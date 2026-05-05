#!/usr/bin/env bash
# Remove every claude-state-hook.sh entry from ~/.claude/settings.json,
# preserve everything else, drop now-empty event arrays.

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required (brew install jq)" >&2
    exit 1
fi
if [ ! -f "$SETTINGS" ]; then
    echo "error: $SETTINGS not found" >&2
    exit 1
fi

BACKUP="$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"

TMP="$(mktemp)"
jq '
.hooks //= {}
| .hooks |= with_entries(
    .value |= (
      map(.hooks |= map(select((.command // "") | contains("claude-state-hook.sh") | not)))
      | map(select((.hooks // []) | length > 0))
    )
  )
| .hooks |= with_entries(select((.value // []) | length > 0))
' "$SETTINGS" > "$TMP"

if ! jq empty "$TMP" >/dev/null 2>&1; then
    echo "error: jq produced invalid JSON" >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$SETTINGS"
echo "Removed all claude-state-hook entries from $SETTINGS"
echo "Backup: $BACKUP"
