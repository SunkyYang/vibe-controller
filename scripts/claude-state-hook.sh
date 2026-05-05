#!/usr/bin/env bash
# Claude Code lifecycle hook → DualSenseWhispr state file.
#
# Usage:
#   claude-state-hook.sh <state>
#
# Wire this into ~/.claude/settings.json so the controller's light bar
# mirrors what Claude is doing. See the project README for an example.

set -e

STATE="${1:-unknown}"
DIR="$HOME/.dualsense-whispr"
mkdir -p "$DIR"
# Write atomically so the watcher never sees a partial line.
echo "$STATE" > "$DIR/state.tmp"
mv -f "$DIR/state.tmp" "$DIR/state"
