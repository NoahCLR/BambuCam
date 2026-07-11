# Releasing BambuCam

Releases are signed, unnotarized app bundles distributed as a Homebrew **Cask**
through [NoahCLR/homebrew-tap](https://github.com/NoahCLR/homebrew-tap). The
full playbook, including the standing policies these scripts follow, lives in
that repo's `docs/PUBLISHING.md`.

## Prerequisites

- `gh` authenticated as the repo owner
- XcodeGen (`brew install xcodegen`)

No Apple Developer account is required: the app is signed with the stable
self-signed "BambuCam Local Code Signing" identity, which
`scripts/signing-common.sh` creates in the login keychain on first use (the
key is stored in `~/Library/Application Support/BambuCam/Signing/`). Keep that
identity forever — macOS permission grants are keyed to the signing
certificate, and changing it resets them for every user.

## Release

1. Bump `CFBundleShortVersionString` (full semver) and `CFBundleVersion` in
   `project.yml` under `info.properties`, run `xcodegen generate`, and commit —
   the tree must be clean.
2. Run:

   ```sh
   scripts/release.sh
   ```

   The script runs the BambuKit tests, builds a universal Release, signs it,
   zips it, pushes the `v<version>` tag, creates the GitHub release, and
   rewrites `Casks/bambucam.rb` in the tap with the new version and SHA-256.
   There is no manual cask-editing step.

## Verify

On the dev machine (see the tap's `PUBLISHING.md` Phase 4 for details):

```sh
brew update && brew install NoahCLR/tap/bambucam   # or brew upgrade bambucam
xattr -dr com.apple.quarantine /Applications/BambuCam.app
codesign --verify --deep --strict /Applications/BambuCam.app
open /Applications/BambuCam.app && sleep 3 && pgrep -x BambuCam
brew style --cask noahclr/tap/bambucam
```

Then pair a printer over a trusted LAN, confirm that
`~/Library/Application Support/BambuCam/config.json` contains no access code,
and confirm that a changed printer certificate blocks reconnecting until an
explicit new pairing.

Gatekeeper blocks the first launch of every quarantined copy (the app is not
notarized), including after each `brew upgrade` — the `xattr` line above or
System Settings → Privacy & Security → **Open Anyway** clears it.
