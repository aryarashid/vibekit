#!/bin/bash
# Builds a signed, notarized and stapled release in ./build:
#
#   build/Vibe-Kit.dmg            for people downloading Vibe Kit for the first time
#   build/Vibe-Kit-<version>.zip  the Sparkle update archive, made from the stapled app
#   build/appcast.xml             the Sparkle feed, which goes on the GitHub release with both
#
# Needs a "Developer ID Application" certificate in the keychain and App Store Connect API
# credentials for notarization. Nothing secret lives in this repo. Pass them in the environment:
#
#   SIGN_IDENTITY             Developer ID identity name or SHA-1. Found automatically when there is one.
#   NOTARY_KEY                Path to the AuthKey_XXXX.p8 file.
#   NOTARY_KEY_ID             Its key ID.
#   NOTARY_ISSUER             Issuer ID, for a team key. Leave unset for an individual key.
#   NOTARY_PROFILE            Or a profile saved with `xcrun notarytool store-credentials`, instead of the three above.
#   SPARKLE_PRIVATE_KEY       The Sparkle EdDSA private key (what `generate_keys -x` exports), or
#   SPARKLE_PRIVATE_KEY_FILE  a file holding it. Without one the release can't update itself.
#   SPARKLE_PUBLIC_KEY        Optional. Derived from the private key, and checked against it if set.
#   RELEASE_NOTES_FILE        Optional Markdown shown in the update window.
#   GITHUB_REPOSITORY         owner/repo the release goes to. Defaults to aryarashid/vibekit.
#
# The fastlane names APP_STORE_CONNECT_API_KEY_KEY_FILEPATH, _KEY_ID and _ISSUER_ID work too.
#
#   VERSION=1.4.0 ./scripts/release.sh     (VERSION defaults to the VERSION file)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
export VERSION
BUILD="${BUILD:-$(git rev-list --count HEAD)}"
export BUILD
REPO="${GITHUB_REPOSITORY:-aryarashid/vibekit}"
export SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/$REPO/releases/latest/download/appcast.xml}"

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

# The Sparkle key goes to a private temporary file for sign_update, and is gone when this exits.
SPARKLE_KEY_FILE=""
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  SPARKLE_KEY_FILE="$WORK/sparkle-key"
  (umask 077 && printf '%s' "$SPARKLE_PRIVATE_KEY" > "$SPARKLE_KEY_FILE")
elif [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  SPARKLE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE/#\~/$HOME}"
fi
if [[ -n "$SPARKLE_KEY_FILE" ]]; then
  # Check the key pair before the slow part, so a mismatch can't ship an app that rejects its own updates.
  DERIVED="$(scripts/sparkle.sh public-key "$SPARKLE_KEY_FILE")"
  if [[ -n "${SPARKLE_PUBLIC_KEY:-}" && "$SPARKLE_PUBLIC_KEY" != "$DERIVED" ]]; then
    echo "SPARKLE_PUBLIC_KEY doesn't match SPARKLE_PRIVATE_KEY." >&2
    exit 1
  fi
  export SPARKLE_PUBLIC_KEY="$DERIVED"
  SIGN_UPDATE="$(scripts/sparkle.sh sign-update)"
else
  echo "warning: no SPARKLE_PRIVATE_KEY, so this release has no update key and will never update itself." >&2
fi

APP="build/Vibe Kit.app"
DMG="build/Vibe-Kit.dmg"
ZIP="build/Vibe-Kit-$VERSION.zip"
APPCAST="build/appcast.xml"
STAGE="build/dmg"

notarize() {
  echo "Notarizing $1"
  xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --timeout 30m
}

# 1. Build a universal app signed with the Developer ID and the hardened runtime.
UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/build-app.sh
codesign --verify --strict --deep --verbose=2 "$APP"
APP_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")"
[[ "$APP_FEED" == "$SPARKLE_FEED_URL" ]] || { echo "Embedded SUFeedURL ($APP_FEED) does not match $SPARKLE_FEED_URL." >&2; exit 1; }

# 2. Notarize the app and staple the ticket to it, so it opens without a network check.
rm -f build/VibeKit-notarize.zip
ditto -c -k --keepParent "$APP" build/VibeKit-notarize.zip
notarize build/VibeKit-notarize.zip
xcrun stapler staple "$APP"
rm -f build/VibeKit-notarize.zip

# 3. The Sparkle update: zip the stapled app, sign the exact bytes, and never touch the zip again.
rm -f "$ZIP" "$APPCAST"
if [[ -n "$SPARKLE_KEY_FILE" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" -p "$ZIP")"
  # Check it against the key inside the app, which is the one Sparkle will use.
  APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
  scripts/sparkle.sh verify "$ZIP" "$SIGNATURE" "$APP_KEY" || { echo "The update signature doesn't match the app's key." >&2; exit 1; }
  NOTES_ARGS=()
  if [[ -n "${RELEASE_NOTES_FILE:-}" ]]; then NOTES_ARGS=(--notes "$RELEASE_NOTES_FILE"); fi
  python3 scripts/make-appcast.py \
    --version "$VERSION" --build "$BUILD" \
    --url "https://github.com/$REPO/releases/download/v$VERSION/$(basename "$ZIP")" \
    --length "$(stat -f%z "$ZIP")" --signature "$SIGNATURE" \
    --min-os "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" \
    --release-page "https://github.com/$REPO/releases" \
    ${NOTES_ARGS[@]+"${NOTES_ARGS[@]}"} --output "$APPCAST"
fi

# 4. Wrap it in a disk image with an Applications shortcut to drag it onto.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Vibe Kit.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Vibe Kit" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

# 5. Sign, notarize and staple the disk image too.
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# 6. Check what Gatekeeper will say to someone who downloads it.
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"

echo "Built $DMG ($VERSION, build $BUILD)"
shasum -a 256 "$DMG"
if [[ -f "$ZIP" ]]; then
  echo "Built $ZIP and $APPCAST. Attach all three to the v$VERSION release; the app reads appcast.xml from the latest release."
fi
