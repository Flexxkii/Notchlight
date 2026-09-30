# Notchlight desktop widgets

Implementation and verification notes, 18 September 2026. The selected visual
references remain in `widget-handoff/`; those pre-existing files were preserved.

## What is implemented

One native WidgetKit configuration supports small and medium families. The small
widget shows one remaining allowance. The medium shows the five-hour/weekly pair
when available, or one centered ring when there is only one window. Both use
native SwiftUI shapes and text, the shipping icon, an opaque adaptive surface,
and static clockwise rings starting at twelve o'clock. WidgetKit owns the outer
container. No wallpaper, glass layers, charts, settings buttons, or timers are
embedded in the widget.

The widget always shows Remaining, without changing the app-wide Used/Remaining
preference or its Used default. Small widgets honor an available app selection;
otherwise the deterministic order is five-hour, weekly, calendar-month, then
other durations in ascending order. The medium uses the first two distinct
available windows in that order. A monthly-only value works on either family.

`WidgetShared` owns the versioned display snapshot, validation, selection,
freshness, serialization, and reset formatting. `WidgetViews` owns the native
views. `WidgetExtension` supplies the WidgetKit provider and entry point. The
host remains responsible for all Codex access. The extension links only the two
widget libraries; it has no Codex reader, credentials, networking entitlement,
or session-file access.

## Verified data-source limitation

The installed Codex app-server's generated `GetAccountRateLimitsResponse` schema
was inspected. Its `RateLimitWindow` contains `usedPercent`, optional
`windowDurationMins`, and optional `resetsAt`. It does **not** provide calendar-month
identity. A sanitized live read on this host exposed one **10,080-minute weekly**
window and no secondary window. No account identity or credential was saved in
that evidence.

The parser now accepts positive integral durations beyond 300 and 10,080 minutes.
Tests cover 28-, 29-, 30-, and 31-day durations. These retain duration labels such
as **30-day**; they are never inferred to be calendar months from a plan name or
duration. A typed `isCalendarMonth` flag supports explicit calendar-month data in
the model and synthetic fixtures, but the current duration-only parser never
sets it. A verified upstream field or documented source mapping is required
before live data can be labeled Monthly. The selected Monthly artwork is matched
by a clearly synthetic presentation fixture, not claimed as live monthly support.

Missing, boolean, malformed, non-finite percentages and missing/nonpositive or
fractional durations are unavailable. Real zero remains valid. Finite percentages
are clamped and the ring uses the same remaining value as the formatted number.
Reset timestamps remain optional; missing dates say “Reset unavailable,” and
expired dates say “Awaiting update.” No allowance or reset date is invented.

## Sharing, account changes, and freshness

The host atomically replaces a minimal JSON snapshot in a supported macOS app
group. Snapshot writes run on a serial actor, with ordered host requests. A
sandboxed, equivalently entitled validation app successfully read a real connected
snapshot from that container. The general shell was correctly denied direct
container access by macOS protection; that protection was not disabled.

Snapshot fields are percentages, durations/calendar semantics, reset/sample/write
times, selected window, connection state, and activity state/sample time. They do
not include email, account identifiers, raw errors, tokens, conversation content,
or session paths. The host compares an in-memory hash of `account/read` email
when available, and watches auth-file metadata to invalidate cached values on
account replacement, deletion, or modification. In-flight prior-generation reads
are discarded. Startup publishes an empty loading/disconnected snapshot before
reading the account. Disconnect writes an empty disconnected snapshot. A failed
limit fetch from a newly identified account cannot reuse the old account's data.

Transient failures within the same account retain last-successful values with a
visible **Stale · last known** label. Sign-in-required, disconnected, loading, and
unavailable are distinct empty states. Activity is Working or Idle only when its
observation is less than **five minutes** old and usage is current. Otherwise the
label is neutral. Usage expires after **15 minutes**, or immediately when a known
reset timestamp is reached. A clock jump beyond the 30-second future tolerance
also makes a sample stale. These durations are product policy, not freshness
promises from WidgetKit.

The existing activity observer supplies actual reconciled timestamps to the
widget without adding another polling loop or invalidating the overlay for
unchanged activity. Unchanged snapshot writes are coalesced to at most once per
minute; successful new usage samples and meaningful state/value changes persist
immediately. Host reload requests target only Notchlight's widget kind, following
meaningful changes or after four minutes to renew expiry information. The
provider requests a reload after 15 minutes and includes precomputed activity,
usage, and reset expiry entries. macOS controls actual delivery and may defer or
coalesce requests; activity is not a real-time task monitor. When the host is
stopped it cannot detect subsequent account changes, and cached values expire to
stale. A disconnect cannot synchronously erase WidgetKit's already rendered cache.

## Build and signing

The existing SwiftPM package, tests, Swift 6 mode, and macOS 14 minimum remain.
`./scripts/build-app.sh` now invokes `scripts/build-widgets.sh`. The latter uses
the installed Swift compiler and SDK to compile extension-safe shared/view
modules plus the native WidgetKit entry point, creates the `.appex` under
`Contents/PlugIns`, copies the app icon, and signs the extension before the host.
The executable enters through Foundation's `_NSExtensionMain`, matching Xcode's
app-extension product settings. Starting directly at Swift `main` compiled and
registered successfully but crashed during the system's descriptor query; the
installed gallery check caught this and the linker entry point is now corrected.
It does not require a generated Xcode project or third-party build dependency.

