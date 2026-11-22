#!/bin/bash
# Small Sparkle helpers for scripts/release.sh and the release workflow.
#
#   scripts/sparkle.sh public-key <private-key-file>         Print the base64 public key for a Sparkle private key.
#   scripts/sparkle.sh verify <file> <signature> <public-key> Check an EdDSA signature the way Sparkle will.
#   scripts/sparkle.sh sign-update                            Print the path to Sparkle's sign_update tool.
#
# The private key file is what `generate_keys -x` exports: a base64 Ed25519 seed. Needs OpenSSL 3
# (Homebrew's, on GitHub's macOS runners); the LibreSSL in /usr/bin has no Ed25519.
set -euo pipefail
cd "$(dirname "$0")/.."

openssl_bin() {
  local candidate
  for candidate in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    if command -v "$candidate" >/dev/null && "$candidate" version 2>/dev/null | grep -q '^OpenSSL [3-9]'; then
      command -v "$candidate"
      return
    fi
  done
  echo "Needs OpenSSL 3 or later for Ed25519: brew install openssl@3" >&2
  exit 1
}

decode() { base64 -D 2>/dev/null || base64 --decode; }

case "${1:-}" in
  public-key)
    file="${2:?Pass the private key file}"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    tr -d '[:space:]' < "$file" | decode > "$tmp/seed"
    case "$(wc -c < "$tmp/seed" | tr -d ' ')" in
      32)
        { printf '302e020100300506032b657004220420' | xxd -r -p; cat "$tmp/seed"; } > "$tmp/key.der"
        "$(openssl_bin)" pkey -inform DER -in "$tmp/key.der" -pubout -outform DER | tail -c 32 | base64
        ;;
      96)
        # Sparkle's older export: 64 bytes of private key, then the 32-byte public key.
        tail -c 32 "$tmp/seed" | base64
        ;;
      *)
        echo "That isn't a Sparkle private key (expected base64 of 32 or 96 bytes)." >&2
        exit 1
        ;;
    esac
    ;;
  verify)
    file="${2:?Pass the file}"; signature="${3:?Pass the signature}"; public="${4:?Pass the public key}"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    { printf '302a300506032b6570032100' | xxd -r -p; printf '%s' "$public" | decode; } > "$tmp/pub.der"
    printf '%s' "$signature" | decode > "$tmp/sig"
    "$(openssl_bin)" pkeyutl -verify -pubin -inkey "$tmp/pub.der" -keyform DER -rawin -in "$file" -sigfile "$tmp/sig" >/dev/null
    ;;
  sign-update)
    tool="$(find .build/artifacts -type f -path '*/bin/sign_update' -print -quit 2>/dev/null || true)"
    if [[ -z "$tool" ]]; then
      swift package resolve >/dev/null
      tool="$(find .build/artifacts -type f -path '*/bin/sign_update' -print -quit)"
    fi
    [[ -x "$tool" ]] || { echo "sign_update not found. Run 'swift package resolve'." >&2; exit 1; }
    echo "$tool"
    ;;
  *)
    sed -n '2,9p' "$0" >&2
    exit 2
    ;;
esac
