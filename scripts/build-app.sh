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
# The lid sleep helper: a second small program, installed as a root LaunchDaemon by the app.
swift build -c release --product VibeKitLidHelper ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Helpers"
cp "$BIN_DIR/VibeKit" "$APP/Contents/MacOS/VibeKit"
cp "$BIN_DIR/VibeKitLidHelper" "$APP/Contents/Helpers/VibeKitLidHelper"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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

# The helper runs as root from /Library/PrivilegedHelperTools, so it must need nothing but the
# system: no rpaths into this machine, no libraries of ours. The app also carries it to root
# inside one shell command, which caps its size, so drop the symbols it does not need to run.
HELPER="$APP/Contents/Helpers/VibeKitLidHelper"
helper_rpaths() { otool -l "$HELPER" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | sort -u; }
# Every library it uses is named by its full path, so it needs no search paths at all. Root
# should not be left looking for libraries in a toolchain folder.
while IFS= read -r rpath; do
  [[ -z "$rpath" ]] || install_name_tool -delete_rpath "$rpath" "$HELPER"
done <<< "$(helper_rpaths)"
[[ -z "$(helper_rpaths)" ]] || { echo "The lid sleep helper still has rpaths: $(helper_rpaths)" >&2; exit 1; }
strip -x "$HELPER"
# Library lines start with a tab. The lines naming the file and architecture do not.
OUTSIDE="$(otool -L "$HELPER" | awk -F'\t' '/^\t/ { split($2, part, " "); print part[1] }' | grep -Ev '^(/usr/lib/|/System/Library/)' || true)"
[[ -z "$OUTSIDE" ]] || { echo "The lid sleep helper links something outside the system: $OUTSIDE" >&2; exit 1; }
HELPER_BYTES="$(stat -f%z "$HELPER")"
(( HELPER_BYTES <= 600 * 1024 )) || { echo "The lid sleep helper is $HELPER_BYTES bytes, over the 600 KB the installer can carry." >&2; exit 1; }

# Sign inside out, never with --deep: Sparkle's helpers, the framework, our helper, then the app.
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
# The identifier is part of what the app and root check before the helper is installed
# (LidSleep.helperRequirement), so it must not follow the file name.
"${SIGN[@]}" --identifier dev.vibekit.lid-sleep "$HELPER"
"${SIGN[@]}" "$APP"

if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then UPDATES="updates on"; else UPDATES="updates off: no SPARKLE_PUBLIC_KEY"; fi
echo "Built $APP ($VERSION, build $BUILD, $UPDATES)"
