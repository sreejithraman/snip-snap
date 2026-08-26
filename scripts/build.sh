#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
derived_data="${SNIP_SNAP_DERIVED_DATA:-/tmp/snip-snap-derived-data}"

if [[ -n "${SNIP_SNAP_DEV_SLOT:-}" ]]; then
    exec "$script_dir/dev-app.sh" build
fi

xcodebuild \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme SnipSnap \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    PRODUCT_BUNDLE_IDENTIFIER=world.sree.snipsnap.compilecheck \
    PRODUCT_NAME=SnipSnapCompileCheck \
    'INFOPLIST_KEY_CFBundleDisplayName=Snip Snap Compile Check' \
    build

print "Compile check passed. Do not launch this build. Use scripts/run.sh to build and open the Dev app."
