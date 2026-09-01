#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-cloud-contract.XXXXXX)"
cleanup() {
    [[ "$test_root" == /private/tmp/snip-snap-cloud-contract.* ]] && /bin/rm -rf "$test_root"
}
trap cleanup EXIT

fail_test() {
    print -u2 "cloud transport contract test failed: $1"
    exit 1
}

/bin/mkdir -p "$test_root/bin"
print -r -- '#!/bin/zsh
print -r -- "$@" >> "$SNIP_SNAP_CONTRACT_PREFLIGHT_ARGS"' > "$test_root/bin/preflight"
print -r -- '#!/bin/zsh
print -r -- "$@" >> "$SNIP_SNAP_CONTRACT_XCODEBUILD_ARGS"
previous=""
for argument in "$@"; do
    if [[ "$previous" == "-resultBundlePath" ]]; then
        /bin/mkdir -p "$argument"
    fi
    previous="$argument"
done' > "$test_root/bin/xcodebuild"
print -r -- '#!/bin/zsh
print -r -- "{\"totalTestCount\":1,\"passedTests\":1,\"failedTests\":0,\"skippedTests\":0}"' > \
    "$test_root/bin/xcresulttool"
/bin/chmod +x "$test_root/bin/preflight" "$test_root/bin/xcodebuild" \
    "$test_root/bin/xcresulttool"

contract="$script_dir/cloud-dev-transport-contract.sh"
if SNIP_SNAP_SIGNED_LANE_PREFLIGHT="$test_root/bin/preflight" \
    SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
    SNIP_SNAP_XCRESULTTOOL="$test_root/bin/xcresulttool" \
    SNIP_SNAP_CONTRACT_PREFLIGHT_ARGS="$test_root/preflight-args" \
    SNIP_SNAP_CONTRACT_XCODEBUILD_ARGS="$test_root/xcodebuild-args" \
    "$contract" >/dev/null 2>&1
then
    fail_test "the maintainer-only lane ran without its explicit opt-in"
fi
[[ ! -e "$test_root/preflight-args" && ! -e "$test_root/xcodebuild-args" ]] || \
    fail_test "the disabled lane touched signing or CloudKit"

SNIP_SNAP_RUN_CLOUD_DEV_TRANSPORT_CONTRACT=1 \
SNIP_SNAP_SIGNED_LANE_PREFLIGHT="$test_root/bin/preflight" \
SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
SNIP_SNAP_XCRESULTTOOL="$test_root/bin/xcresulttool" \
SNIP_SNAP_CONTRACT_PREFLIGHT_ARGS="$test_root/preflight-args" \
SNIP_SNAP_CONTRACT_XCODEBUILD_ARGS="$test_root/xcodebuild-args" \
SNIP_SNAP_DERIVED_DATA="$test_root/derived-data" \
    "$contract" >/dev/null

/usr/bin/grep -F -- 'cloud --scheme SnipSnap --configuration Debug --destination platform=macOS' \
    "$test_root/preflight-args" >/dev/null || \
    fail_test "the lane skipped the signed Cloud Dev preflight"
/usr/bin/grep -F -- '-scheme SnipSnap -configuration Debug -destination platform=macOS' \
    "$test_root/xcodebuild-args" >/dev/null || \
    fail_test "the lane did not run the signed Mac test host"
/usr/bin/grep -F -- '-only-testing:SnipSnapTests/CloudDevTransportContractTests' \
    "$test_root/xcodebuild-args" >/dev/null || \
    fail_test "the lane did not select the real transport contract"
/usr/bin/grep -F -- 'CODE_SIGNING_ALLOWED=YES' "$test_root/xcodebuild-args" >/dev/null || \
    fail_test "the real transport contract did not require signing"
/usr/bin/grep -F -- 'SNIP_SNAP_CLOUD_DEV_TRANSPORT_CONTRACT_ENABLED=YES' \
    "$test_root/xcodebuild-args" >/dev/null || \
    fail_test "the host app did not receive the build-time contract flag"
/usr/bin/grep -F -- '-resultBundlePath' "$test_root/xcodebuild-args" >/dev/null || \
    fail_test "the lane cannot prove that the selected test ran"

print -r -- '#!/bin/zsh
exit 1' > "$test_root/bin/preflight"
/bin/chmod +x "$test_root/bin/preflight"
: > "$test_root/xcodebuild-args"
if SNIP_SNAP_RUN_CLOUD_DEV_TRANSPORT_CONTRACT=1 \
    SNIP_SNAP_SIGNED_LANE_PREFLIGHT="$test_root/bin/preflight" \
    SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
    SNIP_SNAP_XCRESULTTOOL="$test_root/bin/xcresulttool" \
    SNIP_SNAP_CONTRACT_PREFLIGHT_ARGS="$test_root/preflight-args" \
    SNIP_SNAP_CONTRACT_XCODEBUILD_ARGS="$test_root/xcodebuild-args" \
    "$contract" >/dev/null 2>&1
then
    fail_test "the lane ignored a failed signed preflight"
fi
[[ ! -s "$test_root/xcodebuild-args" ]] || \
    fail_test "the failed preflight still touched the development container"

print -r -- '#!/bin/zsh
print -r -- "{\"totalTestCount\":1,\"passedTests\":0,\"failedTests\":0,\"skippedTests\":1}"' > \
    "$test_root/bin/xcresulttool"
print -r -- '#!/bin/zsh
exit 0' > "$test_root/bin/preflight"
/bin/chmod +x "$test_root/bin/xcresulttool" "$test_root/bin/preflight"
if SNIP_SNAP_RUN_CLOUD_DEV_TRANSPORT_CONTRACT=1 \
    SNIP_SNAP_SIGNED_LANE_PREFLIGHT="$test_root/bin/preflight" \
    SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
    SNIP_SNAP_XCRESULTTOOL="$test_root/bin/xcresulttool" \
    SNIP_SNAP_CONTRACT_PREFLIGHT_ARGS="$test_root/preflight-args" \
    SNIP_SNAP_CONTRACT_XCODEBUILD_ARGS="$test_root/xcodebuild-args" \
    SNIP_SNAP_DERIVED_DATA="$test_root/skipped-derived" \
    "$contract" >/dev/null 2>&1
then
    fail_test "the lane reported a skipped real transport test as a pass"
fi

print "Cloud Dev transport contract checks passed."
