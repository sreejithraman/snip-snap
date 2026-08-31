#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
run_mac_app_tests=YES

if (( $# )); then
    [[ "$#" == 1 && "$1" == --without-mac-app-tests ]] || {
        print -u2 "Usage: $0 [--without-mac-app-tests]"
        exit 2
    }
    run_mac_app_tests=NO
fi

source "$script_dir/derived-data.sh"
snip_snap_claim_derived_data
trap snip_snap_cleanup_derived_data EXIT

"$script_dir/release-policy-tests.sh"
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
"$script_dir/release-matrix-tests-tests.sh"
"$script_dir/cloud-dev-transport-contract-tests.sh"
"$script_dir/cloud-dev-tests.sh"
"$script_dir/ios-target-policy-tests.sh"
"$script_dir/localization-policy-tests.sh"

swift test --package-path "$repo_dir/Packages/SnipSnapLibrary"

if [[ "$run_mac_app_tests" == YES ]]; then
    xcodebuild \
        -project "$repo_dir/SnipSnap.xcodeproj" \
        -scheme SnipSnap \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$derived_data" \
        CODE_SIGNING_ALLOWED=NO \
        test
else
    print "Public policy and package tests passed; the iOS release gate omits Mac app-host tests."
fi
