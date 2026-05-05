#!/usr/bin/env bash
# Build the release binary and wrap it into a proper .app bundle so that
# macOS shows the custom icon in System Settings (Accessibility list etc.)
# rather than the generic exec icon.
#
# Output: .build/release/DualSenseWhispr.app

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DualSenseWhispr"
BUILD_DIR="$PROJECT_ROOT/.build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICNS="$PROJECT_ROOT/Resources/AppIcon.icns"
INFO_PLIST="$PROJECT_ROOT/Resources/Info.plist"

echo "==> swift build -c release"
cd "$PROJECT_ROOT"
swift build -c release

if [ ! -f "$ICNS" ] || [ "$PROJECT_ROOT/scripts/build-icns.swift" -nt "$ICNS" ]; then
    echo "==> Rebuilding AppIcon.icns (missing or renderer updated)"
    bash "$PROJECT_ROOT/scripts/build-icns.sh"
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME"  "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST"           "$APP_BUNDLE/Contents/Info.plist"
cp "$ICNS"                 "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc codesigning"
# Re-sign so the bundle path is what TCC keys on (otherwise Accessibility
# trust attaches to the loose binary's cdhash and the .app version is
# treated as a separate identity).
codesign --force --sign - --timestamp=none "$APP_BUNDLE"

echo ""
echo "Built: $APP_BUNDLE"
echo "Run:   $APP_BUNDLE/Contents/MacOS/$APP_NAME"
echo "Or:    open $APP_BUNDLE"
