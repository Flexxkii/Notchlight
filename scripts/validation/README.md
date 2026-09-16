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
