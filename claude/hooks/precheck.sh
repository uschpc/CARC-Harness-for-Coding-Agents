#!/bin/bash
# /etc/claude-code/hooks/precheck.sh
#
# PreToolUse hook for Claude Code on the CARC/USC HPC cluster.
# Runs before every Bash/Write/Edit/Read tool call. Three jobs:
#   1. Audit-log every call.
#   2. BLOCK (exit 2) a small set of unambiguously dangerous patterns:
#      destroying / recursively chmod-ing $HOME, writing ~/.ssh/authorized_keys,
#      destructive ops on other groups' or users' shared storage, and running
#      real computation on a shared login node (mpirun, torchrun, deepspeed,
#      jupyter lab, ollama serve, matlab -batch, nextflow run, ...).
#   3. Force a user confirmation prompt (JSON "ask" decision) for patterns
#      that are usually fine but occasionally cause cluster-wide pain — and
#      for reads of files that commonly hold secrets even though their names
#      don't look like it (~/.bashrc, shell history, ~/.aws/**, kubeconfig).
#
# Policy bias: minimal friction. If a check is annoying more often than it
# catches something real, it does not belong here — put it in CLAUDE.md
# instead, where it's guidance rather than enforcement.
#
# Claude Code hook contract (abridged):
#   stdin  : JSON event ({session_id, tool_name, tool_input, cwd, ...})
#   exit 0 : allow (stdout/stderr is surfaced as extra context)
#   exit 2 : block — stderr is shown to the model
#   JSON stdout with hookSpecificOutput.permissionDecision="ask" forces a
#     user prompt even when permission mode would auto-allow, and is not
#     bypassable (managed-settings disables --dangerously-skip-permissions).

set -u

# Fail closed if the environment is missing USER/HOME (cron, systemd user
# units, some PAM/SSH setups). Without them, later "$USER"/"$HOME" references
# would abort under 'set -u' with a non-2 exit, which Claude Code treats as a
# non-blocking error — i.e. the dangerous call would fail *open*. Populate
# sane defaults up front instead.
: "${USER:=$(id -un 2>/dev/null || echo unknown)}"
: "${HOME:=$(getent passwd "$(id -u 2>/dev/null)" 2>/dev/null | cut -d: -f6)}"
: "${HOME:=/homeless-$$}"
export USER HOME

# ---------- Constants ----------

readonly LOG_DIR_PRIMARY="/var/log/claude-code"
readonly LOG_DIR_FALLBACK="$HOME/.claude/audit"
# Login-node short names. Hostname match is deliberately narrow; if the host
# family is extended, add it here.
readonly LOGIN_NODE_RE='^(discovery|endeavour)[12]$'

# ---------- Parse input ----------

input=$(cat)

# Use python3 because jq is not installed cluster-wide (confirmed on
# discovery1 and compute nodes). Emit five fields separated by \x1f (ASCII
# Unit Separator). Using a non-whitespace separator is intentional: if we
# used \t, consecutive tabs from empty fields would collapse (POSIX
# whitespace-IFS rule) and shift every later field into the wrong variable.
parsed=$(printf '%s' "$input" | python3 -c '
import json, re, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    d = {}
ti = d.get("tool_input") or {}
def s(x): return re.sub(r"[\x00-\x1f]+", " ", str(x if x is not None else ""))
print("\x1f".join([
    s(d.get("tool_name")),
    s(ti.get("command")),
    # NotebookEdit passes the path as "notebook_path", not "file_path";
    # fall back to it so notebook edits get the same path-scoped checks.
    s(ti.get("file_path") or ti.get("notebook_path")),
    s(d.get("session_id")),
    s(d.get("cwd")),
]))
' 2>/dev/null)

IFS=$'\x1f' read -r TOOL CMD FILE_PATH SESSION CWD <<<"$parsed"

# ---------- Logging ----------

today=$(date +%Y%m%d)
if [ -d "$LOG_DIR_PRIMARY" ] && [ -w "$LOG_DIR_PRIMARY" ]; then
    LOG_FILE="$LOG_DIR_PRIMARY/${USER}-${today}.log"
else
    mkdir -p "$LOG_DIR_FALLBACK" 2>/dev/null
    LOG_FILE="$LOG_DIR_FALLBACK/${today}.log"
fi

log_event() {
    # $1 = decision (allow|ask|block), $2 = reason (free text)
    local decision="$1" reason="$2"
    local host; host=$(hostname -s 2>/dev/null || echo unknown)
    # Single line per event — jq-friendly if anyone ever wants to parse it.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -Is)" "$host" "$USER" "$decision" "$TOOL" "$reason" "$CMD" \
        >>"$LOG_FILE" 2>/dev/null || true
}

# ---------- Helpers ----------

# On a login node?
is_login_node() {
    local h; h=$(hostname -s 2>/dev/null)
    [[ "$h" =~ $LOGIN_NODE_RE ]]
}

# Space-separated list of the user's groups, populated lazily.
USER_GROUPS=""
load_user_groups() {
    [ -n "$USER_GROUPS" ] && return
    USER_GROUPS=" $(id -Gn 2>/dev/null) "
}

# Is <group> one the user belongs to? Padded-space membership test.
user_in_group() {
    load_user_groups
    [[ "$USER_GROUPS" == *" $1 "* ]]
}

# Return an expanded command blob: the original plus any strings we can pull
# out of `eval "..."`, `bash -c "..."`, `sh -c "..."`, `$(...)`, and
# backtick substitutions. Best-effort — we want pattern coverage, not a
# full shell parser.
expanded_command() {
    printf '%s' "$CMD" | python3 -c '
import re, sys
s = sys.stdin.read()
out = [s]
out += re.findall(r"\$\(([^()]*)\)", s)
out += re.findall(r"`([^`]*)`", s)
for m in re.finditer(
    r"""\b(?:eval|bash\s+-c|sh\s+-c|bash\s+-lc|zsh\s+-c)\s+('\''[^'\'']*'\''|"[^"]*"|\S+)""",
    s, re.VERBOSE):
    inner = m.group(1)
    if inner and inner[0] in "\"\x27":
        inner = inner[1:-1]
    out.append(inner)
print("\n".join(out))
'
}

# Classify a basename as credential-shaped → echo a reason and return 0,
# else return 1. Used by both the Read-tool branch and the Bash cat/head
# heuristic. Public-key extensions (.pub, *.public.key) are deliberately
# excluded — those are meant to be read.
credential_shape_reason() {
    local p="$1"
    local base="${p##*/}"
    case "$base" in
        .env.example|.env.sample|.env.template|.env.dist|.env.example.*)
            return 1 ;;
        .env|.env.*)
            printf '%s is an env-vars file (often holds API keys / DB passwords)' "$p"
            return 0 ;;
        *.pub|*.pub.*)
            return 1 ;;
        *.pem|*.p12|*.pfx|*.jks|*.keystore)
            printf '%s looks like a private key or keystore' "$p"
            return 0 ;;
        *.public.key|*.pub.key)
            return 1 ;;
        *.key)
            printf '%s looks like a private key file' "$p"
            return 0 ;;
        .htpasswd|.htdigest)
            printf '%s is an htpasswd-style credentials file' "$p"
            return 0 ;;
    esac
    local lower="${base,,}"
    case "$lower" in
        *credentials*|*credential.json|*service-account*.json|*service_account*.json)
            printf '%s has a credential-shaped name' "$p"
            return 0 ;;
    esac
    return 1
}

