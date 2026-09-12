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
print -r -- "store=$SNIP_SNAP_STORE_PATH :: $@" >> "$SNIP_SNAP_CONTRACT_XCODEBUILD_ARGS"
previous=""
for argument in "$@"; do
    if [[ "$previous" == "-resultBundlePath" ]]; then
        /bin/mkdir -p "$argument"
    fi
    previous="$argument"
done
exit "${SNIP_SNAP_CONTRACT_XCODEBUILD_STATUS:-0}"' > "$test_root/bin/xcodebuild"
print -r -- '#!/bin/zsh
case "${SNIP_SNAP_CONTRACT_RESULT:-pass}" in
pass)
    print -r -- "{\"totalTestCount\":1,\"passedTests\":1,\"failedTests\":0,\"skippedTests\":0}"
    ;;
failed)
    print -r -- "{\"totalTestCount\":1,\"passedTests\":0,\"failedTests\":1,\"skippedTests\":0,\"testFailures\":[{\"failureText\":\"CloudKit transport stage: initial fetch\"}]}"
    ;;
skipped)
    print -r -- "{\"totalTestCount\":1,\"passedTests\":0,\"failedTests\":0,\"skippedTests\":1}"
    ;;
esac' > \
    "$test_root/bin/xcresulttool"
/bin/chmod +x "$test_root/bin/preflight" "$test_root/bin/xcodebuild" \
    "$test_root/bin/xcresulttool"

contract="$script_dir/cloud-dev-transport-contract.sh"
export SNIP_SNAP_SIGNED_LANE_PREFLIGHT="$test_root/bin/preflight"
export SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild"
export SNIP_SNAP_XCRESULTTOOL="$test_root/bin/xcresulttool"
export SNIP_SNAP_CONTRACT_PREFLIGHT_ARGS="$test_root/preflight-args"
export SNIP_SNAP_CONTRACT_XCODEBUILD_ARGS="$test_root/xcodebuild-args"
export SNIP_SNAP_DERIVED_DATA="$test_root/derived-data"
export SNIP_SNAP_CLOUD_DEV_TRANSPORT_CONTRACT_ARTIFACTS="$test_root/artifacts"
unset SNIP_SNAP_RUN_CLOUD_DEV_TRANSPORT_CONTRACT SNIP_SNAP_CONTRACT_RESULT \
    SNIP_SNAP_CONTRACT_XCODEBUILD_STATUS

if "$contract" >/dev/null 2>&1; then
    fail_test "the maintainer-only lane ran without its explicit opt-in"
fi
[[ ! -e "$test_root/preflight-args" && ! -e "$test_root/xcodebuild-args" ]] || \
    fail_test "the disabled lane touched signing or CloudKit"

export SNIP_SNAP_RUN_CLOUD_DEV_TRANSPORT_CONTRACT=1
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
/usr/bin/grep -F -- "-derivedDataPath $test_root/derived-data" \
    "$test_root/xcodebuild-args" >/dev/null || \
    fail_test "the lane did not use the supplied build cache"

run_directories=("$test_root/artifacts"/run.*(N))
[[ "${#run_directories[@]}" == 1 ]] || \
    fail_test "the successful lane did not keep one run of evidence"
first_run_directory="$run_directories[1]"
[[ -d "$first_run_directory/CloudDevTransportContract.xcresult" \
    && -s "$first_run_directory/CloudDevTransportContract.json" \
    && -f "$first_run_directory/xcodebuild.log" ]] || \
    fail_test "the successful lane did not keep its result and build log"
/usr/bin/grep -F -- "store=$first_run_directory/local-store/snips.json" \
    "$test_root/xcodebuild-args" >/dev/null || \
    fail_test "the lane did not isolate the contract test store"

"$contract" >/dev/null
run_directories=("$test_root/artifacts"/run.*(N))
[[ "${#run_directories[@]}" == 2 ]] || \
    fail_test "two runs against one build cache overwrote their evidence"
[[ "$run_directories[1]" != "$run_directories[2]" ]] || \
    fail_test "two runs used the same evidence directory"

