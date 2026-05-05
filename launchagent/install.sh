#!/usr/bin/env bash
set -euo pipefail

# Install DualSenseWhispr as a per-user LaunchAgent.
# Run once. Re-run anytime to refresh the binary path / restart the agent.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_LABEL="com.sunky.dualsense-whispr"
AGENT_TEMPLATE="$PROJECT_ROOT/launchagent/$AGENT_LABEL.plist"
AGENT_INSTALLED="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
BIN_PATH="$PROJECT_ROOT/.build/release/DualSenseWhispr"

echo "==> Building release binary"
cd "$PROJECT_ROOT"
swift build -c release

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
echo "Installed: $AGENT_INSTALLED"
echo "Logs:      $LOG_DIR/dualsense-whispr.{log,err}"
echo ""
echo "Manual control:"
echo "  launchctl kickstart -k gui/$UID/$AGENT_LABEL   # restart"
echo "  launchctl bootout   gui/$UID/$AGENT_LABEL      # stop + unload"
echo "  bash $PROJECT_ROOT/launchagent/uninstall.sh    # remove"
