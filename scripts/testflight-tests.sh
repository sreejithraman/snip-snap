#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"

fail_test() {
    print -u2 "TestFlight script test failed: $1"
    exit 1
}

if output="$("$script_dir/testflight.sh" archive 2>&1)"; then
    fail_test "a missing generated build number was accepted"
fi
[[ "$output" == *'pass --build-number with the generated build number'* ]] || \
    fail_test "the missing build number was not clear"

if output="$("$script_dir/testflight.sh" upload --build-number 7 2>&1)"; then
    fail_test "an upload without explicit confirmation was accepted"
fi
[[ "$output" == *'SNIP_SNAP_CONFIRM_TESTFLIGHT_UPLOAD=YES'* ]] || \
    fail_test "the upload confirmation gate was missing"

for required in \
    '-scheme SnipSnapiOS' \
    "-destination 'generic/platform=iOS'" \
    '-allowProvisioningUpdates' \
    'release_policy_require_source' \
    'test.sh" --without-mac-app-tests' \
    'testflight_policy_verify_source_record' \
    'testflight_policy_verify_archive' \
    'SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS' \
    'SHOWROOM_APPLE_KEY_PATH'; do
    /usr/bin/grep -F -- "$required" "$script_dir/testflight.sh" >/dev/null || \
        fail_test "missing upload rule $required"
done

print "TestFlight script checks passed."