# Resolve a tool path to an absolute path for matching: expand a leading ~ or
# $HOME/${HOME}, and make a relative path absolute against $CWD. No '..'
# normalisation — this is for prefix/exact matching, not canonicalisation.
abspath_of() {
    local p="$1"
    case "$p" in
        "~")              p="$HOME" ;;
        "~/"*)            p="$HOME/${p#\~/}" ;;
        '$HOME'|'${HOME}')   p="$HOME" ;;
        '$HOME/'*)        p="$HOME/${p#\$HOME/}" ;;
        '${HOME}/'*)      p="$HOME/${p#\$\{HOME\}/}" ;;
    esac
    case "$p" in
        /*) printf '%s' "$p" ;;
        *)  printf '%s' "${CWD:-$PWD}/$p" ;;
    esac
}

# Files under the user's *own* $HOME whose names aren't credential-shaped but
# which very commonly hold secrets: shell rc/profile files (people leave
# `export FOO_API_KEY=...` in .bashrc), shell/REPL history, cloud-CLI config
# dirs, kube/npm/pip/R config, kaggle/podman registry auth, and odd files
# inside ~/.ssh. Echo a reason and return 0 if $1 matches, else return 1.
# Public keys (*.pub) and the harmless ~/.ssh metadata files are excluded.
sensitive_home_read_reason() {
    local abs; abs=$(abspath_of "$1")
    case "$abs" in "$HOME"/*) : ;; *) return 1 ;; esac
    local rel="${abs#"$HOME"/}"
    case "$rel" in
        *.pub) return 1 ;;
        .bashrc|.bashrc.*|.bash_profile|.bash_login|.profile|.bash_aliases|.bash_logout|.kshrc)
            printf '%s is a shell startup file — these frequently contain "export SOMETHING_API_KEY=..." lines' "$1"; return 0 ;;
        .zshrc|.zshenv|.zprofile|.zlogin|.zlogout)
            printf '%s is a zsh startup file — may contain exported API keys or tokens' "$1"; return 0 ;;
        .bash_history|.zsh_history|.sh_history|.history|.python_history|.node_repl_history|.mysql_history|.psql_history|.rediscli_history|.Rhistory|.lesshst)
            printf '%s is a shell/REPL history file — frequently holds pasted tokens, passwords, and connection strings' "$1"; return 0 ;;
        .Renviron|.Renviron.*)
            printf '%s holds R environment variables (GITHUB_PAT, *_API_KEY, ...)' "$1"; return 0 ;;
        .aws/*)
            printf '%s is under ~/.aws (AWS access keys / SSO config)' "$1"; return 0 ;;
        .config/gcloud/*)
            printf '%s is under ~/.config/gcloud (GCP credentials / OAuth tokens)' "$1"; return 0 ;;
        .azure/*)
            printf '%s is under ~/.azure (Azure CLI tokens)' "$1"; return 0 ;;
        .kube/config|.kube/config.*|.kube/*.kubeconfig|.kube/*.yaml|.kube/*.yml)
            printf '%s is a kubeconfig (cluster certs and bearer tokens)' "$1"; return 0 ;;
        .npmrc|.yarnrc|.yarnrc.yml)
            printf '%s can contain a package-registry auth token' "$1"; return 0 ;;
        .pypirc)
            printf '%s can contain PyPI upload credentials' "$1"; return 0 ;;
        .git-credentials|.config/git/credentials)
            printf '%s holds stored git credentials' "$1"; return 0 ;;
        .kaggle/kaggle.json)
            printf '%s holds your Kaggle API credentials' "$1"; return 0 ;;
        .docker/config.json|.config/containers/auth.json)
            printf '%s holds container-registry auth' "$1"; return 0 ;;
        .terraform.d/credentials.tfrc.json)
            printf '%s holds Terraform Cloud credentials' "$1"; return 0 ;;
        .config/gh/hosts.yml|.config/gh/config.yml)
            printf '%s holds your GitHub CLI auth token' "$1"; return 0 ;;
        .ssh/known_hosts|.ssh/known_hosts.*|.ssh/config|.ssh/authorized_keys|.ssh/authorized_keys2|.ssh/environment)
            return 1 ;;
        .ssh/*)
            printf '%s is inside ~/.ssh and may be a private key' "$1"; return 0 ;;
    esac
    return 1
}

# ---------- Block / ask decisions ----------

# Emit a JSON "ask" decision on stdout and exit 0 (the ask output takes
# precedence over the exit code for the permission prompt).
emit_ask() {
    local reason="$1"
    # Also send a human-readable line to stderr for visibility in --verbose.
    printf '[claude-precheck] asking for confirmation: %s\n' "$reason" >&2
    python3 -c '
import json, sys
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": sys.argv[1],
    }
}))
' "$reason"
    log_event ask "$reason"
    exit 0
}

block() {
    local reason="$1"
    printf '[claude-precheck] BLOCKED: %s\n' "$reason" >&2
    printf 'Command: %s\n' "$CMD" >&2
    log_event block "$reason"
    exit 2
}

allow() {
    log_event allow ok
    exit 0
}

# ---------- Non-Bash tools: path-scoped checks ----------

if [ "$TOOL" != "Bash" ]; then
    # Write / Edit / MultiEdit to sensitive paths. Managed-settings `deny`
    # already covers the obvious cases (~/.ssh, ~/.aws, ~/.bashrc, etc.) but
    # this hook gives a clear message on login-node /tmp writes.
    case "$TOOL" in
        Write|Edit|MultiEdit|NotebookEdit)
            # Adding/altering an SSH login key grants access to the account —
            # never something Claude should do unattended. (managed-settings
            # also `deny`s this; the hook gives a clear message.)
            case "$(abspath_of "$FILE_PATH")" in
                "$HOME"/.ssh/authorized_keys|"$HOME"/.ssh/authorized_keys2)
                    block "writing to ~/.ssh/authorized_keys would grant SSH login to your account. Claude must not add login keys — if you intend to, do it yourself." ;;
            esac
            if is_login_node; then
                case "$FILE_PATH" in
                    /tmp|/tmp/*|/var/tmp|/var/tmp/*|/dev/shm|/dev/shm/*)
                        block "write to $FILE_PATH on login node ($(hostname -s)) — /tmp is shared with every cluster user; use /scratch1/\$USER or a compute-node job" ;;
                esac
            fi
            ;;
        Read)
            # Static-name credentials (~/.aws/credentials, etc.) are denied
            # in managed-settings.json. These branches catch the long tail:
            # credential-shaped names (.env, *.pem, **/credentials.json) and
            # home-dir files that commonly hold secrets despite ordinary names
            # (~/.bashrc, shell history, ~/.aws/**, kubeconfig, ...).
            if reason=$(credential_shape_reason "$FILE_PATH"); then
                emit_ask "Read of $FILE_PATH — $reason. Confirm to proceed."
            fi
            if reason=$(sensitive_home_read_reason "$FILE_PATH"); then
                emit_ask "Read of $FILE_PATH — $reason. Confirm to proceed."
            fi
            ;;
    esac
    allow