# A held cache lock must reject another run before xcodebuild touches the cache.
lock_directory="$test_root/derived-data/.cloud-dev-transport-contract-lock"
[[ ! -e "$lock_directory" ]] || fail_test "the successful run left its cache lock"
/bin/mkdir "$lock_directory"
: > "$test_root/xcodebuild-args"
if locked_output="$(
    SNIP_SNAP_CLOUD_DEV_TRANSPORT_CONTRACT_ARTIFACTS="$test_root/locked-artifacts" \
        "$contract" 2>&1
)"; then
    fail_test "the lane used a cache held by another run"
fi
[[ ! -s "$test_root/xcodebuild-args" && -d "$lock_directory" \
    && "$locked_output" == *"build cache is locked"* ]] || \
    fail_test "the locked lane ran xcodebuild, removed another lock, or hid the cause"
/bin/rmdir "$lock_directory"

print -r -- '#!/bin/zsh
exit 1' > "$test_root/bin/preflight"
/bin/chmod +x "$test_root/bin/preflight"
: > "$test_root/xcodebuild-args"
if "$contract" >/dev/null 2>&1; then
    fail_test "the lane ignored a failed signed preflight"
fi
[[ ! -s "$test_root/xcodebuild-args" ]] || \
    fail_test "the failed preflight still touched the development container"

print -r -- '#!/bin/zsh
exit 0' > "$test_root/bin/preflight"
/bin/chmod +x "$test_root/bin/preflight"
if skipped_output="$(
    SNIP_SNAP_DERIVED_DATA="$test_root/skipped-derived" \
    SNIP_SNAP_CLOUD_DEV_TRANSPORT_CONTRACT_ARTIFACTS="$test_root/skipped-artifacts" \
    SNIP_SNAP_CONTRACT_RESULT=skipped \
        "$contract" 2>&1
)"; then
    fail_test "the lane reported a skipped real transport test as a pass"
fi
[[ "$skipped_output" == *"total=1 passed=0 failed=0 skipped=1"* \
    && "$skipped_output" == *"Evidence: $test_root/skipped-artifacts/run."* ]] || \
    fail_test "the skipped lane did not report its summary and evidence"
skipped_directories=("$test_root/skipped-artifacts"/run.*(N))
[[ "${#skipped_directories[@]}" == 1 \
    && -d "$skipped_directories[1]/CloudDevTransportContract.xcresult" \
    && -s "$skipped_directories[1]/CloudDevTransportContract.json" ]] || \
    fail_test "the skipped lane did not keep its result"

if failed_output="$(
    SNIP_SNAP_DERIVED_DATA="$test_root/failure-derived" \
    SNIP_SNAP_CLOUD_DEV_TRANSPORT_CONTRACT_ARTIFACTS="$test_root/failure-artifacts" \
    SNIP_SNAP_CONTRACT_RESULT=failed \
    SNIP_SNAP_CONTRACT_XCODEBUILD_STATUS=65 \
        "$contract" 2>&1
)"; then
    fail_test "the lane reported a failed real transport test as a pass"
else
    failed_status=$?
fi
[[ "$failed_status" == 65 ]] || \
    fail_test "the lane did not keep the xcodebuild failure status"
[[ "$failed_output" == *"total=1 passed=0 failed=1 skipped=0"* \
    && "$failed_output" == *"Cloud Dev transport contract test failure:"* \
    && "$failed_output" == *"CloudKit transport stage: initial fetch"* \
    && "$failed_output" == *"xcodebuild exited 65"* \
    && "$failed_output" == *"Evidence: $test_root/failure-artifacts/run."* ]] || \
    fail_test "the failed lane did not report its summary, failure text, and evidence"
failed_directories=("$test_root/failure-artifacts"/run.*(N))
[[ "${#failed_directories[@]}" == 1 \
    && -d "$failed_directories[1]/CloudDevTransportContract.xcresult" \
    && -s "$failed_directories[1]/CloudDevTransportContract.json" \
    && -f "$failed_directories[1]/xcodebuild.log" ]] || \
    fail_test "the failed lane did not preserve its result and build log"

[[ ! -e "$test_root/failure-derived/.cloud-dev-transport-contract-lock" \
    && ! -e "$test_root/skipped-derived/.cloud-dev-transport-contract-lock" ]] || \
    fail_test "a failed or skipped run left its cache lock"

print "Cloud Dev transport contract checks passed."
