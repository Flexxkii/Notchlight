#!/bin/zsh
# Rebuild, verify, and archive the app. Does not publish or notarize it.
set -euo pipefail
release_project_dir="${0:A:h:h}"
cd "$release_project_dir"
if (( $# != 0 )); then
    print -u2 "usage: $0"
    exit 2
fi
./scripts/build-app.sh
release_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Notchlight.app/Contents/Info.plist)
release_arch=$(lipo -archs build/Notchlight.app/Contents/MacOS/Notchlight)
if [[ "$release_arch" == *" "* ]]; then release_arch=universal; fi
release_name="Notchlight-${release_version}-macOS-${release_arch}.zip"
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent build/Notchlight.app "dist/$release_name"
# Use an isolated archive folder so stale local releases cannot enter the feed.
release_feed_dir=$(mktemp -d "${release_project_dir}/build/appcast.XXXXXX")
cp "dist/$release_name" "$release_feed_dir/"
release_notes="docs/releases/${release_version}.md"
if [[ ! -f "$release_notes" ]]; then
    print -u2 "Missing release notes: $release_notes"
    exit 1
fi
cp "$release_notes" "$release_feed_dir/${release_name%.zip}.md"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --account "${NOTCHLIGHT_UPDATE_KEY_ACCOUNT:-com.teodor.Notchlight.updates}" \
    --download-url-prefix "https://github.com/Flexxkii/notchlight/releases/download/v${release_version}/" \
    --embed-release-notes --maximum-deltas 0 "$release_feed_dir"
cp "$release_feed_dir/appcast.xml" dist/appcast.xml
python3 scripts/verify-appcast.py dist/appcast.xml "dist/$release_name"
(
    cd dist
    shasum -a 256 "$release_name" appcast.xml > SHA256SUMS.txt
)
print "Created: dist/$release_name"
print "Created: dist/SHA256SUMS.txt"
print "Created: dist/appcast.xml (signed feed and update archive)"
print "Notarization is a separate step; a signed archive is not automatically notarized."
