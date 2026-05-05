#!/usr/bin/env bash
# Wire Claude Code lifecycle events into VibeController's state file so the
# controller's light bar mirrors what Claude is doing.
#
# Idempotent: it strips any prior claude-state-hook.sh entries first, then
# re-installs five hook entries (UserPromptSubmit, PreToolUse, PostToolUse,
# Stop, Notification) alongside whatever else the user already has wired up.
#
# A backup of ~/.claude/settings.json is saved before each run.

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/scripts/claude-state-hook.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required (brew install jq)" >&2
    exit 1
fi
if [ ! -f "$SETTINGS" ]; then
    echo "error: $SETTINGS not found" >&2
    exit 1
fi
if [ ! -x "$HOOK_SCRIPT" ]; then
    echo "error: $HOOK_SCRIPT not executable; run chmod +x" >&2
    exit 1
fi

BACKUP="$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"

TMP="$(mktemp)"
jq --arg cmd "$HOOK_SCRIPT" '
def upsert(event; arg):
  .hooks //= {}
  | .hooks[event] //= [{ "hooks": [] }]
  | (if (.hooks[event] | length) == 0 then .hooks[event] = [{ "hooks": [] }] else . end)
  | .hooks[event][0].hooks //= []
  | .hooks[event][0].hooks |= (
      map(select((.command // "") | contains("claude-state-hook.sh") | not))
      + [{
          "type": "command",
          "command": ($cmd + " " + arg),
          "timeout": 3
        }]
    );

upsert("UserPromptSubmit"; "thinking")
| upsert("PreToolUse"; "tool_use")
| upsert("PostToolUse"; "thinking")
| upsert("Stop"; "idle")
| upsert("Notification"; "notification")
' "$SETTINGS" > "$TMP"

if ! jq empty "$TMP" >/dev/null 2>&1; then
    echo "error: jq produced invalid JSON; not touching $SETTINGS" >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$SETTINGS"

echo "Updated $SETTINGS"
echo "Backup:  $BACKUP"
echo ""
echo "Hook script: $HOOK_SCRIPT"
echo ""
echo "Restart Claude Code (or open a new session) for hooks to apply."
