#!/bin/bash
# Renders the README images from demo data into docs/images. No real servers or projects appear in them.
set -euo pipefail
cd "$(dirname "$0")/.."

# Run from the app bundle so the settings page shows the real version.
./scripts/build-app.sh >/dev/null
BIN="build/Vibe Kit.app/Contents/MacOS/VibeKit"
SHOTS=build/shots
mkdir -p "$SHOTS"

shot() { "$BIN" --snapshot "$SHOTS/$1" --demo --transparent "${@:2}" >/dev/null; }
shot list-dark.png --dark --select-port 8000
shot list-light.png --select-port 5173
shot details-dark.png --dark --expand-port 3000
shot details-light.png --expand-port 3000
shot settings-dark.png --dark --settings
shot settings-light.png --settings

swift scripts/make-readme-art.swift "$SHOTS" docs/images
