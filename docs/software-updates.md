# Software updates

The packaged app uses Sparkle 2.10.1. **Check for Updates…** is available in the
application menu, notch menu, and Settings. The update dialog shows release
notes before installation and handles downloading, signature verification,
replacement, and relaunch. Preferences live outside the bundle and survive
updates. Automatic checks are off initially and can be enabled in Settings;
automatic unattended installation is disabled.

The feed is the `appcast.xml` asset of the latest GitHub release. Both the feed
and archive require Ed25519 signatures. Verification occurs before extraction.
The public key is embedded in `Resources/Info.plist`; the private key stays in
the maintainer's login Keychain under account `com.teodor.Notchlight.updates`.
No private key belongs in this repository, release assets, or CI logs.

## Preparing a release

1. Increment the marketing version and build number in `Resources/Info.plist`.
2. Write `docs/releases/<version>.md`.
3. Run the tests, native UI review, and packaging checks.
4. With the correct Apple signing identity configured, run
   `./scripts/package-release.sh`. It signs the archive and feed using the
   Keychain key and rejects a mismatch with the embedded public key.
5. Upload the ZIP, `SHA256SUMS.txt`, and `appcast.xml` to the matching `v<version>`
   GitHub release. Publish them together. The feed contains only that prepared
   release, avoiding accidental inclusion of old local test archives.
6. Download and verify the published assets, then check for updates from a
   packaged app. Exercise installation with a separately signed older fixture
   when the updater, signing, or packaging behavior changes.

`NOTCHLIGHT_UPDATE_KEY_ACCOUNT` can select another existing Keychain account,
but its public key must match the app. Back up the key securely using Sparkle's
documented process. Do not regenerate a release key to work around lost access.

`scripts/verify-update-package.py` checks nested helpers, signatures, team,
framework runpath, and updater policies. `scripts/verify-appcast.py` checks
metadata, the key, and cryptographic signatures. Sparkle rejects unsigned or
tampered content; the app never falls back to executing an unchecked download.

The current distribution uses Apple Development signing. Update signing does
not constitute Apple notarization. Developer ID/notarization remain separate
distribution work and are not claimed by this release.

References: [Sparkle setup](https://sparkle-project.org/documentation/),
[programmatic integration](https://sparkle-project.org/documentation/programmatic-setup/),
[nested code signing](https://sparkle-project.org/documentation/sandboxing/#code-signing).
