#!/usr/bin/env bash
# Render the multi-resolution AppIcon.icns from scripts/build-icns.swift.
# Source of truth for the icon is the Swift renderer (Apple's SF Symbol),
# not an SVG.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$PROJECT_ROOT/Resources/AppIcon.iconset"
ICNS="$PROJECT_ROOT/Resources/AppIcon.icns"
RENDERER="$PROJECT_ROOT/scripts/build-icns.swift"

if ! command -v iconutil >/dev/null 2>&1; then
    echo "error: iconutil not found (Apple developer tools missing)" >&2
    exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "==> Rendering iconset PNGs (Swift / SF Symbols)"
swift "$RENDERER" "$ICONSET"

echo "==> Packing icns"
iconutil --convert icns --output "$ICNS" "$ICONSET"
echo "Wrote $ICNS"