fi

# ---------- Bash: pattern checks ----------

EXPANDED=$(expanded_command)

# Convenience: grep against $EXPANDED with extended regex, case-sensitive.
has_pattern() { printf '%s' "$EXPANDED" | grep -Eq "$1"; }

# 0. sudo / su as a command. managed-settings denies the literal forms, but
#    that only matches the *outer* command — 'bash -c "sudo ..."', 'eval ...',
#    '$(sudo ...)' slip past it. We match against $EXPANDED (which pulls those
#    wrappers apart), anchored to command position so 'echo sudo' or a path
#    containing "su" doesn't trip it.
if has_pattern '(^|[;&|(])[[:space:]]*(sudo|su)([[:space:]]|$)'; then
    block "sudo/su (privilege escalation or user switch) is not allowed for the agent — and wrapping it in bash -c / eval doesn't change that. If you need elevated actions, run them yourself."
fi

# 1. rm at filesystem roots or $HOME. We check two orthogonal conditions and
#    block only if both hold: "rm has a recursive flag somewhere" AND "rm
#    targets a root or $HOME". Splitting the regex keeps both parts simple
#    and covers short flags (-rf, -Rf), long flags (--recursive, --force),
#    and the --no-preserve-root escape-hatch form.
rm_is_recursive() {
    has_pattern '\brm\b[^|;&]*(-[a-zA-Z]*[rR]|--recursive\b)'
}
rm_hits_root() {
    has_pattern '\brm\b[^|;&]*[[:space:]](/|/\*|~|~/|\$\{?HOME\}?)([[:space:]]|$|;|\||&)'
}
if rm_is_recursive && rm_hits_root; then
    block "rm -r / rm --recursive at a filesystem root or \$HOME"
