#!/bin/zsh
set -euo pipefail
widget_project="${0:A:h:h:h}"
cd "$widget_project"
widget_build="$widget_project/build/widget-extension"
widget_fixture="$widget_project/build/widget-validation/WidgetFixtures.app"
mkdir -p "$widget_fixture/Contents/MacOS" "$widget_fixture/Contents/Resources"
cp build/Notchlight.app/Contents/Resources/Notchlight.icns "$widget_fixture/Contents/Resources/"
xcrun swiftc -O -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -I "$widget_build" \
    scripts/validation/WidgetRenderingHarness.swift "$widget_build/WidgetShared.o" "$widget_build/WidgetViews.o" \
    -o "$widget_fixture/Contents/MacOS/WidgetFixtures"
"$widget_fixture/Contents/MacOS/WidgetFixtures" "${1:-$widget_project/build/widget-validation/renders}"
