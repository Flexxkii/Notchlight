# Contributing to Notchlight

Issues and contributions are welcome under the licenses in LICENSE.
The project is source-available under two alternative PolyForm licenses.

## Before submitting code or artwork

Keep changes focused, preserve macOS 14 and Swift 6 support, and run `swift test`
and `./scripts/build-app.sh`. Include screenshots for visual changes and describe
what you actually tested. Never submit credentials, local Codex session files,
or private diagnostic exports. Identify external sources and their licenses.

## Contributor licensing

You retain copyright in your contribution. By submitting a contribution for
inclusion, you agree to offer it under both PolyForm Noncommercial License 1.0.0
and PolyForm Internal Use License 1.0.0, so recipients can choose either license
as described in LICENSE. The full, unmodified texts are in LICENSES/.

Confirm this in your pull request:

> I offer this contribution under both PolyForm Noncommercial License 1.0.0 and
> PolyForm Internal Use License 1.0.0. I have the authority to grant these rights
> and have identified any material covered by separate third-party terms.

Obtain any necessary employer or coauthor permission before submitting. There is
no copyright assignment or separate grant of broader relicensing rights to the
maintainer. Changes requiring additional rights need a separate agreement with
the relevant contributors. An issue report alone is not a contribution agreement.

## Legal text maintenance

LICENSES/ contains the unmodified upstream license texts. LICENSE includes the
project's license-selection notice and both complete texts. Do not edit the
standard terms. Keep applicable third-party notices intact.

The root LICENSE, TERMS.md, PRIVACY.md, and THIRD_PARTY_NOTICES.md are canonical
for the app. Run ./scripts/sync-legal.sh after editing them to refresh the
SwiftPM resource copies. ./scripts/sync-legal.sh --check checks for drift,
and app packaging performs that check before building.
