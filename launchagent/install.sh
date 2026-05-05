#!/usr/bin/env bash
set -euo pipefail

# Install VibeController as a per-user LaunchAgent.
# Order: stop any running copy first, then build + replace the .app, then load.
# Re-run anytime to refresh the binary / restart the agent.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_LABEL="com.sunky.vibe-controller"
AGENT_TEMPLATE="$PROJECT_ROOT/launchagent/$AGENT_LABEL.plist"
AGENT_INSTALLED="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

SOURCE_APP="$PROJECT_ROOT/.build/release/VibeController.app"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/VibeController.app"
BIN_PATH="$INSTALL_APP/Contents/MacOS/VibeController"

echo "==> Stopping any running instance"
launchctl bootout "gui/$UID" "$AGENT_INSTALLED" 2>/dev/null || true
# pkill safety net in case the agent was orphaned or run manually.
pkill -f "VibeController" 2>/dev/null || true
# Give launchd a beat to release the binary before we overwrite it.
sleep 0.3

echo "==> Building .app bundle"
bash "$PROJECT_ROOT/scripts/build-app.sh"

echo "==> Installing to $INSTALL_APP"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_APP"
ditto "$SOURCE_APP" "$INSTALL_APP"
# Re-sign at the install path; ad-hoc trust binds to (path, cdhash).
codesign --force --sign - --timestamp=none "$INSTALL_APP"

echo "==> Ensuring log dir exists"
mkdir -p "$LOG_DIR"

echo "==> Rendering plist with concrete paths"
sed \
    -e "s#__BIN__#$BIN_PATH#g" \
    -e "s#__HOME__#$HOME#g" \
    "$AGENT_TEMPLATE" > "$AGENT_INSTALLED"

echo "==> Loading agent"
launchctl bootstrap "gui/$UID" "$AGENT_INSTALLED"
launchctl enable "gui/$UID/$AGENT_LABEL"

echo ""
echo "Installed:  $AGENT_INSTALLED"
echo "App:        $INSTALL_APP"
echo "Logs:       $LOG_DIR/vibe-controller.{log,err}"
echo ""
echo "Manual control:"
echo "  launchctl kickstart -k gui/$UID/$AGENT_LABEL   # restart"
echo "  launchctl bootout   gui/$UID/$AGENT_LABEL      # stop + unload"
echo "  bash $PROJECT_ROOT/launchagent/uninstall.sh    # remove"
