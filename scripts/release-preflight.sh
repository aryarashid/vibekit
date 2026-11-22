#!/bin/bash
# Decides whether the release workflow should publish, before it spends time building.
#
# A push to main releases when the VERSION file names a version that has no GitHub release yet.
# Anything else on main (a fix without a version bump, or secrets not set up yet) skips with a
# note in the job summary and exits 0, so main never goes red for it. A manual run from main
# means someone asked for a release, so missing secrets fail loudly. Non-main refs always fail.
#
# Reads EVENT_NAME, REF_TYPE and REF_NAME (GitHub's event, ref type and ref name), secret presence
# booleans (`HAS_<SECRET>=true`, or the secret env var itself when invoked locally), and GH_TOKEN
# for `gh`. Writes publish, version, tag and build to $GITHUB_OUTPUT.
#
# Test overrides:
#   PREFLIGHT_RELEASE_EXISTS=0|1|draft
#   PREFLIGHT_TAG_COMMIT=<sha|none>
#   PREFLIGHT_HEAD_COMMIT=<sha>
#   PREFLIGHT_BUILD=<n>
#   PREFLIGHT_APPCAST_STATE=bootstrap|url|error
#   PREFLIGHT_APPCAST_FILE=<path>
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRED_SECRETS=(DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD NOTARY_KEY_P8 NOTARY_KEY_ID SPARKLE_PRIVATE_KEY)
EVENT_NAME="${EVENT_NAME:-${GITHUB_EVENT_NAME:-workflow_dispatch}}"
REF_TYPE="${REF_TYPE:-${GITHUB_REF_TYPE:-branch}}"
REF_NAME="${REF_NAME:-${GITHUB_REF_NAME:-main}}"
REPO="${GITHUB_REPOSITORY:-aryarashid/vibekit}"
OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stderr}"

# Only a plain push to main may skip quietly. A manual dispatch is an explicit request.
if [[ "$EVENT_NAME" == "push" && "$REF_TYPE" == "branch" ]]; then STRICT=0; else STRICT=1; fi

say() { printf '%s\n' "$*" >> "$SUMMARY"; }
output() { printf '%s=%s\n' "$1" "$2" >> "$OUTPUT"; }
skip() {
  say "### Release skipped"
  say ""
  say "$1"
  output publish false
  exit 0
}
fail() {
  echo "::error::$1"
  say "### Release failed"
  say ""
  say "$1"
  output publish false
  exit 1
}

if [[ "$REF_TYPE" != "branch" || "$REF_NAME" != "main" ]]; then
  fail "Releases may only run from \`main\` (got \`$REF_TYPE/$REF_NAME\`)."
fi

VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION holds \`$VERSION\`, not a version like 1.4.0."
TAG="v$VERSION"
output version "$VERSION"
output tag "$TAG"

if [[ -n "${PREFLIGHT_RELEASE_EXISTS:-}" ]]; then
  EXISTS="$PREFLIGHT_RELEASE_EXISTS"
elif DRAFT="$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null)"; then
  [[ "$DRAFT" == "true" ]] && EXISTS=draft || EXISTS=1
else
  EXISTS=0
fi
if [[ "$EXISTS" == "draft" ]]; then
  fail "A draft release already exists for \`$TAG\`. Inspect, publish, or delete it in GitHub Releases before rerunning."
elif [[ "$EXISTS" == "1" ]]; then
  [[ "$EVENT_NAME" == "workflow_dispatch" ]] && fail "Vibe Kit $VERSION is already released. Bump VERSION to release again."
  skip "Vibe Kit $VERSION is already released. To ship what's on main, bump the VERSION file."
fi

# Verify that any existing tag for this version points to the exact commit we are about to sign.
HEAD_SHA="${PREFLIGHT_HEAD_COMMIT:-$(git rev-parse HEAD)}"
if [[ -n "${PREFLIGHT_TAG_COMMIT:-}" ]]; then
  TAG_SHA="$PREFLIGHT_TAG_COMMIT"
  [[ "$TAG_SHA" == "none" ]] && TAG_SHA=""
else
  TAG_SHA="$(git rev-parse --verify -q "refs/tags/$TAG^{commit}" 2>/dev/null || true)"
fi
if [[ -n "$TAG_SHA" && "$TAG_SHA" != "$HEAD_SHA" ]]; then
  fail "Tag \`$TAG\` already points to \`${TAG_SHA:0:7}\`, not HEAD (\`${HEAD_SHA:0:7}\`). Move or remove the tag, or bump VERSION."
fi

MISSING=()
for name in "${REQUIRED_SECRETS[@]}"; do
  has_var="HAS_$name"
  if [[ "${!has_var:-}" == "true" || -n "${!name:-}" ]]; then
    continue
  fi
  MISSING+=("$name")
done
if (( ${#MISSING[@]} )); then
  list="$(printf '`%s`, ' "${MISSING[@]}")"
  message="these release secrets are not set up: ${list%, }. See docs/RELEASING.md, or run scripts/setup-release-secrets.sh."
  if (( STRICT )); then fail "Can't release Vibe Kit $VERSION: $message"; fi
  skip "Vibe Kit $VERSION would be released, but $message"
fi

# The build number is the commit count, so a shallow clone would make every build look like 1.
if [[ -n "${PREFLIGHT_BUILD:-}" ]]; then
  BUILD="$PREFLIGHT_BUILD"
else
  [[ "$(git rev-parse --is-shallow-repository)" == "false" ]] || fail "The checkout is shallow. Use fetch-depth: 0."
  BUILD="$(git rev-list --count HEAD)"
fi

# Compare against the live appcast. Only treat a missing feed as a first-feed bootstrap when the
# latest release is confirmed to have no appcast.xml asset (or the repo has no releases yet).
parse_appcast_build() {
  python3 - "$1" <<'EOF'
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
tree = ET.parse(sys.argv[1])
versions = []
for item in tree.findall(".//channel/item"):
    text = (item.findtext("sparkle:version", namespaces=ns) or "").strip()
    if text.isdigit():
        versions.append(int(text))
if not versions:
    sys.exit(1)
print(max(versions))
EOF
}

TMP_APPCAST=""
cleanup() { [[ -n "$TMP_APPCAST" ]] && rm -f "$TMP_APPCAST" || true; }
trap cleanup EXIT

PREVIOUS=""
if [[ "${PREFLIGHT_APPCAST_STATE:-}" == "bootstrap" ]]; then
  PREVIOUS="none"
elif [[ "${PREFLIGHT_APPCAST_STATE:-}" == "error" ]]; then
  fail "Couldn't fetch the live appcast to verify the build number."
elif [[ -n "${PREFLIGHT_APPCAST_FILE:-}" ]]; then
  PREVIOUS="$(parse_appcast_build "$PREFLIGHT_APPCAST_FILE" 2>/dev/null)" \
    || fail "The live appcast could not be parsed for a numeric sparkle:version."
else
  LATEST_ERR="$(mktemp)"
  if LATEST_ASSETS="$(gh release view --repo "$REPO" --json assets --jq '.assets[].name' 2>"$LATEST_ERR")"; then
    rm -f "$LATEST_ERR"
    if grep -qx "appcast.xml" <<< "$LATEST_ASSETS"; then
      TMP_APPCAST="$(mktemp)"
      curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" -o "$TMP_APPCAST" \
        || fail "Couldn't fetch releases/latest/download/appcast.xml to verify the build number."
      PREVIOUS="$(parse_appcast_build "$TMP_APPCAST" 2>/dev/null)" \
        || fail "The live appcast.xml does not contain a valid numeric sparkle:version."
    else
      PREVIOUS="none"
    fi
  else
    ERR_TEXT="$(cat "$LATEST_ERR")"
    rm -f "$LATEST_ERR"
    if grep -qi "release not found" <<< "$ERR_TEXT"; then
      PREVIOUS="none"
    else
      fail "Couldn't inspect the latest GitHub release to verify appcast history: $ERR_TEXT"
    fi
  fi
fi

if [[ -n "$PREVIOUS" && "$PREVIOUS" != "none" ]] && (( BUILD <= PREVIOUS )); then
  fail "Build $BUILD is not newer than build $PREVIOUS in the current appcast, so Sparkle would never offer it."
fi
output build "$BUILD"
output publish true
say "### Releasing Vibe Kit $VERSION (build $BUILD)"
