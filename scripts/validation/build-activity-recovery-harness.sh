#!/bin/zsh
set -euo pipefail
validation_project_dir="${0:A:h:h:h}"
cd "$validation_project_dir"
validation_output="${1:?usage: build-activity-recovery-harness.sh OUTPUT [PRODUCTS]}"
validation_products="${2:-$(swift build -c release --show-bin-path)}"
if [[ -d "$validation_products/Modules" ]]; then
    validation_modules="$validation_products/Modules"
    validation_objects=("$validation_products"/{CodexIntegration,Diagnostics}.build/*.o)
else
    validation_modules="$validation_products"
    validation_objects=("$validation_products"/{CodexIntegration,Diagnostics}.o)
fi
mkdir -p "${validation_output:h}"
swiftc -O -g -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -I "$validation_modules" \
    scripts/validation/ActivityRecoveryHarness.swift $validation_objects -o "$validation_output"
