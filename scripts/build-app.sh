#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${PROJECT_DIR}/build"
APP_NAME="Notchlight.app"
DESTINATION_APP="${BUILD_DIR}/${APP_NAME}"

open_app=false
if (( $# > 1 )); then
    print -u2 "usage: $0 [--open]"
    exit 2
elif (( $# == 1 )); then
    if [[ "$1" != "--open" ]]; then
        print -u2 "usage: $0 [--open]"
        exit 2
    fi
    open_app=true
fi

# Refuse before touching the existing app. An ad-hoc host cannot publish to
# the widget's shared container, even when codesign verification succeeds.
if [[ -z "${NOTCHLIGHT_SIGNING_IDENTITY:-}" || "${NOTCHLIGHT_SIGNING_IDENTITY:-}" == "-" ]]; then
    print -u2 'Packaged widgets require NOTCHLIGHT_SIGNING_IDENTITY (Apple Development or Developer ID).'
    print -u2 'Set it to an identity from: security find-identity -v -p codesigning'
    print -u2 'For development without packaged widgets, use: swift run Notchlight'
    exit 1
fi

cd "$PROJECT_DIR"
"${SCRIPT_DIR}/sync-legal.sh" --check
mkdir -p "$BUILD_DIR"
STAGING_DIR=$(mktemp -d "${BUILD_DIR}/.notchlight-stage.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="${STAGING_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
print "Building Notchlight in release mode..."
# Keep the runtime minimum separate from the SDK used for system UI behavior.
# Some SwiftPM/SwiftBuild toolchains otherwise stamp the SDK as the minimum OS.
DEPLOYMENT_TARGET=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${PROJECT_DIR}/Resources/Info.plist")
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
swift build -c release \
    -Xlinker -platform_version -Xlinker macos \
    -Xlinker "$DEPLOYMENT_TARGET" -Xlinker "$SDK_VERSION"
PRODUCTS_DIR=$(swift build -c release --show-bin-path)

print "Compiling the Icon Composer app icon..."
mkdir -p "$BUILD_DIR"
ICON_SOURCE="${PROJECT_DIR}/Resources/Notchlight.icon"
ICON_BUILD_DIR="${BUILD_DIR}/app-icon"
ICON_INFO_PLIST="${BUILD_DIR}/app-icon-info.plist"
rm -rf "$ICON_BUILD_DIR"
mkdir -p "$ICON_BUILD_DIR"
# Compile the layered document and its legacy renditions for the same minimum
# OS as the executable. Copying the raw .icon package is not sufficient.
xcrun actool "$ICON_SOURCE" \
    --compile "$ICON_BUILD_DIR" \
    --platform macosx \
    --minimum-deployment-target "$DEPLOYMENT_TARGET" \
    --app-icon Notchlight \
    --standalone-icon-behavior all \
    --output-partial-info-plist "$ICON_INFO_PLIST" \
    --output-format human-readable-text \
    --warnings --notices
if [[ ! -s "${ICON_BUILD_DIR}/Assets.car" || ! -s "${ICON_BUILD_DIR}/Notchlight.icns" || ! -s "$ICON_INFO_PLIST" ]]; then
    print -u2 "Icon compilation did not produce the expected catalog, fallback icon, and metadata."
    exit 1
fi

mkdir -p "$RESOURCES_DIR"
mkdir -p "${CONTENTS_DIR}/MacOS"
cp "${PRODUCTS_DIR}/Notchlight" "${CONTENTS_DIR}/MacOS/Notchlight"
cp "${PROJECT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Merge '${ICON_INFO_PLIST}'" "${CONTENTS_DIR}/Info.plist"
cp -R "${ICON_BUILD_DIR}/." "$RESOURCES_DIR/"
cp -R "${PRODUCTS_DIR}/Notchlight_Notchlight.bundle" "$RESOURCES_DIR/"
for legal_file in LICENSE TERMS.md PRIVACY.md THIRD_PARTY_NOTICES.md; do
    packaged_legal_file="${RESOURCES_DIR}/Notchlight_Notchlight.bundle/Contents/Resources/Legal/${legal_file}"
    # SwiftPM's bundle layout differs between the SwiftBuild and native build systems.
    if [[ ! -f "$packaged_legal_file" ]]; then
        packaged_legal_file="${RESOURCES_DIR}/Notchlight_Notchlight.bundle/Legal/${legal_file}"
    fi
    cmp "${PROJECT_DIR}/${legal_file}" "$packaged_legal_file"
done
plutil -lint "${CONTENTS_DIR}/Info.plist"

"${SCRIPT_DIR}/build-widgets.sh" "$APP_DIR"

print "Signing with the supplied identity..."
codesign --force --options runtime --timestamp --sign "$NOTCHLIGHT_SIGNING_IDENTITY" \
    --entitlements "${BUILD_DIR}/widget-extension/host.entitlements" "$APP_DIR"
python3 "${SCRIPT_DIR}/verify-widget-package.py" "$APP_DIR"

# Promote only a verified bundle, keeping a recoverable copy of the prior app.
PREVIOUS_APP=""
if [[ -e "$DESTINATION_APP" ]]; then
    BACKUP_DIR=$(mktemp -d "${BUILD_DIR}/previous-app.XXXXXX")
    PREVIOUS_APP="${BACKUP_DIR}/${APP_NAME}"
    mv "$DESTINATION_APP" "$PREVIOUS_APP"
fi
if ! mv "$APP_DIR" "$DESTINATION_APP"; then
    if [[ -n "$PREVIOUS_APP" ]]; then mv "$PREVIOUS_APP" "$DESTINATION_APP"; fi
    exit 1
fi
if [[ -n "$PREVIOUS_APP" ]]; then print "Previous app preserved: ${PREVIOUS_APP}"; fi

print "Created: ${DESTINATION_APP}"
if $open_app; then
    open "$DESTINATION_APP"
fi
