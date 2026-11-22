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
#   scripts/setup-release-secrets.sh --create-csr [--force]
#       Generate a local RSA-2048 private key and Certificate Signing Request (CSR) to create a new
#       5-year Developer ID Application certificate at developer.apple.com.
#
#   scripts/setup-release-secrets.sh --install-cer path/to/developerID_application.cer
#       Pair the downloaded .cer with the key from --create-csr, import it into your login keychain
#       (with Apple's Developer ID G2 intermediate CA), export a macOS-compatible .p12 in memory,
#       upload DEVELOPER_ID_P12_BASE64 and DEVELOPER_ID_P12_PASSWORD, and delete the temp key.
#
#   scripts/setup-release-secrets.sh --developer-id path/to/DeveloperID.p12
#       Upload a Developer ID Application certificate exported from Keychain Access with its
#       private key. Asks for the .p12 password, and imports it locally if this Mac lacks one.
#
#   scripts/setup-release-secrets.sh --notary path/to/AuthKey_XXXX.p8 KEY_ID [ISSUER_ID]
#       Upload an App Store Connect API key for notarization. Leave ISSUER_ID out for an individual key.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${GITHUB_REPOSITORY:-aryarashid/vibekit}"
CSR_DIR="${VIBEKIT_CSR_DIR:-$HOME/.vibekit-devid-csr}"
# Always use macOS's built-in LibreSSL so exported .p12 files stay compatible with security(1)
# even when Homebrew OpenSSL 3/4 is first on PATH.
OPENSSL=/usr/bin/openssl
NAMES=(DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID SPARKLE_PRIVATE_KEY)

put() { gh secret set "$1" --repo "$REPO" >/dev/null && echo "Set $1"; }

ensure_g2_ca() {
  local keychain="$HOME/Library/Keychains/login.keychain-db"
  if security find-certificate -c "Developer ID Certification Authority" -a "$keychain" >/dev/null 2>&1; then
    return 0
  fi
  local g2="$1/DeveloperIDG2CA.cer"
  curl -fsSL https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o "$g2"
  security import "$g2" -k "$keychain" >/dev/null 2>&1 || true
}

