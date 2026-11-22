# Releasing

Vibe Kit updates itself with [Sparkle 2](https://sparkle-project.org). Each GitHub release carries three files:

| File | For |
| --- | --- |
| `Vibe-Kit.dmg` | First-time downloads. Signed, notarized and stapled. |
| `Vibe-Kit-<version>.zip` | The Sparkle update. The notarized, stapled app, signed with the Sparkle EdDSA key. |
| `appcast.xml` | The update feed. The app reads it from `releases/latest/download/appcast.xml`. |

## Shipping a version

Bump `VERSION` (for example `1.3.0` to `1.4.0`) in a PR and merge it. The **Release** workflow then:

1. checks that `v1.4.0` has no release yet and that the secrets are set up,
2. runs the tests,
3. builds a universal app, signs it inside out with the Developer ID, and notarizes and staples it,
4. zips the stapled app, signs the zip with the Sparkle key, and checks that signature against the key in the app,
5. writes `appcast.xml` with GitHub's generated release notes,
6. creates the `v1.4.0` release as a draft with the three files, then publishes it as latest.

Installed copies find the update on their next daily check, or straight away from **Check for Updates…**.

Pushes to main that don't bump `VERSION` skip the release and stay green. Docs-only pushes don't start the workflow at all. Running the workflow from the Actions tab on `main` also releases, and fails loudly when secrets are missing. Non-`main` branches and tag pushes cannot trigger the release workflow, so signing secrets only ever run on trusted `main` commits.

**Versions.** `CFBundleShortVersionString` comes from `VERSION`. `CFBundleVersion` is `git rev-list --count HEAD`, which only goes up on main. Sparkle compares that number, and the workflow refuses a build that isn't newer than the one in the live appcast.

## One-time setup

The workflow needs these repository secrets:

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application certificate and its private key, exported from Keychain Access as a .p12, in base64. |
| `DEVELOPER_ID_P12_PASSWORD` | The password chosen when you exported it. |
| `NOTARY_KEY_P8` | The text of an App Store Connect API key (`AuthKey_XXXX.p8`) with Developer access. |
| `NOTARY_KEY_ID` | That key's ID. |
| `NOTARY_ISSUER_ID` | Its issuer ID. Only for team keys; leave it unset for an individual key. |
| `SPARKLE_PRIVATE_KEY` | The Sparkle EdDSA private key. The public key is worked out from it at build time. |

`scripts/setup-release-secrets.sh` uploads each one through `gh secret set` on stdin, so no value lands in your shell history or on disk:

```sh
scripts/setup-release-secrets.sh --sparkle                                   # once, ever
scripts/setup-release-secrets.sh --create-csr                                # make a new 5-year Developer ID cert
scripts/setup-release-secrets.sh --install-cer ~/Downloads/developerID_application.cer
# Or if you already exported a .p12 from Keychain Access:
scripts/setup-release-secrets.sh --developer-id ~/Desktop/DeveloperID.p12
scripts/setup-release-secrets.sh --notary ~/keys/AuthKey_ABC123.p8 ABC123 [ISSUER_ID]
scripts/setup-release-secrets.sh --check
```

**Look after the Sparkle key.** `--sparkle` makes the key pair with Sparkle's `generate_keys`, which keeps the private key in your login keychain. Every installed copy trusts only that key. If it's lost, installed copies can't update and people have to download the DMG again. Keep the keychain item, or export it with `generate_keys -x` to a password manager.

## Releasing from a Mac

`scripts/release.sh` does steps 3 to 5 locally with the same credentials, read from the environment (see the top of the script):

```sh
SPARKLE_PRIVATE_KEY_FILE=~/secure/sparkle-key NOTARY_PROFILE=vibekit ./scripts/release.sh
```

Then attach `build/Vibe-Kit.dmg`, `build/Vibe-Kit-<version>.zip` and `build/appcast.xml` to the `v<version>` release. **Every release that becomes latest needs its `appcast.xml`**, or update checks fail until the next one.

## Notes

- Builds without `SPARKLE_PUBLIC_KEY`, ad hoc local builds, debug builds, `swift run`, the CLI flags, `--snapshot` and tests never start Sparkle. Settings › Updates says why.
- 1.3.0 and older have no updater, so people on them need one manual download.
- The app sends no system profile. The only update traffic is a daily fetch of `appcast.xml` from GitHub, plus the download when there is an update.
