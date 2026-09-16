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
(
    cd dist
    shasum -a 256 "$release_name" > SHA256SUMS.txt
)
print "Created: dist/$release_name"
print "Created: dist/SHA256SUMS.txt"
print "Notarization is a separate step. Do not describe an ad-hoc archive as notarized."
