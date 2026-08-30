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
python_tool="${SNIP_SNAP_PYTHON:-python3}"
share_fixture_pid=""
share_fixture_port="58493"
share_fixture_lock="/private/tmp/snip-snap-share-fixture-${share_fixture_port}.lock"
share_fixture_lock_owned="0"

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
    if [[ -n "$share_fixture_pid" ]]; then
        /bin/kill "$share_fixture_pid" >/dev/null 2>&1 || true
        wait "$share_fixture_pid" 2>/dev/null || true
        share_fixture_pid=""
        print "Share fixture stopped."
    fi
    if [[ "$share_fixture_lock_owned" == "1" ]]; then
        /bin/rmdir "$share_fixture_lock" >/dev/null 2>&1 || true
        share_fixture_lock_owned="0"
    fi
    [[ -f "$owner_marker" ]] && /bin/rm -rf "$derived_data_root"
}

run_stage() {
    local exit_code
    if "$@"; then
        return 0
    else
        exit_code="$?"
        cleanup
        exit "$exit_code"
    fi
}

trap cleanup INT TERM HUP
start_share_fixture() {
    local root="$derived_data_root/share-fixture"
    local port_file="$derived_data_root/share-fixture-port"
    local log_file="$derived_data_root/share-fixture.log"
    /bin/mkdir "$share_fixture_lock" 2>/dev/null || {
        print -u2 "Release matrix: another Share fixture owns loopback port $share_fixture_port."
        return 1
    }
    share_fixture_lock_owned="1"
    /bin/mkdir -p "$root"
    print -r -- '<!doctype html><html><head><title>Snip Snap Share Fixture</title></head><body><h1>Snip Snap Share Fixture</h1></body></html>' > "$root/index.html"
    "$python_tool" "$script_dir/local-share-fixture.py" "$root" "$port_file" "$share_fixture_port" \
        >"$log_file" 2>&1 &
    share_fixture_pid="$!"
    for _ in {1..100}; do
        [[ -s "$port_file" ]] && break
        /bin/kill -0 "$share_fixture_pid" >/dev/null 2>&1 || break
        /bin/sleep 0.05
    done
    [[ -s "$port_file" ]] || {
        print -u2 "Release matrix: the local Share fixture did not start."
        [[ ! -s "$log_file" ]] || /bin/cat "$log_file" >&2
        return 1
    }
    local port="$(/bin/cat "$port_file")"
    [[ "$port" == "$share_fixture_port" ]] || {
        print -u2 "Release matrix: the local Share fixture returned an invalid port."
        return 1
    }
    print "Share fixture started: http://127.0.0.1:$port/"
}

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
            -only-testing:SnipSnapCloudTests/CloudAttachmentTransferTests/testHundredMiBPerSnipLimitAcceptsInclusiveTotalAndRejectsOneByteOver \
            -only-testing:SnipSnapCloudTests/CloudAttachmentTransferTests/testQuotaUploadFailureDoesNotFalseAcceptBeforeRetry \
            -only-testing:SnipSnapCloudTests/CloudAttachmentTransferTests/testInterruptedUploadRetriesWithoutDuplicateAcceptance \
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

run_stage start_share_fixture

print "Release matrix tests: iPhone 25 MiB transfer"
run_stage run_transfer_test "$iphone_destination" "$derived_data_root/iphone-transfer"
print "Release matrix tests: iPhone limit, Share, and attachment actions"
run_stage run_app_actions "$iphone_destination" "$derived_data_root/iphone-app"
print "Release matrix tests: iPhone Share extension process"
run_stage run_share_process "$iphone_destination" "$derived_data_root/iphone-share-process"
print "Release matrix tests: iPad 25 MiB transfer"
run_stage run_transfer_test "$ipad_destination" "$derived_data_root/ipad-transfer"
print "Release matrix tests: iPad limit, Share, and attachment actions"
run_stage run_app_actions "$ipad_destination" "$derived_data_root/ipad-app"
print "Release matrix tests: iPad Share extension process"
run_stage run_share_process "$ipad_destination" "$derived_data_root/ipad-share-process"

print "iPhone and iPad release-matrix tests passed."
cleanup