fi

# 2. rm / chmod / chown / mv against cluster-shared mount roots — block.
#    Matches the literal mount root without a further path component. We
#    do not require a recursive flag here: changing the owner/perms of a
#    mount point (e.g. 'chmod 777 /apps') is always wrong, recursive or
#    not. The middle is deliberately permissive ([^|;&]*) so modes like
#    'chmod -R 777 /apps' or 'chmod --recursive 777 /apps' both match.
for root in /home1 /project2 /scratch1 /cryoem2 /apps /spack; do
    if has_pattern "\\b(rm|chmod|chown|mv)\\b[^|;&]*[[:space:]]${root}/?(\\*|\\*/)?([[:space:]]|$|;|\\||&)"; then
        block "destructive op at the root of ${root}"
    fi
done

# 2b. Recursive chmod/chown at the filesystem root '/'. The managed-settings
#     deny 'Bash(chmod -R /:*)' is effectively dead: a real command puts the
#     mode before the path ('chmod -R 777 /'), so it never has the literal
#     'chmod -R /' prefix. Cover the real forms here, including '/' and '/*'.
if has_pattern '(^|[^a-zA-Z0-9_])(chmod|chown)[[:space:]]+[^|;&]*(-[a-zA-Z]*R|--recursive)[^|;&]*[[:space:]]/\*?([[:space:]]|$|;|\||&)'; then
    block "recursive chmod/chown at the filesystem root '/' — this can brick the OS and is never correct. Scope it to a specific directory you own."
fi

