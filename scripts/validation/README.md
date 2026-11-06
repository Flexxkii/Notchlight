# Settings validation fixture

This standalone executable compiles the real Settings views and model with optimized Swift 6 settings. It uses a unique, disposable UserDefaults suite, synthetic 48% usage and activity, and disables Codex readers and the physical overlay. It does not change the shipping app or the user's appearance settings. Its menu is test scaffolding, not an application feature.

```sh
swift build -c release
scripts/validation/build-settings-harness.sh build/settings-harness
build/settings-harness --measure > build/settings-metrics.jsonl
```

The measurement takes about 72 seconds. Do not interact with the fixture during the run. Each phase settles for two seconds, then samples process CPU and wakeup counter deltas over ten seconds. Footprint is an endpoint sample. Phases: busy visible, minimized, closed, reopened, ordered out, idle visible. Every record includes actual AppKit visibility and miniaturization/occlusion state. The executable exits and deletes its temporary preferences when finished. Instruments should run separately to avoid contaminating these measurements.

For interactive validation, omit `--measure`. The fixture's menu offers light/dark content, 500×480 minimum content size (⌘1), default size (⌘2), deactivation (⌘3), busy/idle activity (⌘B), Settings (⌘,), and quit (⌘Q). Deactivation writes `inactive-state.json` beside the executable's app bundle (when packaged) to establish whether the window was key/visible. Use an actual window capture for screenshots; AppKit bitmap caching does not correctly capture all native SwiftUI effects.

Use real macOS System Settings for Reduce Motion, Reduce Transparency, Increase Contrast, and keyboard navigation. Record their initial values and restore them after testing. Do not grant Input Monitoring or other new permissions for this fixture.

## Release screenshots

After building the app, run `scripts/validation/package-settings-harness.sh`.
Open `build/screenshots/Notchlight Screenshots.app` for a packaged fixture with
the real icon and bundled legal documents. Use ⌘L for light/dark, ⌘J for legal
documents, and the standard screenshot tool to capture only its window. Quit
when finished to remove the temporary preferences. Sample usage is deliberately
labeled in the window title and README; no user account data is used.

To reproduce the original comparison, extract `build/macos-optimization/baseline/source-before.tar.gz` into a separate scratch directory and pass its `Sources/Notchlight` path as the second build-script argument. Keep the current fixture and unchanged library targets identical on both sides. The archive, compiled original fixture, and raw research are local generated artifacts; durable measurement results are under `docs/validation/macos-optimization/`.

The first exploratory run used a covering window from the same process; AppKit still reported the target as unoccluded. A deminiaturize/close sequence also raced restoration. Those samples were discarded, and the final sequence above was captured for both builds. Full occlusion is covered deterministically by the observer regression test; the hidden-window performance claim uses only minimized/closed/ordered-out samples with verified state.

## First-run notch hint

`NotchMenuHintHarness.swift` uses the production controller/view with a simulated
notch and no preferences or Codex connection. Quit the fixture before rebuilding.

```sh
swift build -c release
zsh scripts/validation/build-notch-hint-harness.sh
"build/notch-menu-hint-validation/Notch Hint Fixture.app/Contents/MacOS/NotchHintFixture" --verify
```

`--verify` checks presentation, placement, the panel's nonactivating behavior,
timeout, and no replay. Add `--without-focus` to exercise the case where the
fixture window loses keyboard focus. Verification failures print a `FAIL` message
and exit with status 1 instead of generating a macOS crash report. Interactive
previews do not run fatal test assertions and may be dismissed at any time.
For visual inspection, replace `--verify` with `--embedded --light` or
`--embedded --dark` (or `--embedded --contrast`). The embedded mode displays the
same production view inside the fixture window because CUA window captures omit
floating panels. Its dismiss button removes the preview and closes the controller's
panel. The fixture's interactive timeout is 45 seconds; production uses 12 seconds.
Accessibility preference toggles and physical-notch/Space interactions still
require actual system/hardware validation.

## Activity file notifications

`ActivityEventsHarness.swift` benchmarks the activity detector against 256
synthetic, unchanged session logs and a temporary SQLite catalog. It uses the
real FSEvents/vnode watchers and existing diagnostics, without changing preferences or
the user's Codex files. Codex Desktop must be running. The fixture excludes
border rendering, mouse tracking, Settings, and usage-limit requests.

Before editing the detector, save its release `CodexIntegration` and `Diagnostics`
modules/object files into a baseline products directory. Compile the same fixture
against each version:

```sh
zsh scripts/validation/build-activity-events-harness.sh build/activity-baseline /path/to/baseline-products legacy
swift build -c release
zsh scripts/validation/build-activity-events-harness.sh build/activity-events
build/activity-baseline 1
build/activity-events 1
build/activity-baseline --burst 1
build/activity-events --burst 1
```

Idle trials last 60 seconds after a two-second settling period. Run three trials
per version sequentially, without builds or profilers running. `ACTIVITY_SECONDS`
can shorten a smoke test; do not mix shortened samples into the comparison.
Burst trials keep the writer open while appending three start/completion pairs
and report each detection delay, matching Codex’s long-lived writer behavior.
JSON records include process CPU-time deltas, wakeup deltas, detector metadata
checks, reads, bytes, and latency. These are isolated detector measurements, not
a promised CPU percentage for the full application. Fixtures remove their own
temporary files and exit after each trial.

## Activity parsing and cached catalog recovery

`ActivityRecoveryHarness.swift` measures two isolated release workloads using
temporary synthetic data. Save the baseline release products before changing
the integration target, then compile this same harness against both versions:

```sh
swift build -c release
ditto "$(swift build -c release --show-bin-path)" build/activity-recovery-baseline-products
zsh scripts/validation/build-activity-recovery-harness.sh build/activity-recovery-before build/activity-recovery-baseline-products
# After implementing the change:
swift build -c release
zsh scripts/validation/build-activity-recovery-harness.sh build/activity-recovery-after
build/activity-recovery-before 1
build/activity-recovery-after 1
build/activity-recovery-before --wal 1
build/activity-recovery-after --wal 1
```

Run three trials per implementation sequentially, without concurrent builds,
tests, or profilers. The default scenario warms the filesystem/runtime once,
then reads a 7.9 MiB mixed log five times with fresh reader caches. It checks the
final lifecycle classification and reports elapsed time, process CPU time,
wakeups, and endpoint footprint. These are isolated reader measurements, not
full-app CPU or battery-life estimates.

`--wal` requires Codex Desktop to be running, but watches only the fixture's
temporary directory. After caching a valid catalog it removes the WAL through
SQLite's normal close behavior, measures query attempts for 12 seconds, then
recreates the WAL and appends a task-start event with both writers held open.
It checks that cached activity stayed available and reports recovery latency.
Diagnostics are enabled only in this scenario. The fixture changes no user
preferences or Codex data and removes its own temporary files on exit.
