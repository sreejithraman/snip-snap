#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"

fail_test() {
    print -u2 "TestFlight script test failed: $1"
    exit 1
}

if output="$("$script_dir/testflight.sh" archive --build-number 999999 2>&1)"; then
    fail_test "a mismatched build number was accepted"
fi
[[ "$output" == *'--build-number must match release.json'* ]] || \
    fail_test "the build mismatch was not clear"

if output="$("$script_dir/testflight.sh" upload 2>&1)"; then
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
