#!/bin/zsh
# Build after `swift build -c release`. Optional second argument points to archived app sources.
set -euo pipefail
validation_project_dir="${0:A:h:h:h}"
cd "$validation_project_dir"
validation_output="${1:?usage: build-settings-harness.sh OUTPUT_BINARY [APP_SOURCES_DIRECTORY]}"
validation_app_sources="${2:-Sources/Notchlight}"
validation_products=$(swift build -c release --show-bin-path)
validation_sources=("$validation_app_sources"/**/*.swift)
validation_sources=(${validation_sources:#*/NotchlightApp.swift})
if [[ -d "$validation_products/Modules" ]]; then
    validation_modules="$validation_products/Modules"
    validation_objects=("$validation_products"/{BorderOverlay,CodexIntegration,Diagnostics}.build/*.o)
else
    validation_modules="$validation_products"
    validation_objects=("$validation_products"/{BorderOverlay,CodexIntegration,Diagnostics}.o)
fi
mkdir -p "${validation_output:h}"
swiftc -O -g -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -I "$validation_modules" \
    $validation_sources scripts/validation/SettingsHarness.swift $validation_objects -o "$validation_output"
