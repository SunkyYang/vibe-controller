#!/usr/bin/env bash
set -euo pipefail

AGENT_LABEL="com.sunky.dualsense-whispr"
AGENT_INSTALLED="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

echo "==> Booting out (if running)"
launchctl bootout "gui/$UID" "$AGENT_INSTALLED" 2>/dev/null || true

if [ -f "$AGENT_INSTALLED" ]; then
    rm -f "$AGENT_INSTALLED"
    echo "Removed $AGENT_INSTALLED"
else
    echo "No installed plist at $AGENT_INSTALLED (already uninstalled)"
fi
