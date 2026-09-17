#!/bin/zsh
# Build after `swift build -c release`; does not use the shipping preferences.
set -euo pipefail
cd "${0:A:h:h:h}"
validation_app="${1:-build/notch-menu-hint-validation/Notch Hint Fixture.app}"
validation_products=$(swift build -c release --show-bin-path)
if [[ -d "$validation_products/Modules" ]]; then
    validation_modules="$validation_products/Modules"
    validation_objects=("$validation_products"/Diagnostics.build/*.o)
else
    validation_modules="$validation_products"
    validation_objects=("$validation_products/Diagnostics.o")
fi
mkdir -p "$validation_app/Contents/MacOS"
swiftc -O -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos14.0" \
    -sdk "$(xcrun --show-sdk-path)" -I "$validation_modules" \
    Sources/BorderOverlay/*.swift scripts/validation/NotchMenuHintHarness.swift \
    $validation_objects -o "$validation_app/Contents/MacOS/NotchHintFixture"
cat > "$validation_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.notchlight.hint-fixture</string>
<key>CFBundleExecutable</key><string>NotchHintFixture</string>
<key>CFBundleName</key><string>Notch Hint Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$validation_app"
