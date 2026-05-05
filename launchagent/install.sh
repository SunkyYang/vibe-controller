#!/usr/bin/env bash
set -euo pipefail

# Install DualSenseWhispr as a per-user LaunchAgent.
# Builds release, packages a proper .app, copies it to ~/Applications,
# then loads the agent against that stable path.
# Re-run anytime to refresh the binary / restart the agent.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_LABEL="com.sunky.dualsense-whispr"
AGENT_TEMPLATE="$PROJECT_ROOT/launchagent/$AGENT_LABEL.plist"
AGENT_INSTALLED="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

# .build is a transient build artefact directory; copy the bundle to a
# stable location so System Settings (Accessibility +) and TCC trust
# attach to a real, discoverable path.
SOURCE_APP="$PROJECT_ROOT/.build/release/DualSenseWhispr.app"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/DualSenseWhispr.app"
BIN_PATH="$INSTALL_APP/Contents/MacOS/DualSenseWhispr"

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

echo "==> Stopping any running instance"
launchctl bootout "gui/$UID" "$AGENT_INSTALLED" 2>/dev/null || true

echo "==> Loading agent"
launchctl bootstrap "gui/$UID" "$AGENT_INSTALLED"
launchctl enable "gui/$UID/$AGENT_LABEL"

echo ""
echo "Installed:  $AGENT_INSTALLED"
echo "App:        $INSTALL_APP"
echo "Logs:       $LOG_DIR/dualsense-whispr.{log,err}"
echo ""
echo "Manual control:"
echo "  launchctl kickstart -k gui/$UID/$AGENT_LABEL   # restart"
echo "  launchctl bootout   gui/$UID/$AGENT_LABEL      # stop + unload"
echo "  bash $PROJECT_ROOT/launchagent/uninstall.sh    # remove"
