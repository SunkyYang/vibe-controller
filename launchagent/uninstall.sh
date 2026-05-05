#!/usr/bin/env bash
set -euo pipefail

AGENT_LABEL="com.sunky.dualsense-whispr"
AGENT_INSTALLED="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
INSTALL_APP="$HOME/Applications/DualSenseWhispr.app"

echo "==> Booting out (if running)"
launchctl bootout "gui/$UID" "$AGENT_INSTALLED" 2>/dev/null || true

if [ -f "$AGENT_INSTALLED" ]; then
    rm -f "$AGENT_INSTALLED"
    echo "Removed $AGENT_INSTALLED"
else
    echo "No installed plist at $AGENT_INSTALLED"
fi

if [ -d "$INSTALL_APP" ]; then
    rm -rf "$INSTALL_APP"
    echo "Removed $INSTALL_APP"
else
    echo "No installed app at $INSTALL_APP"
fi

echo ""
echo "You may also want to remove the obsolete entry from"
echo "System Settings -> Privacy & Security -> Accessibility."
