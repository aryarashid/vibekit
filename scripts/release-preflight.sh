#!/bin/bash
# Decides whether the release workflow should publish, before it spends time building.
#
# A push to main releases when the VERSION file names a version that has no GitHub release yet.
# Anything else on main (a fix without a version bump, or secrets not set up yet) skips with a
# note in the job summary and exits 0, so main never goes red for it. A `v*` tag push or a manual
# run means someone asked for a release, so missing secrets fail loudly.
#
# Reads EVENT_NAME, REF_TYPE and REF_NAME (GitHub's event, ref type and ref name), the release
# secrets as environment variables, and GH_TOKEN for `gh`. Writes publish, version, tag and build
# to $GITHUB_OUTPUT. For tests: PREFLIGHT_RELEASE_EXISTS=0|1 and PREFLIGHT_PREVIOUS_BUILD=<n|none>
# stand in for the GitHub lookups.
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRED_SECRETS=(DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD NOTARY_KEY_P8 NOTARY_KEY_ID SPARKLE_PRIVATE_KEY)
EVENT_NAME="${EVENT_NAME:-${GITHUB_EVENT_NAME:-workflow_dispatch}}"
REF_TYPE="${REF_TYPE:-${GITHUB_REF_TYPE:-branch}}"
REF_NAME="${REF_NAME:-${GITHUB_REF_NAME:-main}}"
REPO="${GITHUB_REPOSITORY:-aryarashid/vibekit}"
OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stderr}"

# Only a plain push to main may skip quietly. A tag or a manual run is an explicit request.
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

VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION holds \`$VERSION\`, not a version like 1.4.0."
TAG="v$VERSION"
output version "$VERSION"
output tag "$TAG"

if [[ "$REF_TYPE" == "tag" && "$REF_NAME" != "$TAG" ]]; then
  fail "Tag \`$REF_NAME\` doesn't match the VERSION file (\`$VERSION\`). Bump VERSION in the tagged commit."
fi

if [[ -n "${PREFLIGHT_RELEASE_EXISTS:-}" ]]; then
  EXISTS="$PREFLIGHT_RELEASE_EXISTS"
elif gh release view "$TAG" --repo "$REPO" --json tagName >/dev/null 2>&1; then
  EXISTS=1
else
  EXISTS=0
fi
if [[ "$EXISTS" == "1" ]]; then
  [[ "$EVENT_NAME" == "workflow_dispatch" ]] && fail "Vibe Kit $VERSION is already released. Bump VERSION to release again."
  skip "Vibe Kit $VERSION is already released. To ship what's on main, bump the VERSION file."
fi

MISSING=()
for name in "${REQUIRED_SECRETS[@]}"; do
  [[ -n "${!name:-}" ]] || MISSING+=("$name")
done
if (( ${#MISSING[@]} )); then
  list="$(printf '`%s`, ' "${MISSING[@]}")"
  message="these release secrets are not set up: ${list%, }. See docs/RELEASING.md, or run scripts/setup-release-secrets.sh."
  if (( STRICT )); then fail "Can't release Vibe Kit $VERSION: $message"; fi
  skip "Vibe Kit $VERSION would be released, but $message"
fi

# The build number is the commit count, so a shallow clone would make every build look like 1.
[[ "$(git rev-parse --is-shallow-repository)" == "false" ]] || fail "The checkout is shallow. Use fetch-depth: 0."
BUILD="$(git rev-list --count HEAD)"
if [[ -n "${PREFLIGHT_PREVIOUS_BUILD:-}" ]]; then
  PREVIOUS="$PREFLIGHT_PREVIOUS_BUILD"
else
  PREVIOUS="$(curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" 2>/dev/null \
    | sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' | sort -n | tail -1 || true)"
fi
if [[ -n "$PREVIOUS" && "$PREVIOUS" != "none" ]] && (( BUILD <= PREVIOUS )); then
  fail "Build $BUILD is not newer than build $PREVIOUS in the current appcast, so Sparkle would never offer it."
fi
output build "$BUILD"
output publish true
say "### Releasing Vibe Kit $VERSION (build $BUILD)"
