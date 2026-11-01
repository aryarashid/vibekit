#!/bin/bash
# Builds "Vibe Kit.app" into ./build. Set UNIVERSAL=1 for an arm64 + x86_64 binary.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/Vibe Kit.app"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --product VibeKit --arch arm64 --arch x86_64
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release --product VibeKit
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

[[ -f build/AppIcon.icns ]] || swift scripts/make-icon.swift build

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VibeKit" "$APP/Contents/MacOS/VibeKit"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc signature. Fine for running locally; a release would use a Developer ID and notarization.
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION, build $BUILD)"
