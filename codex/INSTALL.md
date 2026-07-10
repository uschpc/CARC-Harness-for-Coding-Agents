# Setup 1 — `/etc/codex/` managed policy

For when you have root on the target node (`discovery1/2`, `endeavour1/2`).

This dir contains everything you need:

```
AGENTS.md
requirements.toml
managed_config.toml
hooks/precheck.sh
INSTALL.md          (this file)
```

## Install

From inside this dir, as root on the target node:

```bash
sudo install -d -m 0755 -o root -g root /etc/codex /etc/codex/hooks
sudo install -m 0644 -o root -g root AGENTS.md           /etc/codex/AGENTS.md
sudo install -m 0644 -o root -g root requirements.toml   /etc/codex/requirements.toml
sudo install -m 0644 -o root -g root managed_config.toml /etc/codex/managed_config.toml
sudo install -m 0755 -o root -g root hooks/precheck.sh   /etc/codex/hooks/precheck.sh

# Central audit log. The hook writes /var/log/codex-carc/<user>-<date>.log and
# falls back to ~/.codex/audit/ only if this dir is missing or not writable.
# Mode 1733: sticky + world-writable but not readable/listable, so any user can
# append their own file but cannot read or delete another user's.
sudo install -d -m 1733 -o root -g root /var/log/codex-carc
```

Students can then run the normal `codex` command. A module is still useful if
CARC wants to distribute a specific Codex version.

## How enforcement works

Recent Codex CLI versions support two Unix/Linux admin files:

- `/etc/codex/requirements.toml` — admin-enforced requirements users cannot
  override
- `/etc/codex/managed_config.toml` — managed launch defaults that override
  user config at startup

This setup uses `requirements.toml` to forbid `danger-full-access`, forbid
`approval never`, disable unmanaged hooks, install the CARC managed precheck
hook, disable browser/computer-use surfaces on the cluster, deny reads of
common credential directories, and require prompts for `rm`, `sbatch`,
`scancel`, and `git push`.

`managed_config.toml` supplies the normal starting posture:

- `sandbox_mode = "workspace-write"`
- `approval_policy = "untrusted"`
- hooks enabled
- command network access disabled in `workspace-write`

`AGENTS.md` is installed under `/etc/codex/AGENTS.md` as the canonical CARC
instruction file. Codex does not use that file as a managed-policy layer by
itself, so copy or symlink it into course repositories or student workspaces
when you want the model to see the CARC-specific operating guidance.

Cluster network, credential, and proxy controls are still needed if CARC wants
to prevent unmanaged clients from reaching external model services. See
[`../docs/ADMIN_ENFORCEMENT.md`](../docs/ADMIN_ENFORCEMENT.md).

## Verify

```bash
sudo bash -n /etc/codex/hooks/precheck.sh && echo "hook OK"
python3 -c 'import pathlib,tomllib; tomllib.loads(pathlib.Path("/etc/codex/requirements.toml").read_text()); tomllib.loads(pathlib.Path("/etc/codex/managed_config.toml").read_text()); print("config OK")'
codex --version
```

Then in a user session: start `codex`, run `/hooks` to review the managed
hook, and run `/permissions` to confirm the active sandbox and approval mode.
