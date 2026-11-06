#!/bin/zsh
# Prepare isolated, signed old/new apps and a loopback-only signed test feed.
set -euo pipefail
fixture_root="${0:A:h:h:h}"
cd "$fixture_root"
: "${NOTCHLIGHT_SIGNING_IDENTITY:?Set a team-backed signing identity}"
fixture_dir="$fixture_root/build/update-validation"
fixture_framework="$fixture_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
mkdir -p "$fixture_dir/installed" "$fixture_dir/server" "$fixture_dir/new"
xcrun swiftc -O -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos14.0" \
    -F "$fixture_framework" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/Notchlight/App/UpdateController.swift Sources/Notchlight/Views/UpdateSettingsView.swift \
    scripts/validation/UpdateHarness.swift -o "$fixture_dir/UpdateHarness"
for fixture_kind in installed new; do
    fixture_app="$fixture_dir/$fixture_kind/Notchlight Update Test.app"
    if [[ -e "$fixture_app" ]]; then
        print -u2 "Fixture already exists; preserve or move it before rebuilding: $fixture_app"
        exit 1
    fi
    ditto build/Notchlight.app "$fixture_app"
    rm "$fixture_app/Contents/MacOS/Notchlight"
    cp "$fixture_dir/UpdateHarness" "$fixture_app/Contents/MacOS/UpdateHarness"
    python3 - "$fixture_app/Contents/Info.plist" "$fixture_kind" <<'PY'
import pathlib, plistlib, sys
p = pathlib.Path(sys.argv[1]); d = plistlib.loads(p.read_bytes())
d.update(CFBundleExecutable='UpdateHarness', CFBundleIdentifier='com.notchlight.updater-validation',
         CFBundleName='Notchlight Update Test', CFBundleDisplayName='Notchlight Update Test', LSUIElement=False,
         SUFeedURL='http://127.0.0.1:8769/appcast.xml',
         NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
if sys.argv[2] == 'installed':
    d.update(CFBundleVersion='10', CFBundleShortVersionString='1.2.9')
p.write_bytes(plistlib.dumps(d))
PY
    codesign --force --options runtime --timestamp --sign "$NOTCHLIGHT_SIGNING_IDENTITY" "$fixture_app"
    codesign --verify --deep --strict "$fixture_app"
done
ditto -c -k --sequesterRsrc --keepParent "$fixture_dir/new/Notchlight Update Test.app" "$fixture_dir/server/UpdateTest.zip"
print 'Update fixture: signed download, install, relaunch, and preserved settings.' > "$fixture_dir/server/UpdateTest.md"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --account com.teodor.Notchlight.updates \
    --download-url-prefix http://127.0.0.1:8769/ --embed-release-notes --maximum-deltas 0 "$fixture_dir/server"
cp "$fixture_dir/server/appcast.xml" "$fixture_dir/valid-appcast.xml"
print "Prepared $fixture_dir. Serve server/ on 127.0.0.1:8769 and open the installed fixture."
