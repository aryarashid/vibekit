#!/bin/bash
# Checks the release helpers without any secrets or network: the preflight decisions, and a
# throwaway Sparkle key signing an archive and an appcast. Run by CI.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
check() {
  local name="$1" expected_rc="$2" expected_publish="$3"; shift 3
  local out="$tmp/out" rc=0
  : > "$out"
  env -u DEVELOPER_ID_P12_BASE64 -u DEVELOPER_ID_P12_PASSWORD -u NOTARY_KEY_P8 -u NOTARY_KEY_ID -u SPARKLE_PRIVATE_KEY \
    GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$tmp/summary" "$@" scripts/release-preflight.sh >/dev/null 2>&1 || rc=$?
  local publish
  publish="$(sed -n 's/^publish=//p' "$out" | tail -1)"
  if [[ "$rc" == "$expected_rc" && "$publish" == "$expected_publish" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $rc, publish=$publish (wanted exit $expected_rc, publish=$expected_publish)"
    sed 's/^/     /' "$tmp/summary" 2>/dev/null || true
    fails=$((fails + 1))
  fi
  rm -f "$tmp/summary"
}

version="$(tr -d '[:space:]' < VERSION)"
secrets=(DEVELOPER_ID_P12_BASE64=x DEVELOPER_ID_P12_PASSWORD=x NOTARY_KEY_P8=x NOTARY_KEY_ID=x SPARKLE_PRIVATE_KEY=x)
main=(EVENT_NAME=push REF_TYPE=branch REF_NAME=main PREFLIGHT_PREVIOUS_BUILD=none)
tag=(EVENT_NAME=push REF_TYPE=tag "REF_NAME=v$version" PREFLIGHT_PREVIOUS_BUILD=none)
manual=(EVENT_NAME=workflow_dispatch REF_TYPE=branch REF_NAME=main PREFLIGHT_PREVIOUS_BUILD=none)

check "main, no secrets: skip green"            0 false "${main[@]}" PREFLIGHT_RELEASE_EXISTS=0
check "main, already released: skip green"      0 false "${main[@]}" PREFLIGHT_RELEASE_EXISTS=1
check "main, new version + secrets: publish"    0 true  "${main[@]}" PREFLIGHT_RELEASE_EXISTS=0 "${secrets[@]}"
check "manual, no secrets: fail"                1 false "${manual[@]}" PREFLIGHT_RELEASE_EXISTS=0
check "manual, already released: fail"          1 false "${manual[@]}" PREFLIGHT_RELEASE_EXISTS=1 "${secrets[@]}"
check "tag, no secrets: fail"                   1 false "${tag[@]}" PREFLIGHT_RELEASE_EXISTS=0
check "tag, secrets: publish"                   0 true  "${tag[@]}" PREFLIGHT_RELEASE_EXISTS=0 "${secrets[@]}"
check "tag not matching VERSION: fail"          1 false EVENT_NAME=push REF_TYPE=tag REF_NAME=v0.0.1 PREFLIGHT_RELEASE_EXISTS=0 "${secrets[@]}"
check "build not newer than appcast: fail"      1 false "${main[@]}" PREFLIGHT_RELEASE_EXISTS=0 PREFLIGHT_PREVIOUS_BUILD=999999 "${secrets[@]}"

# A throwaway key signs a fake archive; the signature checks out against the derived public
# key, a tampered archive does not, and the appcast is well-formed with the right fields.
openssl rand -base64 32 > "$tmp/key"
public="$(scripts/sparkle.sh public-key "$tmp/key")"
head -c 4096 /dev/urandom > "$tmp/update.zip"
signature="$("$(scripts/sparkle.sh sign-update)" --ed-key-file "$tmp/key" -p "$tmp/update.zip")"
if scripts/sparkle.sh verify "$tmp/update.zip" "$signature" "$public"; then echo "ok   signature verifies"; else echo "FAIL signature"; fails=$((fails + 1)); fi
echo x >> "$tmp/update.zip"
if scripts/sparkle.sh verify "$tmp/update.zip" "$signature" "$public" 2>/dev/null; then echo "FAIL tampered archive verified"; fails=$((fails + 1)); else echo "ok   tampered archive rejected"; fi

printf '## What changed\n\n* Fixes & things ]]> <b>\n' > "$tmp/notes.md"
python3 scripts/make-appcast.py --version 9.9.9 --build 4242 --url "https://example.com/Vibe Kit & co.zip" \
  --length 4097 --signature "$signature" --notes "$tmp/notes.md" --release-page https://example.com/releases --output "$tmp/appcast.xml"
if python3 - "$tmp/appcast.xml" "$signature" <<'EOF'
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
item = ET.parse(sys.argv[1]).find("channel/item")
enc = item.find("enclosure")
assert item.findtext("sparkle:version", namespaces=ns) == "4242"
assert item.findtext("sparkle:shortVersionString", namespaces=ns) == "9.9.9"
assert enc.get("url") == "https://example.com/Vibe Kit & co.zip"
assert enc.get("length") == "4097"
assert enc.get("{%s}edSignature" % ns["sparkle"]) == sys.argv[2]
assert "Fixes & things ]]> <b>" in item.findtext("description")
EOF
then echo "ok   appcast parses"; else echo "FAIL appcast"; fails=$((fails + 1)); fi

(( fails == 0 )) || { echo "$fails failed"; exit 1; }
echo "All release script checks passed"
