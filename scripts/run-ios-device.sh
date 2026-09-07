#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
device_id="${1:-}"
[[ -n "$device_id" && $# == 1 ]] || {
    print -u2 "Usage: SNIP_SNAP_DEVELOPMENT_TEAM=TEAM scripts/run.sh ios-device DEVICE_UDID"
    exit 2
}
development_team="${SNIP_SNAP_DEVELOPMENT_TEAM:?Set SNIP_SNAP_DEVELOPMENT_TEAM to your Apple Development team.}"
slot="$("$script_dir/dev-slot.sh" claim)"
dev_state_dir="${SNIP_SNAP_DEV_STATE_DIR:-$HOME/Library/Application Support/Snip Snap/Development}"
derived_data="$dev_state_dir/build/ios-device-slot-$slot"
bundle_id="world.sree.snipsnap.ios.dev$slot"

xcodebuild \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme SnipSnapiOS \
    -configuration Debug \
    -destination "platform=iOS,id=$device_id" \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    "DEVELOPMENT_TEAM=$development_team" \
    CODE_SIGN_IDENTITY="Apple Development" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_ENTITLEMENTS= \
    SNIP_SNAP_APP_GROUP_IDENTIFIER= \
    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER= \
    "SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" \
    "SNIP_SNAP_DISPLAY_NAME=Snip Snap Dev $slot" \
    "SNIP_SNAP_SHARE_DISPLAY_NAME=Save to Snip Snap Dev $slot" \
    ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev \
    build

app_path="$derived_data/Build/Products/Debug-iphoneos/Snip Snap iOS.app"
xcrun devicectl device install app --device "$device_id" "$app_path"
xcrun devicectl device process launch --device "$device_id" --terminate-existing "$bundle_id"
print "Opened Snip Snap Dev $slot on the connected iOS device."
