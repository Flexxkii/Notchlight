#!/bin/zsh
# Package the existing fixture for native UI checks and privacy-safe screenshots.
# Build the release app first with ./scripts/build-app.sh.
set -euo pipefail
fixture_project_dir="${0:A:h:h:h}"
cd "$fixture_project_dir"
fixture_app="$fixture_project_dir/build/screenshots/Notchlight Screenshots.app"
mkdir -p "$fixture_app/Contents/MacOS" "$fixture_app/Contents/Resources/Legal"
scripts/validation/build-settings-harness.sh "$fixture_app/Contents/MacOS/SettingsHarness"
cp Resources/Info.plist "$fixture_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable SettingsHarness' "$fixture_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.notchlight.screenshot-fixture' "$fixture_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$fixture_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Merge '$fixture_project_dir/build/app-icon-info.plist'" "$fixture_app/Contents/Info.plist"
cp build/app-icon/Assets.car build/app-icon/Notchlight.icns "$fixture_app/Contents/Resources/"
cp LICENSE TERMS.md PRIVACY.md THIRD_PARTY_NOTICES.md "$fixture_app/Contents/Resources/Legal/"
codesign --force --sign - "$fixture_app"
print "Created: $fixture_app"
