#!/bin/zsh
# Add a real WidgetKit app extension to an already staged Notchlight.app.
set -euo pipefail
widget_project_dir="${0:A:h:h}"
widget_app="${1:?usage: build-widgets.sh APP_PATH}"
widget_build="${widget_project_dir}/build/widget-extension"
widget_extension="${widget_app}/Contents/PlugIns/NotchlightWidgets.appex"
widget_sdk=$(xcrun --sdk macosx --show-sdk-path)
widget_sdk_version=$(xcrun --sdk macosx --show-sdk-version)
widget_minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$widget_app/Contents/Info.plist")
widget_flags=(-O -parse-as-library -swift-version 6 -application-extension
    -target "$(uname -m)-apple-macos${widget_minimum}" -sdk "$widget_sdk")
mkdir -p "$widget_build" "$widget_extension/Contents/MacOS" "$widget_extension/Contents/Resources"
cd "$widget_project_dir"
print "Building the native WidgetKit extension..."
xcrun swiftc $widget_flags -whole-module-optimization -emit-object -emit-module \
    -module-name WidgetShared Sources/WidgetShared/*.swift \
    -emit-module-path "$widget_build/WidgetShared.swiftmodule" -o "$widget_build/WidgetShared.o"
xcrun swiftc $widget_flags -whole-module-optimization -emit-object -emit-module \
    -module-name WidgetViews -I "$widget_build" Sources/WidgetViews/*.swift \
    -emit-module-path "$widget_build/WidgetViews.swiftmodule" -o "$widget_build/WidgetViews.o"
# Match Xcode's app-extension entry point. Foundation bootstraps the extension
# before dispatching to the Swift @main widget; entering Swift main directly
# crashes ExtensionFoundation when WidgetKit launches the process.
xcrun swiftc $widget_flags -I "$widget_build" WidgetExtension/*.swift \
    "$widget_build/WidgetShared.o" "$widget_build/WidgetViews.o" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -platform_version -Xlinker macos -Xlinker "$widget_minimum" -Xlinker "$widget_sdk_version" \
    -o "$widget_extension/Contents/MacOS/NotchlightWidgets"
cp WidgetExtension/Info.plist "$widget_extension/Contents/Info.plist"
cp "$widget_app/Contents/Resources/Notchlight.icns" "$widget_extension/Contents/Resources/"
for widget_key in CFBundleShortVersionString CFBundleVersion; do
    widget_value=$(/usr/libexec/PlistBuddy -c "Print :${widget_key}" "$widget_app/Contents/Info.plist")
    /usr/libexec/PlistBuddy -c "Set :${widget_key} ${widget_value}" "$widget_extension/Contents/Info.plist"
done

widget_team=""
if [[ -n "${NOTCHLIGHT_SIGNING_IDENTITY:-}" ]]; then
    # Obtain the actual signing team without hardcoding personal identifiers.
    cp "$widget_extension/Contents/MacOS/NotchlightWidgets" "$widget_build/signing-probe"
    codesign --force --sign "$NOTCHLIGHT_SIGNING_IDENTITY" "$widget_build/signing-probe"
    widget_team=$(codesign -dv --verbose=4 "$widget_build/signing-probe" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    rm "$widget_build/signing-probe"
    if [[ -z "$widget_team" || "$widget_team" == "not set" ]]; then
        print -u2 "Widget data sharing requires a signing identity with an Apple development team."
        exit 1
    fi
else
    print -u2 "Widget extension compiled with ad-hoc signing. Live widgets require NOTCHLIGHT_SIGNING_IDENTITY for an authorized app group."
fi
python3 - "$widget_app" "$widget_extension" "$widget_build" "$widget_team" <<'PY'
import pathlib, plistlib, sys
app, extension, build = map(pathlib.Path, sys.argv[1:4])
team = sys.argv[4]
host_entitlements = {}
extension_entitlements = {'com.apple.security.app-sandbox': True}
if team:
    group = team + '.com.teodor.Notchlight.shared'
    for entitlements in [host_entitlements, extension_entitlements]:
        entitlements['com.apple.security.application-groups'] = [group]
    for bundle in [app, extension]:
        path = bundle / 'Contents/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['NotchlightAppGroup'] = group
        path.write_bytes(plistlib.dumps(info))
for name, entitlements in [('host', host_entitlements), ('extension', extension_entitlements)]:
    (build / (name + '.entitlements')).write_bytes(plistlib.dumps(entitlements))
PY
plutil -lint "$widget_extension/Contents/Info.plist"
if [[ -n "${NOTCHLIGHT_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$NOTCHLIGHT_SIGNING_IDENTITY" \
        --entitlements "$widget_build/extension.entitlements" "$widget_extension"
else
    codesign --force --sign - --entitlements "$widget_build/extension.entitlements" "$widget_extension"
fi
codesign --verify --strict --verbose=2 "$widget_extension"
