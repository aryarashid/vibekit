#!/bin/bash
# Builds Vibe Kit, installs it in /Applications (or ~/Applications), and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

DEST="/Applications"
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"

# Quit a running copy so the new one replaces it cleanly.
osascript -e 'tell application id "dev.vibekit.VibeKit" to quit' >/dev/null 2>&1 || true
pkill -x VibeKit >/dev/null 2>&1 || true
sleep 0.5

rm -rf "$DEST/Vibe Kit.app"
cp -R "build/Vibe Kit.app" "$DEST/"
open "$DEST/Vibe Kit.app"
echo "Installed $DEST/Vibe Kit.app. Look for the V in your menu bar, or press Control-Option-Command-V."
