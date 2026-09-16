# Notchlight usage guide

Notchlight is a small macOS 14+ utility that draws a responsive border around a MacBook notch. It detects every notched display automatically, follows the display’s safe-area geometry, and supports click-through interaction. Click the notch border to open the native menu; hover shows the current Codex usage and exact reset date. Settings are persisted locally.

It uses AppKit’s display safe-area APIs and requires no extra dependency.

The settings window includes five ruler-like ticks at 0%, 25%, 50%, 75%, and 100% of the border path. You can enable them, choose their color, and adjust thickness and length. Advanced controls set the outward offset, top padding, and opacity; notch spacing moves the border and ticks together.

## Appearance controls

- **Start / End:** drag the sliders or type percentages from 0 to 100. On the notch, 0% is the top-left corner and 100% is the top-right, following the sides and bottom.
- **Border color:** choose any opaque color with the native macOS color picker. The preview, outline, and glow use the selected color.
- **Codex working color:** blue by default; temporarily replaces the normal border color while Codex is working.
- **Show only while Codex is working:** enable this to hide the border and ruler ticks when idle. **Hide after inactivity** keeps them visible after work stops for 1, 5, 10, 30, or 60 minutes, or hides them immediately. The default timeout is 1 minute. New activity cancels the timeout; the next idle period starts a fresh timeout. The notch menu and hover details stay available while the border is hidden.
- **Line weight, spacing, and soft glow:** adjust the outline’s appearance.
- **Busy glow:** when Codex is working, the notch border and settings preview pulse smoothly every 1.8 seconds. The glow stops when Codex becomes idle. Reduce Motion keeps the busy glow static.
- **Hide when swiping:** optional Input Monitoring support hides the border during desktop swipe transitions and restores it after the swipe finishes or is canceled. Permission is requested only when you press the Allow button. This passively observes private gesture fields that may change with macOS updates; if unavailable, the app uses the standard desktop-transition fallback.
- **Desktop transitions:** without swipe monitoring permission, the overlay hides in Mission Control and briefly fades/slides out when macOS reports a Space change, then eases back after the transition settles. Rapid switches postpone its return. Reduce Motion uses a fade without sliding. Public AppKit reports the Space change rather than a trackpad swipe's start or progress, so it cannot guarantee concealment from the first frame of an interactive swipe. The fallback remains available without Input Monitoring permission.

Changes apply immediately and persist across launches. Moving one endpoint past the other moves the other endpoint along with it. Equal percentages hide the line. Reset appearance restores the default red outline; while connected, Codex continues to control its length and glow.

## Requirements

- macOS 14 or later
- Xcode 26 or newer with Swift 6.2 or newer (includes the Icon Composer asset compiler)

## Run from source

```sh
swift run Notchlight
```

Run the test suite with:

```sh
swift test
```

## Build the app bundle

The packaging script builds a release binary, compiles the Ember Notch Icon Composer document at `Resources/Notchlight.icon`, creates `build/Notchlight.app`, and applies a local ad-hoc signature. It does not install anything into Applications.

To edit the shipping icon, open `Resources/Notchlight.icon` in Icon Composer and rebuild. The build uses Apple's `actool` to generate `Assets.car` and the `.icns` compatibility renditions with a macOS 14 minimum, then merges the compiler's icon metadata into the app's Info.plist. `swift run` launches an executable directly; use the packaged app to see its bundle icon. The script also bundles the license, terms, privacy policy, and third-party notices for offline access.

```sh
./scripts/build-app.sh
```

Pass `--open` only when you want the newly built app launched:

```sh
./scripts/build-app.sh --open
```

The implementation notes reference Apple’s [`NSScreen.auxiliaryTopLeftArea`](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea) and [`NSScreen.safeAreaInsets`](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets) APIs.

## Codex connection

The **Connect to Codex** switch lets account usage drive the border from 0% to the percentage already used. **Automatic** chooses the five-hour window when reported, otherwise the weekly window. You can also select a window explicitly. Missing limits are shown as unavailable, never as a measured 0%.

The app reads usage once per minute through the installed Codex CLI’s [local app-server account API](https://learn.chatgpt.com/docs/app-server). It uses your existing Codex sign-in, makes no model requests, and never reads or stores authentication tokens. Refresh failures retain the last known value with a warning in settings. Quit the app or disconnect to stop its monitoring.

Your color, line weight, and spacing stay adjustable while connected. Disconnecting restores your saved manual start, end, and glow settings.

Activity is checked every two seconds using local Codex task lifecycle metadata (`task_started`, `task_complete`, and `turn_aborted`). Only lifecycle state and timestamps are retained. The app reads the local task catalog without changing it and checks whether the Codex desktop app is running. Completed and interrupted tasks stop the glow. Unresolved activity older than 15 minutes becomes unavailable and stops glowing. This activity source depends on Codex’s local file format; remote-only work or future format changes may not be detected.

## Performance diagnostics

Diagnostic logging starts automatically and stays local to this Mac. In **Settings → Diagnostics**, you can turn recording off, reveal the logs, or export a ZIP containing the raw measurements, environment metadata, and a readable report. **Export diagnostics…** is also in the notch menu, so you can export without opening the animated settings preview. Exporting does not upload anything.

Logs live in `~/Library/Logs/Notchlight/Diagnostics/`. They rotate at 10 MiB and retain at most 24 hours or 50 MiB. Disabling recording keeps existing logs available for export. Avoid editing the active files; use an exported snapshot for analysis.

Every two seconds, Notchlight samples its CPU time, physical memory footprint, resident memory, disk I/O, page-ins, and wakeups. CPU uses the Activity Monitor convention: **100% is one fully occupied core**. Memory and CPU peaks are sampled peaks, so brief spikes between samples may be higher. Sleep, wake, restarts, missing samples, and logging errors are marked explicitly. The recorder batches disk writes and aggregates frequent mouse/render activity instead of logging every callback.

Each measurement is accompanied by automatic context: Codex connection and activity, overlay/pulse visibility, display and Reduce Motion configuration, hover/swipe/menu state, and settings visibility. Activity checks include file/cache counts and bytes read; usage refreshes include RPC timings and helper-process measurements. The short-lived `codex app-server` helper is tracked separately; its final CPU total or memory peak may be incomplete if it exits between observations. Timings and coincident resource changes indicate where to investigate, not proof that one operation caused all CPU work in that interval. GPU utilization and power in watts are not measured.

Only allowlisted performance metadata is saved. Logs exclude conversation text, RPC payloads, authentication tokens, account identifiers, task titles, and absolute paths to Codex session files.

For a useful 5–30 minute test, use the packaged **Release** app and spend a few minutes in each relevant state:

1. Disconnect Codex, close Settings, and leave the overlay idle.
2. Connect Codex and keep it idle long enough to include a one-minute usage refresh.
3. Run a Codex task with the busy glow visible and Settings closed.
4. Open Settings while Codex is working, then minimize or close it.
5. Hover the notch, open its menu, and switch desktops; optionally repeat with swipe monitoring enabled.

No test labels are needed. Export afterward and share the ZIP for investigation. The report groups automatically observed states and flags gaps, partial helper measurements, and mixed-state intervals. For deeper investigation, Instruments can record the matching signposts for activity checks, database work, usage refreshes, and RPC stages.
