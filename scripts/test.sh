#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
run_common_tests=YES
run_mac_app_tests=YES
run_ios_app_tests=YES
ios_test_destination="${SNIP_SNAP_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=latest}"

usage() {
    print -u2 "Usage: $0 [--mac-only | --ios-only | --without-mac-app-tests]"
    exit 2
}
(( $# <= 1 )) || usage
case "${1:-}" in
    '') ;;
    --mac-only) run_ios_app_tests=NO ;;
    --ios-only) run_common_tests=NO; run_mac_app_tests=NO ;;
    --without-mac-app-tests) run_mac_app_tests=NO ;;
    *) usage ;;
esac

source "$script_dir/derived-data.sh"
source "$script_dir/ios-bundle-check.sh"
snip_snap_claim_derived_data
trap snip_snap_cleanup_derived_data EXIT

if [[ "$run_common_tests" == YES ]]; then
    "$script_dir/release-policy-tests.sh"
    "$script_dir/release-automation-tests.sh"
    "$script_dir/signing-policy-tests.sh"
    "$script_dir/testflight-policy-tests.sh"
    "$script_dir/testflight-tests.sh"
    "$script_dir/tracked-input-policy-tests.sh"
    "$script_dir/tracked-input-policy.sh"
    "$script_dir/showroom-delivery-tests.sh"
    "$script_dir/dev-slot-tests.sh"
    "$script_dir/build-tests.sh"
    "$script_dir/derived-data-tests.sh"
    "$script_dir/build-matrix-tests.sh"
    "$script_dir/test-runner-tests.sh"
    "$script_dir/release-matrix-tests-tests.sh"
    "$script_dir/cloud-dev-transport-contract-tests.sh"
    "$script_dir/cloud-dev-tests.sh"
    "$script_dir/ios-target-policy-tests.sh"
    "$script_dir/localization-policy-tests.sh"

    swift test --package-path "$repo_dir/Packages/SnipSnapLibrary"
fi

if [[ "$run_mac_app_tests" == YES ]]; then
    mac_derived_data="$derived_data/mac"
    mac_store_path="$derived_data/mac-test-store/snips.json"
    SNIP_SNAP_STORE_PATH="$mac_store_path" xcodebuild \
        -project "$repo_dir/SnipSnap.xcodeproj" \
        -scheme SnipSnap \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$mac_derived_data" \
        CODE_SIGNING_ALLOWED=NO \
        SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER= \
        test
elif [[ "$run_common_tests" == YES ]]; then
    print "Public policy and package tests passed; the iOS release gate omits Mac app-host tests."
fi

if [[ "$run_ios_app_tests" == YES ]]; then
    xcodebuild \
        -project "$repo_dir/SnipSnap.xcodeproj" \
        -scheme SnipSnapiOS \
        -configuration Debug \
        -destination "$ios_test_destination" \
        -derivedDataPath "$derived_data/ios" \
        CODE_SIGNING_ALLOWED=NO \
        SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER= \
        -only-testing:SnipSnapiOSTests \
        test

    snip_snap_check_ios_bundle \
        "$derived_data/ios/Build/Products/Debug-iphonesimulator/Snip Snap iOS.app"
fi
