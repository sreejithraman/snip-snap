#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
preflight_tool="${SNIP_SNAP_SIGNED_LANE_PREFLIGHT:-$script_dir/signed-lane-preflight.sh}"
xcodebuild_tool="${SNIP_SNAP_XCODEBUILD:-xcodebuild}"
xcresulttool_tool="${SNIP_SNAP_XCRESULTTOOL:-}"

if [[ "${SNIP_SNAP_RUN_CLOUD_DEV_TRANSPORT_CONTRACT:-}" != 1 ]]; then
    print -u2 "Cloud Dev transport contract is maintainer-only. Set SNIP_SNAP_RUN_CLOUD_DEV_TRANSPORT_CONTRACT=1 after configuring the signed Cloud Dev lane."
    exit 2
fi

build_cache="${SNIP_SNAP_DERIVED_DATA:-$repo_dir/.build/cloud-dev-transport-contract}"
evidence_root="${SNIP_SNAP_CLOUD_DEV_TRANSPORT_CONTRACT_ARTIFACTS:-$repo_dir/artifacts/cloud-dev-transport-contract}"

report_failure() {
    print -u2 "Cloud Dev transport contract failed: $1"
    print -u2 "Evidence: $run_dir"
}

[[ "$build_cache" == /* ]] || {
    print -u2 "Cloud Dev transport contract requires an absolute SNIP_SNAP_DERIVED_DATA path."
    exit 2
}
[[ "$evidence_root" == /* ]] || {
    print -u2 "Cloud Dev transport contract requires an absolute SNIP_SNAP_CLOUD_DEV_TRANSPORT_CONTRACT_ARTIFACTS path."
    exit 2
}

"$preflight_tool" cloud \
    --scheme SnipSnap \
    --configuration Debug \
    --destination 'platform=macOS'

/bin/mkdir -p "$build_cache" "$evidence_root"
run_dir="$(/usr/bin/mktemp -d "$evidence_root/run.XXXXXX")"
cache_lock="$build_cache/.cloud-dev-transport-contract-lock"
if ! /bin/mkdir "$cache_lock" 2>/dev/null; then
    report_failure "build cache is locked: $cache_lock. Wait for the other run; if it was interrupted, remove the lock only after confirming it has stopped."
    exit 2
fi
trap '/bin/rmdir "$cache_lock"' EXIT

result_bundle="$run_dir/CloudDevTransportContract.xcresult"
result_summary="$run_dir/CloudDevTransportContract.json"
result_summary_error="$run_dir/CloudDevTransportContract-summary-error.log"
xcodebuild_log="$run_dir/xcodebuild.log"
local_store_path="$run_dir/local-store/snips.json"
/bin/mkdir -p "${local_store_path:h}"

set +e
SNIP_SNAP_STORE_PATH="$local_store_path" "$xcodebuild_tool" \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme SnipSnap \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$build_cache" \
    -resultBundlePath "$result_bundle" \
    CODE_SIGNING_ALLOWED=YES \
    SNIP_SNAP_CLOUD_DEV_TRANSPORT_CONTRACT_ENABLED=YES \
    -only-testing:SnipSnapTests/CloudDevTransportContractTests \
    test 2>&1 | /usr/bin/tee "$xcodebuild_log"
statuses=("${pipestatus[@]}")
set -e
xcodebuild_status="${statuses[1]}"
tee_status="${statuses[2]}"

summary_ready=NO
summary_line=""
if [[ -d "$result_bundle" ]]; then
    if [[ -n "$xcresulttool_tool" ]]; then
        "$xcresulttool_tool" "$result_bundle" > "$result_summary" 2> "$result_summary_error" || true
    else
        xcrun xcresulttool get test-results summary \
            --path "$result_bundle" --format json > "$result_summary" 2> "$result_summary_error" || true
    fi

    if [[ -s "$result_summary" ]]; then
        total_test_count="$(/usr/bin/plutil -extract totalTestCount raw "$result_summary" 2>/dev/null || true)"
        passed_test_count="$(/usr/bin/plutil -extract passedTests raw "$result_summary" 2>/dev/null || true)"
        failed_test_count="$(/usr/bin/plutil -extract failedTests raw "$result_summary" 2>/dev/null || true)"
        skipped_test_count="$(/usr/bin/plutil -extract skippedTests raw "$result_summary" 2>/dev/null || true)"
        if [[ -n "$total_test_count" && -n "$passed_test_count" \
            && -n "$failed_test_count" && -n "$skipped_test_count" ]]
        then
            summary_ready=YES
            summary_line="total=$total_test_count passed=$passed_test_count failed=$failed_test_count skipped=$skipped_test_count"
            print "Cloud Dev transport contract result: $summary_line"
            failure_texts="$(/usr/bin/ruby -rjson -e '
                JSON.parse(File.read(ARGV[0])).fetch("testFailures", []).each do |failure|
                  text = failure["failureText"]
                  puts text if text.is_a?(String) && !text.empty?
                end
            ' "$result_summary" 2>/dev/null || true)"
            if [[ -n "$failure_texts" ]]; then
                print -u2 "Cloud Dev transport contract test failure:"
                print -u2 -r -- "$failure_texts"
            fi
        fi
    fi
fi

if [[ "$xcodebuild_status" != 0 ]]; then
    report_failure "xcodebuild exited $xcodebuild_status${summary_line:+; $summary_line}"
    exit "$xcodebuild_status"
fi
if [[ "$tee_status" != 0 ]]; then
    report_failure "could not write the xcodebuild log"
    exit "$tee_status"
fi
if [[ ! -d "$result_bundle" ]]; then
    report_failure "xcodebuild completed without a result bundle"
    exit 1
fi
if [[ "$summary_ready" != YES ]]; then
    report_failure "could not read the test-result summary; see $result_summary_error"
    exit 1
fi

[[ "$total_test_count" == 1 \
    && "$passed_test_count" == 1 \
    && "$failed_test_count" == 0 \
    && "$skipped_test_count" == 0 ]] || {
    report_failure "expected one passing, non-skipped test; $summary_line"
    exit 1
}

print "Signed Cloud Dev fake-versus-real transport contract passed. Evidence: $run_dir"
