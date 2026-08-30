#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
package_dir="$repo_dir/Packages/SnipSnapLibrary"
program="$0"
derived_data_prefix="${SNIP_SNAP_DERIVED_DATA:-/private/tmp/snip-snap-release-tests}"
iphone_destination="${SNIP_SNAP_IPHONE_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=latest}"
ipad_destination="${SNIP_SNAP_IPAD_TEST_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=latest}"
xcodebuild_tool="${SNIP_SNAP_XCODEBUILD:-xcodebuild}"

usage() {
    print -u2 "Usage: $program [--iphone-destination DESTINATION] [--ipad-destination DESTINATION]"
}

while (( $# )); do
    case "$1" in
        --iphone-destination)
            (( $# >= 2 )) || { usage; exit 2; }
            iphone_destination="$2"
            shift 2
            ;;
        --ipad-destination)
            (( $# >= 2 )) || { usage; exit 2; }
            ipad_destination="$2"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

[[ "$derived_data_prefix" == /* ]] || {
    print -u2 "Release matrix: SNIP_SNAP_DERIVED_DATA must be an absolute path prefix."
    exit 2
}
derived_data_root="$(/usr/bin/mktemp -d "${derived_data_prefix}.XXXXXX")"
owner_marker="$derived_data_root/.snip-snap-release-tests-owned"
/usr/bin/touch "$owner_marker"
cleanup() {
    [[ -f "$owner_marker" ]] && /bin/rm -rf "$derived_data_root"
}
trap cleanup EXIT

run_transfer_test() {
    local destination="$1"
    local derived_data="$2"
    (
        cd "$package_dir"
        "$xcodebuild_tool" \
            -scheme SnipSnapLibrary-Package \
            -configuration Debug \
            -destination "$destination" \
            -derivedDataPath "$derived_data" \
            CODE_SIGNING_ALLOWED=NO \
            -only-testing:SnipSnapCloudTests/CloudAttachmentTransferTests/testTwentyFiveMiBDownloadVerifiesHashRetriesInterruptionAndUsesBoundedCache \
            test
    )
}

run_app_actions() {
    local destination="$1"
    local derived_data="$2"
    "$xcodebuild_tool" \
        -project "$repo_dir/SnipSnap.xcodeproj" \
        -scheme SnipSnapiOS \
        -configuration Debug \
        -destination "$destination" \
        -derivedDataPath "$derived_data" \
        CODE_SIGNING_ALLOWED=NO \
        -only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testSyncEnableReportsEveryAttachmentAboveTheSnipSnapLimit \
        -only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testSharesMultipleSelectedSnips \
        -only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testLocalAttachmentsPreviewRemoveAndSurviveRelaunch \
        test
}

run_share_process() {
    local destination="$1"
    local derived_data="$2"
    "$xcodebuild_tool" \
        -project "$repo_dir/SnipSnap.xcodeproj" \
        -scheme SnipSnapiOS \
        -configuration Debug \
        -destination "$destination" \
        -derivedDataPath "$derived_data" \
        CODE_SIGNING_ALLOWED=YES \
        DEVELOPMENT_TEAM= \
        -only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testShareExtensionImportsExactlyOnceWhileMainAppIsOpen \
        -only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testShareExtensionImportsExactlyOnceWhileMainAppIsClosed \
        -only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testShareExtensionDefersExactlyOnceWhileMainStoreIsUnavailable \
        test
}

print "Release matrix tests: iPhone 25 MiB transfer"
run_transfer_test "$iphone_destination" "$derived_data_root/iphone-transfer"
print "Release matrix tests: iPhone limit, Share, and attachment actions"
run_app_actions "$iphone_destination" "$derived_data_root/iphone-app"
print "Release matrix tests: iPhone Share extension process"
run_share_process "$iphone_destination" "$derived_data_root/iphone-share-process"
print "Release matrix tests: iPad 25 MiB transfer"
run_transfer_test "$ipad_destination" "$derived_data_root/ipad-transfer"
print "Release matrix tests: iPad limit, Share, and attachment actions"
run_app_actions "$ipad_destination" "$derived_data_root/ipad-app"
print "Release matrix tests: iPad Share extension process"
run_share_process "$ipad_destination" "$derived_data_root/ipad-share-process"

print "iPhone and iPad release-matrix tests passed."
