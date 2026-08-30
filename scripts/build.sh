#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
bundle_arguments=()

if [[ -n "${SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER:-}" ]]; then
    bundle_arguments+=(
        "SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=$SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER"
    )
fi

if [[ -n "${SNIP_SNAP_DEV_SLOT:-}" ]]; then
    exec "$script_dir/dev-app.sh" build
fi

source "$script_dir/derived-data.sh"
snip_snap_claim_derived_data
trap snip_snap_cleanup_derived_data EXIT

xcodebuild \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme SnipSnapiOS \
    -configuration Release \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build

xcodebuild \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme SnipSnap \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    "${bundle_arguments[@]}" \
    'PRODUCT_BUNDLE_IDENTIFIER=$(SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER).compilecheck' \
    PRODUCT_NAME=SnipSnapCompileCheck \
    'INFOPLIST_KEY_CFBundleDisplayName=Snip Snap Compile Check' \
    build

print "Compile checks passed. Do not launch this build. Use scripts/run.sh to build and open the Dev app."
