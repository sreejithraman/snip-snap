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
print -r -- "store=$SNIP_SNAP_STORE_PATH :: forwarded-store=${TEST_RUNNER_SNIP_SNAP_STORE_PATH:-} :: diagnostics=${TEST_RUNNER_SNIP_SNAP_DIAGNOSTICS_DIRECTORY:-} :: $@" >> "$SNIP_SNAP_CONTRACT_XCODEBUILD_ARGS"
if [[ "${SNIP_SNAP_CONTRACT_EVIDENCE:-complete}" != missing ]]; then
    /usr/bin/ruby "$SNIP_SNAP_CONTRACT_EVIDENCE_FIXTURE"
fi
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
multiple)
    print -r -- "{\"totalTestCount\":2,\"passedTests\":2,\"failedTests\":0,\"skippedTests\":0}"
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

cat > "$test_root/evidence-fixture.rb" <<'RUBY'
require 'json'
require 'fileutils'
require 'time'
directory = ENV.fetch('TEST_RUNNER_SNIP_SNAP_CONTRACT_EVIDENCE_DIRECTORY')
FileUtils.mkdir_p(directory)
run_id = '00000000-0000-0000-0000-000000000001'
zones = %w[metadata payload planner3-metadata planner3-payload planner5-metadata planner5-payload].map { |s| "snipsnap-contract-#{run_id}-#{s}" }
phases = %w[baseline setup 9-capability 1-3-4-5-one-stale 2-three-stale 3-all-atomic-events 6-unchanged-companion 7-failed-ordinary 7-failed-atomic 8-fetch-0 8-fetch-1 8-fetch-2 setup-planner-3 10-planner-3 setup-planner-5 10-planner-5]
started = Time.at(ENV.fetch('TEST_RUNNER_SNIP_SNAP_CONTRACT_STARTED_AT').to_i)
results = phases.to_h { |phase| [phase, 'pass'] }
[3, 5].each { |n| results["10-cost-#{n}"] = "atomic-provider-batches=1; metadata-member-saves=#{n}; all-provider-batches=1; logical-not-HTTP" }
cleanup = zones.to_h { |zone| [zone, 'verified-absent'] }
cleanup[zones.first] = 'UNRESOLVED' if ENV['SNIP_SNAP_CONTRACT_EVIDENCE'] == 'partial-cleanup'
manifest = {runID: run_id, sourceRevision: ENV.fetch('TEST_RUNNER_SNIP_SNAP_CONTRACT_SOURCE_REVISION'), harnessRevision: ENV.fetch('TEST_RUNNER_SNIP_SNAP_CONTRACT_HARNESS_REVISION'), accountFingerprint: 'a' * 64, startedAt: started.iso8601, workDeadline: (started + 1800).iso8601, cleanupDeadline: (started + 2400).iso8601, zones: zones, results: results, cleanup: cleanup}
File.write(File.join(directory, 'manifest.json'), JSON.generate(manifest))
trace = phases.flat_map { |phase| %w[provider-batch sent-event-before].map { |kind| {phase: phase, kind: kind} } }
trace = [] if ENV['SNIP_SNAP_CONTRACT_EVIDENCE'] == 'no-sdk-trace'
trace.each_with_index { |entry, index| entry[:sequence] = index }
File.write(File.join(directory, 'sdk-trace.json'), JSON.generate(trace))
RUBY
export SNIP_SNAP_CONTRACT_EVIDENCE_FIXTURE="$test_root/evidence-fixture.rb"

contract="$script_dir/cloud-dev-transport-contract.sh"
export SNIP_SNAP_SIGNED_LANE_PREFLIGHT="$test_root/bin/preflight"
export SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild"
export SNIP_SNAP_XCRESULTTOOL="$test_root/bin/xcresulttool"
export SNIP_SNAP_CONTRACT_PREFLIGHT_ARGS="$test_root/preflight-args"
export SNIP_SNAP_CONTRACT_XCODEBUILD_ARGS="$test_root/xcodebuild-args"
export SNIP_SNAP_DERIVED_DATA="$test_root/derived-data"
export SNIP_SNAP_CLOUD_DEV_TRANSPORT_CONTRACT_ARTIFACTS="$test_root/artifacts"
unset SNIP_SNAP_RUN_CLOUD_DEV_TRANSPORT_CONTRACT SNIP_SNAP_CONTRACT_RESULT \
    SNIP_SNAP_CONTRACT_XCODEBUILD_STATUS SNIP_SNAP_CONTRACT_EVIDENCE

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

/usr/bin/grep -F -- "forwarded-store=$first_run_directory/local-store/snips.json" \
    "$test_root/xcodebuild-args" >/dev/null || \
    fail_test "the lane did not explicitly forward the isolated store to its test host"

/usr/bin/grep -F -- "diagnostics=$first_run_directory/local-store/SnipSnapDiagnostics" \
    "$test_root/xcodebuild-args" >/dev/null || \
    fail_test "the lane did not explicitly isolate hosted diagnostic storage"

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

if multiple_output="$(SNIP_SNAP_CONTRACT_RESULT=multiple "$contract" 2>&1)"; then
    fail_test "the ten-phase harness inflated the one-live-test allowance"
fi
[[ "$multiple_output" == *"expected one passing, non-skipped test"* ]] || \
    fail_test "the exact-one-test guard did not explain a multiple-test summary"

for mode in missing partial-cleanup no-sdk-trace; do
    if evidence_output="$(SNIP_SNAP_CONTRACT_EVIDENCE="$mode" "$contract" 2>&1)"; then
        fail_test "a single passing host test hid $mode evidence"
    fi
    [[ "$evidence_output" == *"atomic evidence or exact-zone cleanup is incomplete"* ]] || \
        fail_test "the $mode evidence guard did not report its cause"
done

print "Cloud Dev transport contract checks passed."
