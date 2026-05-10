# Claude Code state mirroring

Make the light bar react to what Claude Code is doing — blue while thinking, purple during tool calls, amber on notifications, dark when idle.

## Install

```bash
bash scripts/install-claude-hooks.sh    # one-time wiring
```

Undo:

```bash
bash scripts/uninstall-claude-hooks.sh
```

The installer is idempotent and **non-destructive** — it backs up `~/.claude/settings.json` and uses `jq` to merge five hook entries (`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `Notification`) without touching anything else. Each hook calls `scripts/claude-state-hook.sh <state>`, which writes a single line into `~/.vibe-controller/state`. The running app watches that file and updates the light bar.

Pre-existing hooks in your settings are preserved; we just append. **Open a new Claude Code session for the hooks to take effect.**

## Inspecting state

The state file is just one word — easy to introspect:

```bash
cat ~/.vibe-controller/state
```
