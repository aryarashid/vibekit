#!/bin/bash
# Builds a signed, notarized and stapled "Vibe-Kit.dmg" in ./build for a GitHub release.
#
# Needs a "Developer ID Application" certificate in the keychain and App Store Connect API
# credentials for notarization. Nothing secret lives in this repo. Pass them in the environment:
#
#   SIGN_IDENTITY   Developer ID identity name or SHA-1. Found automatically when there is one.
#   NOTARY_KEY      Path to the AuthKey_XXXX.p8 file.
#   NOTARY_KEY_ID   Its key ID.
#   NOTARY_ISSUER   Issuer ID, for a team key. Leave unset for an individual key.
#   NOTARY_PROFILE  Or a profile saved with `xcrun notarytool store-credentials`, instead of the three above.
#
# The fastlane names APP_STORE_CONNECT_API_KEY_KEY_FILEPATH, _KEY_ID and _ISSUER_ID work too.
#
#   VERSION=1.3.0 ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?Set VERSION, for example VERSION=1.3.0}"
export VERSION

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi
[[ -n "$SIGN_IDENTITY" ]] || { echo "No Developer ID Application identity in the keychain." >&2; exit 1; }

NOTARY_KEY="${NOTARY_KEY:-${APP_STORE_CONNECT_API_KEY_KEY_FILEPATH:-}}"
NOTARY_KEY="${NOTARY_KEY/#\~/$HOME}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-${APP_STORE_CONNECT_API_KEY_KEY_ID:-}}"
NOTARY_ISSUER="${NOTARY_ISSUER:-${APP_STORE_CONNECT_API_KEY_ISSUER_ID:-}}"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${NOTARY_KEY:?Set NOTARY_KEY, NOTARY_KEY_ID (and NOTARY_ISSUER for a team key), or NOTARY_PROFILE}"
  : "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID}"
  NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID")
  if [[ -n "$NOTARY_ISSUER" ]]; then NOTARY_AUTH+=(--issuer "$NOTARY_ISSUER"); fi
fi

APP="build/Vibe Kit.app"
DMG="build/Vibe-Kit.dmg"
STAGE="build/dmg"

notarize() {
  echo "Notarizing $1"
  xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --timeout 30m
}

# 1. Build a universal app signed with the Developer ID and the hardened runtime.
UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/build-app.sh
codesign --verify --strict --deep --verbose=2 "$APP"

# 2. Notarize the app and staple the ticket to it, so it opens without a network check.
rm -f build/VibeKit-notarize.zip
ditto -c -k --keepParent "$APP" build/VibeKit-notarize.zip
notarize build/VibeKit-notarize.zip
xcrun stapler staple "$APP"
rm -f build/VibeKit-notarize.zip

# 3. Wrap it in a disk image with an Applications shortcut to drag it onto.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Vibe Kit.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Vibe Kit" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

# 4. Sign, notarize and staple the disk image too.
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# 5. Check what Gatekeeper will say to someone who downloads it.
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"

echo "Built $DMG ($VERSION)"
shasum -a 256 "$DMG"
