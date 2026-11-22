#!/bin/bash
# One-time setup of the GitHub secrets the release workflow needs. Values go to `gh secret set`
# on stdin, never on a command line, in a file in the repo, or on screen.
#
#   scripts/setup-release-secrets.sh --check
#       List which release secrets the repo has (names only).
#
#   scripts/setup-release-secrets.sh --sparkle
#       Make the Sparkle EdDSA key pair with Sparkle's generate_keys (the private key stays in your
#       login keychain, which is its backup), then upload SPARKLE_PRIVATE_KEY. Run once, ever: a
#       new key would make every installed copy reject updates.
#
#   scripts/setup-release-secrets.sh --developer-id path/to/DeveloperID.p12
#       Upload a Developer ID Application certificate exported from Keychain Access with its
#       private key. Asks for the .p12 password.
#
#   scripts/setup-release-secrets.sh --notary path/to/AuthKey_XXXX.p8 KEY_ID [ISSUER_ID]
#       Upload an App Store Connect API key for notarization. Leave ISSUER_ID out for an individual key.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${GITHUB_REPOSITORY:-aryarashid/vibekit}"
NAMES=(DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID SPARKLE_PRIVATE_KEY)

put() { gh secret set "$1" --repo "$REPO" >/dev/null && echo "Set $1"; }

case "${1:-}" in
  --check)
    have="$(gh secret list --repo "$REPO" --json name --jq '.[].name')"
    for name in "${NAMES[@]}"; do
      if grep -qx "$name" <<< "$have"; then echo "set      $name"
      elif [[ "$name" == NOTARY_ISSUER_ID ]]; then echo "optional $name (team API keys only)"
      else echo "missing  $name"; fi
    done
    ;;
  --sparkle)
    tool_dir="$(dirname "$(scripts/sparkle.sh sign-update)")"
    if gh secret list --repo "$REPO" --json name --jq '.[].name' | grep -qx SPARKLE_PRIVATE_KEY; then
      echo "SPARKLE_PRIVATE_KEY is already set. Replacing it would break updates for everyone; delete it by hand first if you really mean to." >&2
      exit 1
    fi
    # Creates the key in the login keychain, or reuses the one already there.
    "$tool_dir/generate_keys"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    "$tool_dir/generate_keys" -x "$tmp/key" >/dev/null
    put SPARKLE_PRIVATE_KEY < "$tmp/key"
    echo "Public key: $(scripts/sparkle.sh public-key "$tmp/key")"
    echo "The release workflow puts it in the app's SUPublicEDKey. Keep the login keychain item; it is the only copy besides GitHub."
    ;;
  --developer-id)
    p12="${2:?Pass the .p12 file}"
    base64 < "$p12" | tr -d '\n' | put DEVELOPER_ID_P12_BASE64
    read -rsp "Password for $(basename "$p12"): " password; echo
    printf '%s' "$password" | put DEVELOPER_ID_P12_PASSWORD
    ;;
  --notary)
    p8="${2:?Pass the AuthKey .p8 file}"; key_id="${3:?Pass the key ID}"
    put NOTARY_KEY_P8 < "$p8"
    printf '%s' "$key_id" | put NOTARY_KEY_ID
    if [[ -n "${4:-}" ]]; then printf '%s' "$4" | put NOTARY_ISSUER_ID; fi
    ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