For working shared data, supply a team-backed signing identity:

```sh
NOTCHLIGHT_SIGNING_IDENTITY="Your Apple Development or Developer ID identity" ./scripts/build-app.sh
```

The build derives the team from that identity and adds
`<TEAM>.com.teodor.Notchlight.shared` to both bundles and entitlements. Apple
supports team-prefixed app groups on macOS without a provisioning profile. The
host remains unsandboxed for its existing integration; the extension is sandboxed
and has only its app-group entitlement. Signing alone does not notarize the app.
A local Apple Development identity was used for this validation. Public release
signing/notarization was not performed.

The previous default ad-hoc build is retained. It builds and embeds the extension
and explicitly warns that live app-group sharing requires a team identity; it
does not fabricate a group identifier or claim ad-hoc widgets are fully functional.
The packaged app is `build/Notchlight.app`. Launch it once, then use macOS's
**Edit Widgets** gallery to select Notchlight Usage and add either family.

The URL `notchlight://usage` is registered by the host and set once with
`widgetURL`. The AppKit delegate routes it to the existing Settings window and a
usage refresh. A pending cold-launch URL is delivered once the window action is
ready. Unknown URLs are ignored.

## Release 1.2.0 — 1 October 2026

The GitHub release now includes the signed host and embedded extension. Current
verification, log fixes, and validation limits are recorded in
[the 1.2.0 release notes](releases/1.2.0.md). App-group lookup now runs on the
writer actor, and healthy idle usage refreshes every five minutes.

## Earlier implementation validation — 18 September 2026

All checks below used arm64 macOS 27 / Xcode 27 / SDK 27, targeting macOS 14.

- `swift test`: the final result is recorded in `validation/widgets/verification.json`.
  Tests cover parser durations/invalids/resets, monthly-only and dual selection,
  percentages, freshness, disconnect/account changes, atomic snapshot round trips,
  ordered host publication, and cold/warm URL dispatch.
- Signed packaged-app build and strict deep signature verification passed.
  Both executable load commands retain minimum macOS 14.0 with SDK 27.0.
- `pluginkit` registered `com.teodor.Notchlight.Widgets` as a native extension.
  Both sizes were subsequently discovered in the real macOS widget gallery and
  added to Notification Center. They rendered the host's live
  weekly allowance; the medium correctly showed one centered ring.
  This establishes installed WidgetKit operation, with desktop placement tracked
  separately below.
- A sandboxed app with the extension's app-group entitlement read the host's live
  connected weekly snapshot. This verifies cross-process storage and authorization.
- Native `ImageRenderer` fixtures were inspected at 170×170 and 360×170 points,
  rendered at 2× scale. Small monthly, medium dual, medium single, stale, unknown
  activity, Idle, Working, and empty/error states fit in light and dark appearance.
  [Dark fixtures](validation/widgets/fixtures-dark.png),
  [light fixtures](validation/widgets/fixtures-light.png), and
  [vibrant view fixture](validation/widgets/fixtures-vibrant.png).
- Vibrant view output remains legible without relying on color. An off-host
  accented-mode render was blank, so that fixture does **not** establish actual
  system accented rendering behavior; this still needs WidgetKit-hosted testing.
- The installed accessibility tree exposed a remaining-allowance/reset label and “Status unavailable” in both sizes. Static views contain no animation
  or transparent material. Accessibility-tree inspection is not a VoiceOver
  speech/navigation test.
- After quitting the host, clicking the installed small widget launched the app
  and revealed its existing Settings/usage window. The actual cold-launch result
  was visually inspected, in addition to the existing cold/warm routing tests.

The user approved the AppleScript/System Events fallback. It enabled gallery
inspection and addition, alongside native UI actions. Desktop drag attempts have
not yet produced a confirmed desktop placement; that check remains pending.
Native UI inspection of the host still closes the tool's pipe, so screenshots and
the approved fallback were used to confirm the launch result. macOS 14/26 runtime,
Intel, VoiceOver navigation, and system accessibility appearance combinations
remain untested. No performance improvement or real-time refresh guarantee is
claimed.

Local build outputs and detailed logs: `build/widget-validation/`. Recreate visual
fixtures after a packaged build with `./scripts/validation/render-widget-fixtures.sh`.
These synthetic fixtures do not read or write the production shared snapshot.

## Platform references checked

- [Creating a widget extension](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension):
  static configuration, native Widget entry point, supported families, and launch-once
  gallery requirement. Article Markdown and the installed Xcode template were read.
- [Accessing app group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers):
  team-prefix authorization and supported macOS groups without provisioning profiles.
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date):
  system-controlled reload budgets and precomputed timeline entries. No per-minute
  widget refresh is promised.
- [widgetURL](https://developer.apple.com/documentation/swiftui/view/widgeturl(_:)):
  native containing-app opening mechanism, available on macOS 11 and later.

Installed SDK declarations were checked for `containerBackground(for: .widget)`,
`contentMarginsDisabled`, rendering modes, and `widgetAccentable`; all calls used
by the extension are available at the retained macOS 14 baseline.
