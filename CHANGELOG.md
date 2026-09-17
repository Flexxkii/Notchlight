# Changelog

## [1.1.0](https://github.com/Flexxkii/notchlight/releases/tag/v1.1.0) — 2026-09-17

Notchlight now fits more naturally into your day, with automatic startup,
a friendlier first launch, and less repeated work behind the scenes.

### Added

- **Launch at login.** Enable it in **Settings → General** to start Notchlight
  when you sign in. The native checkbox reflects macOS's current status and
  offers a shortcut to Login Items when approval is needed.
- **A first-run guide to the notch menu.** New installations show a short
  “Click your notch” hint. It disappears when the menu opens, when dismissed,
  or after 12 seconds. Existing users skip the hint.

### Improved

- **Activity tracking reacts to file changes.** Codex start, completion, and
  interruption events update the border without repeatedly scanning unchanged
  logs every two seconds. A periodic safety check and polling fallback keep
  detection resilient when notifications are unavailable.
- **A lighter animated preview.** Core Animation now drives the Settings
  glow, preserving its appearance while removing per-frame SwiftUI updates.
  Animation pauses when Settings is hidden and respects Reduce Motion.
- **Clearer documentation.** Expanded feature descriptions and instructions
  for launch at login and activity tracking.

### Fixed

- Activity tracking retries automatically when the local Codex task catalog
  is temporarily unavailable, including recovery after its WAL sidecar returns.
- Unchanged activity snapshots no longer trigger unnecessary UI updates.
- File replacement, truncation, dropped notifications, sleep/wake, and Codex
  restarts are covered by the activity observer's reconciliation and recovery.

[Release notes and download details](docs/releases/1.1.0.md)
· [All changes since 1.0.3](https://github.com/Flexxkii/notchlight/compare/v1.0.3...v1.1.0)

## [1.0.3](https://github.com/Flexxkii/notchlight/releases/tag/v1.0.3) — 2026-09-16

- Fixed old Codex logs being rescanned as new data after startup.
- Refreshed file metadata reliably detects appended events and truncation.

[Full release notes](docs/releases/1.0.3.md)

## [1.0.2](https://github.com/Flexxkii/notchlight/releases/tag/v1.0.2) — 2026-09-16

- Added a choice between used and remaining Codex allowance across the border,
  Settings preview, hover details, and notch menu.

[Full release notes](docs/releases/1.0.2.md)

## [1.0.1](https://github.com/Flexxkii/notchlight/releases/tag/v1.0.1) — 2026-09-16

- First public release, with customizable notch borders, Codex usage and
  activity, native Settings, local diagnostics, and bundled legal documents.

[Full release notes](docs/releases/1.0.1.md)