# 3 & 4. Destructive ops on another lab's /project2/<group> or another user's
#    /scratch1/<user>. Policy: a world-writable (777) leftover dir in another
#    lab does NOT grant you permission, and scratch dirs are per-user.
#
#    Two things this does that the earlier version didn't:
#    (a) It only treats a /project2 or /scratch1 path as a *target* if it is an
#        argument to a destructive verb (or a redirect / dd 'of=' target). The
#        old code blocked any line that merely *contained* a destructive-verb
#        token AND a foreign path anywhere — so 'rm ./x; cat /project2/other/y'
#        or even an 'echo "...mv..." > ./notes' false-tripped it.
#    (b) It covers the destructive verbs the rm/chmod/chown/mv list missed:
#        truncate, shred, tee, dd 'of=', 'rsync --delete', and '>'/'>>'
#        redirects. Plain additive copies (cp -r, rsync without --delete) are
#        intentionally NOT treated as destructive here (cp -a/-p into /project2
#        is handled separately by the quota rule in §5).
check_foreign_shared_destructive() {
    local targets
    targets=$(printf '%s' "$EXPANDED" | python3 -c '
import re, sys
s = sys.stdin.read()

# Verbs whose path args we treat as destructive/overwriting targets. cp and
# additive rsync are intentionally absent (additive into a writable dir; the
# cp -a/-p quota case is handled separately in §5).
DESTRUCTIVE = {"rm", "mv", "chmod", "chown", "truncate", "shred", "tee"}

def emit(p, out):
    if p.startswith("/project2/") or p.startswith("/scratch1/"):
        out.append(p)

def redir_targets(toks, out):
    # Any >/>> redirect target (not >&). Target may be glued (">f") or next tok.
    j = 0
    while j < len(toks):
        t = toks[j]
        if t.startswith(">") and not t.startswith(">&"):
            rest = t[2:] if t.startswith(">>") else t[1:]
            if rest:
                emit(rest, out)
            elif j + 1 < len(toks):
                emit(toks[j + 1], out); j += 1
        j += 1

out = []
for line in s.splitlines():
    # Split into simple-command segments on shell operators, so the first token
    # of each segment is its command and the rest are *that* command s args.
    # This is what scopes a foreign path to the verb that actually targets it
    # (and stops a stray "mv" inside a quoted echo arg from tripping the check).
    for seg in re.split(r"\|\||&&|[;|&()]", line):
        toks = seg.split()
        if not toks:
            continue
        redir_targets(toks, out)
        verb = toks[0].split("/")[-1]  # /bin/rm -> rm
        args = toks[1:]
        if verb in DESTRUCTIVE:
            for a in args:
                if a.startswith("-") or a.startswith(">") or "://" in a or any(c in a for c in "*?["):
                    continue
                emit(a, out)
        elif verb == "dd":
            for a in args:
                if a.startswith("of="):
                    emit(a[3:], out)
        elif verb == "rsync" and any(a.startswith("--delete") for a in args):
            for a in args:
                if a.startswith("-") or "://" in a or any(c in a for c in "*?["):
                    continue
                emit(a, out)
for p in out:
    print(p)
' | sort -u)
    [ -z "$targets" ] && return
    load_user_groups
    while IFS= read -r tgt; do
        [ -z "$tgt" ] && continue
        case "$tgt" in
            /project2/*)
                local sub="${tgt#/project2/}"; sub="${sub%%/*}"
                [ -z "$sub" ] && continue
                if ! user_in_group "$sub"; then
                    block "destructive op targets /project2/$sub — you are not a member of group $sub; even a world-writable dir in another lab is off-limits"
                fi
                ;;
            /scratch1/*)
                local u="${tgt#/scratch1/}"; u="${u%%/*}"
                [ -z "$u" ] && continue
                if [ "$u" != "$USER" ]; then
                    block "destructive op targets /scratch1/$u — not your scratch directory"
                fi
                ;;
        esac
    done <<<"$targets"
}
check_foreign_shared_destructive

# 4b. 'cd <other-lab> && rm -rf *' escape-hatch. A user can side-step every
#     check above by first cd-ing into a different user's directory and then
#     issuing a destructive op against a relative path / glob. Catch this by
#     scanning for cd/pushd targets under /project2/<group> or
#     /scratch1/<user>, and if the target is not one the current user owns
#     AND any destructive verb appears anywhere in the same command, block.
#     Accepted tradeoff: 'cd /project2/other && ls && cd /project2/mine &&
#     rm *' also triggers this (a false positive for the rare compound-cd
#     case). Users who genuinely need that pattern can split it into two
#     tool calls.
check_cd_traversal() {
    local cd_targets
    cd_targets=$(printf '%s' "$EXPANDED" | python3 -c '
import re, sys
s = sys.stdin.read()
# Is there any destructive verb anywhere in the expanded command? If not,
# any cd is uninteresting.
if not re.search(r"\b(rm|chmod|chown|mv|cp)\b", s):
    sys.exit(0)
for m in re.finditer(r"\b(?:cd|pushd)\s+(/project2/[A-Za-z0-9._-]+|/scratch1/[A-Za-z0-9._-]+)", s):
    print(m.group(1))
' | sort -u)
    [ -z "$cd_targets" ] && return
    load_user_groups
    while IFS= read -r tgt; do
        case "$tgt" in
            /project2/*)
                local grp="${tgt#/project2/}"
                if ! user_in_group "$grp"; then
                    block "command does 'cd /project2/$grp' and then a destructive op — $grp is not one of your groups. 'cd <their_dir> && rm -rf *' counts as touching their files."
                fi
                ;;
            /scratch1/*)
                local u="${tgt#/scratch1/}"
                if [ "$u" != "$USER" ]; then
                    block "command does 'cd /scratch1/$u' and then a destructive op — not your scratch directory."
                fi
                ;;
        esac
    done <<<"$cd_targets"
}
check_cd_traversal

# 5. cp -a / cp -p into /project2 — causes "quota exceeded" because the
#    source group/owner is preserved and blows the destination group's quota.
if has_pattern '(^|[^a-zA-Z0-9_])cp[[:space:]]+(-[a-zA-Z]*[ap][a-zA-Z]*[[:space:]]+).*(/project2/)'; then
    block "cp -a / cp -p into /project2 — preserves source group and causes 'disk quota exceeded'. Use plain 'cp -r' instead."
fi

# 6. Login-node /tmp writes. On login hosts, stdout redirects and tee into
#    /tmp, /var/tmp, or /dev/shm also count. On compute nodes /tmp is
#    per-job tmpfs; not touched here. The '/tmp' must be a standalone path
#    arg (right after '>' / after whitespace) — '/scratch1/$USER/tmp/...',
#    the *recommended* TMPDIR, must NOT trigger this.
if is_login_node && has_pattern '(>>?[[:space:]]*|[[:space:]]tee[[:space:]]+([^|;&]*[[:space:]])?)/(tmp|var/tmp|dev/shm)([/[:space:]]|;|\||&|$)'; then
    block "write to /tmp|/var/tmp|/dev/shm on login node ($(hostname -s)) — shared by every cluster user; use /scratch1/\$USER/tmp or run on a compute node"
fi
# And the literal commands that create files there, like mkdir/touch/mv/cp dest.
# The middle '([^;&|]*[[:space:]])?' is optional so 'mkdir /tmp/x' (path
# directly after the verb) matches as well as 'cp src /tmp/y' (path after
# other args).
if is_login_node && has_pattern '(^|[;&|(])[[:space:]]*(mkdir|touch|install|mv|cp|rsync|dd)[[:space:]]+([^;&|]*[[:space:]])?/(tmp|var/tmp|dev/shm)(/|[[:space:]]|$)'; then
    block "file create/move into /tmp|/var/tmp|/dev/shm on login node — shared; use /scratch1/\$USER"
fi

# 6b. Real computation on a login node. discovery1/2 and endeavour1/2 are
#     shared entry points — meant for editing, compiling small things, moving
#     data, and submitting jobs. Computation goes in a SLURM allocation. We
#     BLOCK the unambiguous offenders and ASK on the grey-area ones. (The
#     hostname match is the same LOGIN_NODE_RE used elsewhere, so this is a
#     no-op on compute nodes.)
if is_login_node; then
    LN="$(hostname -s 2>/dev/null || echo login)"
    # (a) parallel / distributed job launchers — never appropriate here.
    if has_pattern '(^|[^a-zA-Z0-9_])(mpirun|mpiexec|mpiexec\.hydra|orterun|torchrun|deepspeed|horovodrun)([[:space:]]|$)' \
       || has_pattern '(^|[^a-zA-Z0-9_])accelerate[[:space:]]+launch([[:space:]]|$)'; then
        block "parallel/distributed job launcher on a login node ($LN), shared by ~50 people. Get an allocation first — quick test: 'salloc --partition=debug --time=0:30:00 --mem=8G' then 'srun --pty bash'; real run: write an sbatch script and submit it."
    fi
    # (b) long-running servers / model runtimes.
    if has_pattern '(^|[^a-zA-Z0-9_])jupyter[[:space:]]+(lab|notebook|server)([[:space:]]|$)' \
       || has_pattern '(^|[^a-zA-Z0-9_])jupyter-(lab|notebook)([[:space:]]|$)' \
       || has_pattern '(^|[^a-zA-Z0-9_])(ollama[[:space:]]+(run|serve)|vllm[[:space:]]+serve|llama-server|text-generation-launcher|sglang)([[:space:]]|$)'; then
        block "starting a long-running server / model runtime on a login node ($LN). Launch it inside a SLURM allocation on a compute node — for a short test use '--partition=debug'."
    fi
    # (c) compute drivers people routinely run on the head node by mistake.
    if has_pattern '(^|[^a-zA-Z0-9_])matlab[[:space:]]+[^;&|]*(-batch|-r)([[:space:]"'\''])' \
       || has_pattern '(^|[^a-zA-Z0-9_])(nextflow[[:space:]]+run|comsol[[:space:]]+batch)([[:space:]]|$)' \
       || has_pattern '(^|[^a-zA-Z0-9_])abaqus[[:space:]]+[^;&|]*job='; then
        block "running a compute driver on a login node ($LN). Submit it as a SLURM job; for a short test use '--partition=debug --time<=1:00:00'."
    fi
    # (d) Plain interpreter-with-script invocations — ASK so the user gets a
    #     one-tap approval before it runs. Wording is deliberately approve-
    #     friendly (the common case is a small script that's fine to run);
    #     the "use salloc" alternative is mentioned but not the default
    #     framing, so Claude doesn't pre-empt the prompt with a salloc recipe.
    if has_pattern '(^|[^a-zA-Z0-9_])(python[0-9.]*|ipython[0-9.]*|pypy[0-9.]*|Rscript|julia)[[:space:]][^;&|]*\.(py|R|r|jl)([^a-zA-Z0-9_]|$)' \
       || has_pattern '(^|[^a-zA-Z0-9_])R[[:space:]]+CMD[[:space:]]+BATCH([[:space:]]|$)'; then
        emit_ask "Interpreter invoked with a script on login node ($LN). Quick scripts are fine here — approve to run. If it's real computation, decline and use 'salloc --partition=debug --time=0:30:00 --mem=8G' then re-run there."
    fi
    # (e) parallel build — compiling small things on the head node is
    #     tolerated; a big '-j' build is not.
    if has_pattern '(^|[^a-zA-Z0-9_])make[[:space:]]+[^;&|]*(-j[[:space:]]*([0-9]{2,}|[4-9])([^0-9]|$)|--jobs[[:space:]=]+[0-9])'; then
        emit_ask "parallel build ('make -j...') on a login node ($LN). Compiling small things here is fine; a big parallel build belongs in 'salloc --partition=debug'. Confirm to build here."
    fi
    # (f) long-lived UI / monitoring servers.
    if has_pattern '(^|[^a-zA-Z0-9_])(tensorboard|mlflow[[:space:]]+ui|streamlit[[:space:]]+run|gradio)([[:space:]]|$)'; then
        emit_ask "starting a UI/monitoring server on a login node ($LN). These keep running and tie up the shared node — prefer a compute-node allocation. Confirm to continue here."
    fi
fi

# 6c. Wholesale destruction or permission changes of a *home* directory.
#     Section 1 already blocks the simplest 'rm -r ~' / 'rm -r $HOME' forms;
#     this widens the net to the quoted forms ("$HOME", "${HOME}"), the
#     top-level globs (~/*, $HOME/.*), recursive chmod/chown on $HOME or
#     ~/.ssh (the classic lock-yourself-out — sshd refuses a group- or
#     world-accessible $HOME or ~/.ssh), the 'cd ~ && rm -rf *' escape hatch,
#     and (as a prompt) 'find $HOME ... -delete'. A *specific* subdirectory
#     like '~/build' is intentionally NOT matched — that's normal work.
#     HOME_TOK = a token naming the home dir itself; HOME_END = it then ends
#     or is followed only by a top-level glob ('$' here is the line anchor).
HOME_TOK='("?(~|\$HOME|\$\{HOME\}|/home1?/[A-Za-z0-9._-]+)"?)'
HOME_END='("?/?(\*|\.\*|\{\.[^}]*\})?)("|[[:space:]]|;|\||&|$)'
if has_pattern "(^|[^a-zA-Z0-9_])rm[[:space:]]+[^|;&]*(-[a-zA-Z]*[rR]|--recursive)[^|;&]*[[:space:]]${HOME_TOK}${HOME_END}"; then
    block "recursive rm of a home directory — that erases config, SSH keys, conda envs, and everything else under \$HOME. If you really want this, do it yourself."
fi
if has_pattern "(^|[^a-zA-Z0-9_])(chmod|chown)[[:space:]]+[^|;&]*(-[a-zA-Z]*R|--recursive)[^|;&]*[[:space:]]${HOME_TOK}${HOME_END}" \
   || has_pattern "(^|[^a-zA-Z0-9_])(chmod|chown)[[:space:]]+[^|;&]*(-[a-zA-Z]*R|--recursive)[^|;&]*[[:space:]]${HOME_TOK}/\.ssh(/[^[:space:]]*)?(\"|[[:space:]]|;|\||&|$)"; then
    block "recursive chmod/chown on a home directory (or ~/.ssh). This routinely breaks login — sshd refuses to use ~/.ssh, or \$HOME itself, when it is group- or world-accessible — and clobbers permissions across thousands of files. Set perms on the specific files that need it instead (e.g. 'chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_*')."
fi
# 'cd ~' / 'cd $HOME' / bare 'cd' followed by an rm with a bare glob target.
if has_pattern "(^|[;&|(])[[:space:]]*cd[[:space:]]+${HOME_TOK}([[:space:]]|;|&|\||$)" \
   || has_pattern "(^|[;&|(])[[:space:]]*cd[[:space:]]*(;|&&|\|\||$)"; then
    if has_pattern "(^|[;&|])[[:space:]]*rm[[:space:]]+[^|;&]*(-[a-zA-Z]*[rR]|--recursive)[^|;&]*[[:space:]]\.?/?\*([[:space:]]|;|\||&|$)"; then
        block "this 'cd's to your home directory and then 'rm -r' a bare glob ('*' / './*') — that wipes \$HOME. If you really mean it, do it yourself."
    fi
fi
if has_pattern "(^|[^a-zA-Z0-9_])find[[:space:]]+${HOME_TOK}([[:space:]]|/[[:space:]])[^;&|]*(-delete|-exec[[:space:]]+rm([[:space:]]|$))"; then
    emit_ask "'find \$HOME ... -delete' / '-exec rm' — one wrong predicate here wipes the whole home directory. Prefer narrowing the search root to a specific subdirectory, or listing matches first. Confirm to run it as written."
fi

# 6d. Adding an SSH login key to an account via the shell (echo/printf/cat
#     redirected, tee -a, cp, sed -i into ~/.ssh/authorized_keys). The
#     Write/Edit tool path is denied in managed-settings; this is the
#     shell-redirect path. Read-only commands (cat/grep/diff with no write
#     operator) are deliberately not caught here.
if has_pattern '(~|\$HOME|\$\{HOME\}|/home1?/[A-Za-z0-9._-]+|/root)/\.ssh/authorized_keys2?([^A-Za-z0-9_]|$)' \
   && has_pattern '(>>?|(^|[[:space:];&|(])(tee|cp|install|rsync|dd|sed)([[:space:]]|$))'; then
    block "this writes to ~/.ssh/authorized_keys — that grants SSH login to the account. Claude must not add login keys; do it yourself if intended."
fi

# ---------- Ask (warn-but-allow) decisions ----------

# 7. rm/mv targeting files/folders owned by another user — ASK and name
#    the owner. The block checks above already gate other labs' /project2
#    dirs and other users' /scratch1 dirs. This adds a finer-grained
#    check: even in your own area, if a colleague's file is sitting there
#    (e.g. someone in your lab dropped data into /project2/<your_group>/),
#    you should get one prompt that names the owner before deleting or
#    moving someone else's work.
#
#    Implementation notes:
#    - We resolve paths with $CWD for relatives, lstat them (don't follow
#      symlinks — `rm <symlink>` removes the link itself).
#    - Globs (*, ?, [) are skipped: expanding them safely is non-trivial
#      and the directory-level block checks above already catch the
#      cross-lab cases. Future work to expand small globs in a bounded way.
#    - Files that don't exist are skipped silently (rm will fail anyway).
check_foreign_owned_destructive_ask() {
    local report
    report=$(printf '%s' "$EXPANDED" | python3 -c '
import os, pwd, re, sys
cwd = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
user = os.environ.get("USER", "")
s = sys.stdin.read()

def owner_of(p):
    try:
        st = os.lstat(p)
    except OSError:
        return None
    try:
        return pwd.getpwuid(st.st_uid).pw_name
    except KeyError:
        return str(st.st_uid)

seen = []
for line in s.splitlines():
    toks = line.split()
    i = 0
    while i < len(toks):
        if re.fullmatch(r"(rm|mv)", toks[i]):
            j = i + 1
            ddash = False
            while j < len(toks):
                a = toks[j]
                if a in ("|", "||", "&", "&&", ";"):
                    break
                if not ddash and a == "--":
                    ddash = True; j += 1; continue
                if not ddash and a.startswith("-"):
                    j += 1; continue
                # Strip a single trailing punctuation if any (e.g. trailing comma in a doc)
                if any(c in a for c in "*?["):
                    j += 1; continue
                if "://" in a:
                    j += 1; continue
                p = a if a.startswith("/") else os.path.normpath(os.path.join(cwd, a))
                o = owner_of(p)
                if o is not None and o != user:
                    pair = (p, o)
                    if pair not in seen:
                        seen.append(pair)
                j += 1
            i = j
        else:
            i += 1
for p, o in seen[:5]:
    sys.stdout.write(p + "\t" + o + "\n")
' "$CWD")
    [ -z "$report" ] && return
    local msg
    msg='rm/mv targets file(s) owned by another user:'$'\n'
    local path owner
    while IFS=$'\t' read -r path owner; do
        [ -z "$path" ] && continue
        msg+="  - ${path} (owned by ${owner})"$'\n'
    done <<<"$report"
    msg+='You are about to delete or move files that are not yours. Confirm to proceed.'
    emit_ask "$msg"
}
check_foreign_owned_destructive_ask

# 8. Mass-install commands — metadata pressure on parallel FS. Ask the user
#    so they see the warning even under --permission-mode acceptEdits.
if has_pattern '(^|[^a-zA-Z0-9_])(pip[3]?|pip3\.[0-9]+)[[:space:]]+(install|download|wheel)([[:space:]]|$)'; then
    emit_ask "pip install can create tens of thousands of small files and hit your 1.9M-inode /home1 quota. Prefer '--user' into /home1/\$USER and 'pip cache purge' after. Confirm to continue."
fi
if has_pattern '(^|[^a-zA-Z0-9_])npm[[:space:]]+(install|i|ci|add)([[:space:]]|$)'; then
    emit_ask "npm install creates huge node_modules trees (bad on VAST/BeeGFS). Run it in /home1 or /tmp on a compute node, not /project2 or /scratch1. Confirm to continue."
fi
if has_pattern '(^|[^a-zA-Z0-9_])(yarn|pnpm)[[:space:]]+(install|add)([[:space:]]|$)'; then
    emit_ask "yarn/pnpm install creates many small files — keep it on /home1 or compute-node /tmp. Confirm to continue."
fi
if has_pattern '(^|[^a-zA-Z0-9_])(conda|mamba)[[:space:]]+(create|install|env[[:space:]]+create)([[:space:]]|$)'; then
    emit_ask "conda/mamba envs are large; for big envs use '--prefix /project2/<your_group>/<env>' rather than /home1. Confirm to continue."
fi

# 9. sbatch — submitting a job. Always show the user the script first and
#    confirm its resource asks before anything hits the queue.
if has_pattern '(^|[^a-zA-Z0-9_])sbatch([[:space:]]|$)'; then
    emit_ask "submitting a SLURM job. Show the user the job script first, then confirm: --account is one of their groups ('sacctmgr show assoc user=\$USER'), and --partition / --mem / --time / --cpus-per-task / --gres are right and within the group's QOS. For a quick test prefer '--partition=debug --time=0:30:00' over a multi-day partition. Do not 'sbatch' until the user has okayed the script."
fi

# 9b. salloc / srun --pty without --partition=debug — nudge toward the debug
#     queue for interactive testing instead of the default 2-day 'main'.
if has_pattern '(^|[^a-zA-Z0-9_])(salloc|srun)([[:space:]]|$)' \
   && has_pattern '(^|[^a-zA-Z0-9_])(salloc|srun[^;&|]*--pty)([[:space:]]|$)' \
   && ! has_pattern '(-p|--partition)[[:space:]=]+debug([[:space:]]|$)'; then
    emit_ask "interactive allocation without '--partition=debug'. For a quick test, 'salloc --partition=debug --time=0:30:00 --mem=8G --cpus-per-task=4' schedules fast and doesn't draw down the 2-day allocation; only move to main/gpu/epyc-64/etc. once it works. Confirm to continue, or re-run with --partition=debug."
fi

# 10. curl/wget piped straight into a shell — classic supply-chain foot-gun.
if has_pattern '(curl|wget)[[:space:]]+[^;|&]+(\|[[:space:]]*(bash|sh|zsh|python[0-9.]*))'; then
    emit_ask "piping a network download straight into a shell is how supply-chain attacks land. Confirm you trust the URL and the content."
fi

# 11. Bash command reading a credential-shaped / secrets-bearing file via
#     cat/head/tail/etc. The Read-tool branch above gates Claude's Read calls;
#     this catches the same shapes when Claude shells out. Best-effort: after
#     a reader verb we take *every* non-flag, non-redirect-target token up to
#     the next shell separator (so 'head -n 50 ~/.bashrc' is caught — the
#     value '50' is harmless to also check) and stop at '>' so a write target
#     like 'cat x > /tmp/y' is not mistaken for a read.
check_bash_credential_read() {
    local files
    files=$(printf '%s' "$EXPANDED" | python3 -c '
import re, sys
s = sys.stdin.read()
out = []
verb_re = re.compile(r"(?<![\w.\-])(?:cat|less|more|head|tail|bat|view|nl|tac|xxd|od|hexdump|strings)\b")
for line in s.splitlines():
    for m in verb_re.finditer(line):
        rest = re.split(r"[;&|<>()]", line[m.end():], 1)[0]
        for tok in rest.split():
            if tok.startswith("-") or "://" in tok:
                continue
            out.append(tok.strip("\"\x27"))
print("\n".join(out))
' | sort -u)
    [ -z "$files" ] && return
    local f reason
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if reason=$(credential_shape_reason "$f"); then
            emit_ask "Bash reads $f — $reason. Confirm to proceed."
        fi
        if reason=$(sensitive_home_read_reason "$f"); then
            emit_ask "Bash reads $f — $reason. Confirm to proceed."
        fi
    done <<<"$files"
}
check_bash_credential_read

# ---------- Default ----------

allow