case "${1:-}" in
  --check)
    have="$(gh secret list --repo "$REPO" --json name --jq '.[].name')"
    for name in "${NAMES[@]}"; do
      if grep -qx "$name" <<< "$have"; then echo "set      $name"
      elif [[ "$name" == NOTARY_ISSUER_ID ]]; then echo "optional $name (team API keys only)"
      else echo "missing  $name"; fi
    done
    ;;
  --create-csr)
    key="$CSR_DIR/devid.key"
    csr="$CSR_DIR/VibeKit-DeveloperID.certSigningRequest"
    if [[ -f "$key" && "${2:-}" != "--force" ]]; then
      echo "A pending key already exists at $key." >&2
      echo "Upload $csr, or pass --force to replace it." >&2
      exit 1
    fi
    (umask 077 && mkdir -p "$CSR_DIR")
    chmod 700 "$CSR_DIR"
    (umask 077 && "$OPENSSL" genrsa -out "$key" 2048 2>/dev/null)
    "$OPENSSL" req -new -key "$key" -subj "/CN=Vibe Kit Developer ID/O=Vibe Kit" -out "$csr"
    echo "Created CSR: $csr"
    echo
    echo "Next steps:"
    echo "  1. Open https://developer.apple.com/account/resources/certificates/add"
    echo "  2. Select 'Developer ID Application', upload the CSR above, and download the .cer file."
    echo "  3. Run: scripts/setup-release-secrets.sh --install-cer ~/Downloads/developerID_application.cer"
    ;;
  --install-cer)
    cer="${2:?Pass the downloaded .cer file}"
    key="$CSR_DIR/devid.key"
    [[ -f "$cer" ]] || { echo "Certificate file not found: $cer" >&2; exit 1; }
    [[ -f "$key" ]] || { echo "Pending private key not found at $key. Run --create-csr first." >&2; exit 1; }
    tmp="$(mktemp -d)"
    chmod 700 "$tmp"
    verify_kc="$tmp/verify.keychain-db"
    cleanup() {
      security delete-keychain "$verify_kc" >/dev/null 2>&1 || true
      rm -rf "$tmp"
    }
    trap cleanup EXIT

    pem="$tmp/cert.pem"
    if "$OPENSSL" x509 -in "$cer" -inform PEM -out "$pem" >/dev/null 2>&1; then
      :
    elif "$OPENSSL" x509 -in "$cer" -inform DER -out "$pem" >/dev/null 2>&1; then
      :
    else
      echo "Could not read $cer as a PEM or DER X.509 certificate." >&2
      exit 1
    fi

    subject="$("$OPENSSL" x509 -in "$pem" -noout -subject)"
    if [[ "$subject" != *"Developer ID Application"* ]]; then
      echo "Expected a 'Developer ID Application' certificate, got: $subject" >&2
      exit 1
    fi

    cert_mod="$("$OPENSSL" x509 -in "$pem" -noout -modulus | "$OPENSSL" sha256)"
    key_mod="$("$OPENSSL" rsa -in "$key" -noout -modulus 2>/dev/null | "$OPENSSL" sha256)"
    if [[ "$cert_mod" != "$key_mod" ]]; then
      echo "This certificate does not match the private key in $key." >&2
      exit 1
    fi

    pass_file="$tmp/p12.pass"
    (umask 077 && "$OPENSSL" rand -base64 36 | tr -d '/+=\n' | head -c 32 > "$pass_file")
    p12="$tmp/DeveloperID.p12"
    (umask 077 && "$OPENSSL" pkcs12 -export -inkey "$key" -in "$pem" -out "$p12" -passout "file:$pass_file")

    # Verify macOS security(1) can import and pair the exported .p12 before uploading.
    verify_pass="$("$OPENSSL" rand -hex 16)"
    p12_pass="$(cat "$pass_file")"
    security create-keychain -p "$verify_pass" "$verify_kc"
    security unlock-keychain -p "$verify_pass" "$verify_kc"
    security import "$p12" -k "$verify_kc" -P "$p12_pass" -A >/dev/null
    if ! security find-identity -p codesigning "$verify_kc" | grep -q "Developer ID Application"; then
      echo "Exported .p12 failed macOS keychain verification." >&2
      exit 1
    fi

    if [[ "${SKIP_KEYCHAIN_IMPORT:-0}" != "1" ]]; then
      ensure_g2_ca "$tmp"
      security import "$p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P "$p12_pass" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
      echo "Imported Developer ID Application identity into login keychain."
    fi

    if [[ "${SKIP_GH_UPLOAD:-0}" != "1" ]]; then
      base64 < "$p12" | tr -d '\n' | put DEVELOPER_ID_P12_BASE64
      put DEVELOPER_ID_P12_PASSWORD < "$pass_file"
    fi

    rm -rf "$CSR_DIR"
    echo "Removed temporary private key folder $CSR_DIR."
    if [[ "${SKIP_KEYCHAIN_IMPORT:-0}" != "1" ]]; then
      security find-identity -v -p codesigning | grep "Developer ID Application" || true
    fi
    if [[ "${SKIP_GH_UPLOAD:-0}" != "1" ]]; then
      "$0" --check
    fi
    ;;
  --sparkle)
    tool_dir="$(dirname "$(scripts/sparkle.sh sign-update)")"
    have="$(gh secret list --repo "$REPO" --json name --jq '.[].name')"
    if grep -qx SPARKLE_PRIVATE_KEY <<< "$have"; then
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
    if [[ "${SKIP_KEYCHAIN_IMPORT:-0}" != "1" ]] \
      && ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT
      ensure_g2_ca "$tmp"
      security import "$p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P "$password" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
      echo "Imported Developer ID Application identity into login keychain."
    fi
    ;;
  --notary)
    p8="${2:?Pass the AuthKey .p8 file}"; key_id="${3:?Pass the key ID}"
    put NOTARY_KEY_P8 < "$p8"
    printf '%s' "$key_id" | put NOTARY_KEY_ID
    if [[ -n "${4:-}" ]]; then
      printf '%s' "$4" | put NOTARY_ISSUER_ID
    else
      have="$(gh secret list --repo "$REPO" --json name --jq '.[].name')"
      if grep -qx NOTARY_ISSUER_ID <<< "$have"; then
        gh secret delete NOTARY_ISSUER_ID --repo "$REPO" >/dev/null
        echo "Removed stale NOTARY_ISSUER_ID (individual keys must not pass --issuer)"
      fi
    fi
    ;;
  *)
    sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
