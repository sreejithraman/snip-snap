#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
device_id="${1:-}"
if (( $# > 0 )); then shift; fi
ui_test=""
if [[ "${1:-}" == --ui-test && $# == 2 ]]; then
    [[ -n "$2" ]] || {
        print -u2 "Missing value for --ui-test"
        exit 2
    }
    ui_test="$2"
    shift 2
fi
[[ -n "$device_id" && $# == 0 ]] || {
    print -u2 "Usage: SNIP_SNAP_DEVELOPMENT_TEAM=TEAM scripts/run.sh ios-device DEVICE_UDID [--ui-test TEST_NAME]"
    exit 2
}
development_team="${SNIP_SNAP_DEVELOPMENT_TEAM:?Set SNIP_SNAP_DEVELOPMENT_TEAM to your Apple Development team.}"
slot="$("$script_dir/dev-slot.sh" claim)"
dev_state_dir="${SNIP_SNAP_DEV_STATE_DIR:-$HOME/Library/Application Support/Snip Snap/Development}"
derived_data="$dev_state_dir/build/ios-device-slot-$slot"
bundle_id="world.sree.snipsnap.ios.dev$slot"
local_dev_entitlements="$repo_dir/Config/LocalDev.iOS.entitlements"

build_arguments=(
    -project "$repo_dir/SnipSnap.xcodeproj"
    -scheme SnipSnapiOS
    -configuration Debug
    -destination "platform=iOS,id=$device_id"
    -derivedDataPath "$derived_data"
    -allowProvisioningUpdates
    -allowProvisioningDeviceRegistration
    "DEVELOPMENT_TEAM=$development_team"
    CODE_SIGN_IDENTITY="Apple Development"
    CODE_SIGN_STYLE=Automatic
    "CODE_SIGN_ENTITLEMENTS=$local_dev_entitlements"
    "SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS=$local_dev_entitlements"
    SNIP_SNAP_APP_GROUP_IDENTIFIER=
    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER=
    "SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=$bundle_id"
    "SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER=$bundle_id"
    "SNIP_SNAP_DISPLAY_NAME=Snip Snap Dev $slot"
    "SNIP_SNAP_SHARE_DISPLAY_NAME=Save to Snip Snap Dev $slot"
    ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev
)
xcodebuild "${build_arguments[@]}" build

app_path="$derived_data/Build/Products/Debug-iphoneos/Snip Snap iOS.app"
xcrun devicectl device install app --device "$device_id" "$app_path"
xcrun devicectl device process launch --device "$device_id" --terminate-existing "$bundle_id"
print "Opened Snip Snap Dev $slot on the connected iOS device."
if [[ -n "$ui_test" ]]; then
    xcodebuild "${build_arguments[@]}" \
        -parallel-testing-enabled NO \
        "-only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/$ui_test" \
        test
    print "Device UI test passed: $ui_test"
fi
