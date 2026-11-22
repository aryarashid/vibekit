#!/bin/bash
# Builds "Vibe Kit.app" into ./build. Set UNIVERSAL=1 for an arm64 + x86_64 binary.
#
#   VERSION             Marketing version. Defaults to the VERSION file.
#   BUILD               CFBundleVersion. Defaults to the commit count, which only goes up on main.
#   SIGN_IDENTITY       Developer ID to sign with (hardened runtime + timestamp). Ad hoc when unset.
#   SPARKLE_PUBLIC_KEY  Base64 EdDSA public key for updates. Without it the app never checks for updates.
#   SPARKLE_FEED_URL    The appcast. Defaults to the one attached to the latest GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

# macOS 27's SwiftUI macros live in Xcode, not the standalone Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
REPO="${GITHUB_REPOSITORY:-aryarashid/vibekit}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/$REPO/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
APP="build/Vibe Kit.app"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
  ARCH_FLAGS=()
fi
swift build -c release --product VibeKit ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

# SwiftPM copies Sparkle.framework next to the binary. The resolved artifact is the fallback;
# both hold the same universal framework.
SPARKLE="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE" ]]; then
  SPARKLE="$(find .build/artifacts -type d -path '*macos-arm64_x86_64/Sparkle.framework' -print -quit)"
fi
[[ -d "$SPARKLE" ]] || { echo "Sparkle.framework not found. Run 'swift package resolve'." >&2; exit 1; }

# Redraw the icon when the drawing script is newer than the last one drawn.
[[ build/AppIcon.icns -nt scripts/make-icon.swift ]] || swift scripts/make-icon.swift build

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/VibeKit" "$APP/Contents/MacOS/VibeKit"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/lid-sleep-helper.sh "$APP/Contents/Resources/lid-sleep-helper.sh"

PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
# plutil, not sed: base64 keys and URLs contain slashes.
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD" "$PLIST"
plutil -replace SUFeedURL -string "$SPARKLE_FEED_URL" "$PLIST"
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$PLIST"
fi

# Find the framework in the bundle, and drop rpaths that point into this machine's .build folder.
BINARY="$APP/Contents/MacOS/VibeKit"
RPATHS="$(otool -l "$BINARY" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')"
while IFS= read -r rpath; do
  [[ "$rpath" == *"/.build/"* ]] && install_name_tool -delete_rpath "$rpath" "$BINARY"
done <<< "$RPATHS"
grep -qxF '@executable_path/../Frameworks' <<< "$RPATHS" || install_name_tool -add_rpath '@executable_path/../Frameworks' "$BINARY"

# Sign inside out, never with --deep: Sparkle's helpers, the framework, then the app.
# Ad hoc by default, which is fine for running locally. scripts/release.sh sets SIGN_IDENTITY to a
# Developer ID and this adds the hardened runtime and a timestamp for notarization.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  SIGN=(codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
else
  SIGN=(codesign --force --sign -)
fi
FW="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"
"${SIGN[@]}" "$APP"

if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then UPDATES="updates on"; else UPDATES="updates off: no SPARKLE_PUBLIC_KEY"; fi
echo "Built $APP ($VERSION, build $BUILD, $UPDATES)"
