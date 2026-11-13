#!/bin/bash
# Builds "Vibe Kit.app" into ./build. Set UNIVERSAL=1 for an arm64 + x86_64 binary.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.3.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/Vibe Kit.app"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --product VibeKit --arch arm64 --arch x86_64
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release --product VibeKit
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

# Redraw the icon when the drawing script is newer than the last one drawn.
[[ build/AppIcon.icns -nt scripts/make-icon.swift ]] || swift scripts/make-icon.swift build

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VibeKit" "$APP/Contents/MacOS/VibeKit"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

# Ad hoc signature by default, which is fine for running locally. scripts/release.sh sets
# SIGN_IDENTITY to a Developer ID and adds the hardened runtime and a timestamp for notarization.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP ($VERSION, build $BUILD)"
