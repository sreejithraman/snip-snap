#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
derived_data="${SNIP_SNAP_DERIVED_DATA:-/tmp/snip-snap-derived-data}"
build_settings=(CODE_SIGNING_ALLOWED=NO)

if [[ -n "${SNIP_SNAP_DEV_SLOT:-}" ]]; then
    slot="$("$script_dir/dev-slot.sh" claim)"
    state_dir="${SNIP_SNAP_DEV_STATE_DIR:-$HOME/Library/Application Support/Snip Snap/Development}"
    derived_data="${SNIP_SNAP_DERIVED_DATA:-$state_dir/build/slot-$slot}"

    build_settings=(
        CODE_SIGNING_ALLOWED=YES
        CODE_SIGNING_REQUIRED=YES
        "PRODUCT_BUNDLE_IDENTIFIER=world.sree.snipsnap.dev$slot"
        "PRODUCT_NAME=SnipSnapDev$slot"
        "INFOPLIST_KEY_CFBundleDisplayName=Snip Snap Dev $slot"
    )
fi

xcodebuild \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme SnipSnap \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    "${build_settings[@]}" \
    build
