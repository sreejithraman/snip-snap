#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
simulator_id="${1:-}"
[[ -n "$simulator_id" && $# == 1 ]] || {
    print -u2 "Usage: scripts/run.sh ios-simulator SIMULATOR_ID"
    exit 2
}
slot="$("$script_dir/dev-slot.sh" claim)"
dev_state_dir="${SNIP_SNAP_DEV_STATE_DIR:-$HOME/Library/Application Support/Snip Snap/Development}"
derived_data="$dev_state_dir/build/ios-slot-$slot"
bundle_id="world.sree.snipsnap.ios.dev$slot"

xcodebuild \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme SnipSnapiOS \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    SNIP_SNAP_APP_GROUP_IDENTIFIER= \
    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER= \
    "SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" \
    "SNIP_SNAP_DISPLAY_NAME=Snip Snap Dev $slot" \
    build

app_path="$derived_data/Build/Products/Debug-iphonesimulator/Snip Snap iOS.app"
xcrun simctl install "$simulator_id" "$app_path"
xcrun simctl launch --terminate-running-process "$simulator_id" "$bundle_id"
print "Opened Snip Snap Dev $slot on Simulator $simulator_id."
