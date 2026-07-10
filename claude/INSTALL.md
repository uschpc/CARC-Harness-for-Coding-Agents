# Setup 1 — `/etc/claude-code/` (root install, real boundary)

For when you have root on the target node (`discovery1/2`, `endeavour1/2`).

This dir contains everything you need:

```
CLAUDE.md
managed-settings.json
hooks/precheck.sh
INSTALL.md          (this file)
```

## Install

From inside this dir, as root on the target node:

```bash
sudo install -d -m 0755 -o root -g root /etc/claude-code /etc/claude-code/hooks
sudo install -m 0644 -o root -g root CLAUDE.md             /etc/claude-code/
sudo install -m 0644 -o root -g root managed-settings.json /etc/claude-code/
sudo install -m 0755 -o root -g root hooks/precheck.sh     /etc/claude-code/hooks/

# Central audit log. The hook writes /var/log/claude-code/<user>-<date>.log and
# falls back to ~/.claude/audit/ only if this dir is missing or not writable —
# so without this step the audit trail silently scatters into each user's home
# (per-user and user-deletable). Mode 1733: sticky + world-writable but NOT
# readable/listable, so any user can append their own file but cannot read or
# delete another user's.
sudo install -d -m 1733 -o root -g root /var/log/claude-code
```

## Why this is the real boundary

`managed-settings.json` carries three flags that ONLY take effect when the file lives at `/etc/claude-code/managed-settings.json` (root-owned):

- `disableBypassPermissionsMode: "disable"` — turns off `--dangerously-skip-permissions`.
- `allowManagedPermissionRulesOnly: true` — project `.claude/settings.json` can't add permissions.
- `allowManagedHooksOnly: true` — project `.claude/settings.json` can't add hooks.

In user-tier installs those keys are silently ignored — that's the difference between this setup and Setup 2.

## Verify

```bash
sudo bash -n /etc/claude-code/hooks/precheck.sh && echo "hook OK"
sudo python3 -m json.tool /etc/claude-code/managed-settings.json >/dev/null && echo "settings OK"
```

Then in a user session: start `claude`, run `/hooks` (one PreToolUse hook per matcher) and `/permissions` (the deny / ask lists from `managed-settings.json`).
