#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-release-matrix-tests.XXXXXX)"
fixture_lock="/private/tmp/snip-snap-share-fixture-58493.lock"
test_fixture_lock_owned=0
cleanup() {
    [[ "$test_fixture_lock_owned" == 0 ]] || /bin/rmdir "$fixture_lock" 2>/dev/null || true
    [[ "$test_root" == /private/tmp/snip-snap-release-matrix-tests.* ]] && \
        /bin/rm -rf "$test_root"
}
trap cleanup EXIT

fail_test() {
    print -u2 "release matrix test failed: $1"
    exit 1
}

/bin/mkdir -p "$test_root/bin"
print -r -- '#!/bin/zsh
set -euo pipefail
[[ -s "$SNIP_SNAP_RELEASE_FIXTURE_PID_FILE" ]] && /bin/kill -0 "$(cat "$SNIP_SNAP_RELEASE_FIXTURE_PID_FILE")" || exit 1
print -r -- "$PWD :: $@" >> "$SNIP_SNAP_RELEASE_TEST_ARGS_FILE"' > \
    "$test_root/bin/xcodebuild"
/bin/chmod +x "$test_root/bin/xcodebuild"
cat > "$test_root/bin/python3" <<'STUB'
#!/bin/zsh
set -euo pipefail
[[ -f "$2/index.html" && "$4" == 58493 ]] || exit 1
print -r -- "$$" > "$SNIP_SNAP_RELEASE_FIXTURE_PID_FILE"
print -r -- "$$" >> "$SNIP_SNAP_RELEASE_FIXTURE_LOG"
trap '/bin/rm -f "$SNIP_SNAP_RELEASE_FIXTURE_PID_FILE"; exit 0' INT TERM
print -r -- "$4" > "$3"
while true; do /bin/sleep 0.05; done
STUB
/bin/chmod +x "$test_root/bin/python3"
export SNIP_SNAP_PYTHON="$test_root/bin/python3"
export SNIP_SNAP_RELEASE_FIXTURE_PID_FILE="$test_root/fixture.pid"
export SNIP_SNAP_RELEASE_FIXTURE_LOG="$test_root/fixture.log"

assert_fixture_cleaned_up() {
    [[ ! -e "$fixture_lock" && ! -e "$SNIP_SNAP_RELEASE_FIXTURE_PID_FILE" ]] || \
        fail_test "the runner left its fixture child or lock behind"
    local fixture_pid
    for fixture_pid in ${(f)"$(cat "$SNIP_SNAP_RELEASE_FIXTURE_LOG")"}; do
        if /bin/kill -0 "$fixture_pid" 2>/dev/null; then
            fail_test "the runner left its fixture child alive"
        fi
    done
    local -a derived_directories=("$test_root"/*derived*(N/))
    (( ${#derived_directories} == 0 )) || fail_test "the runner left owned test files behind"
}

args_file="$test_root/test-args"
output="$(
    SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
    SNIP_SNAP_RELEASE_TEST_ARGS_FILE="$args_file" \
    SNIP_SNAP_DERIVED_DATA="$test_root/derived-data" \
        "$script_dir/release-matrix-tests.sh" \
        --iphone-destination 'platform=iOS Simulator,name=Example iPhone' \
        --ipad-destination 'platform=iOS Simulator,name=Example iPad'
)"

[[ "$(/usr/bin/wc -l < "$args_file" | /usr/bin/tr -d ' ')" == 6 ]] || \
    fail_test "the release matrix did not run exactly six Simulator test commands"

for line in 1 4; do
    destination='platform=iOS Simulator,name=Example iPhone'
    [[ "$line" == 4 ]] && destination='platform=iOS Simulator,name=Example iPad'
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        "Packages/SnipSnapLibrary :: -scheme SnipSnapLibrary-Package -configuration Debug -destination $destination" >/dev/null || \
        fail_test "the package transfer test missed $destination"
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '-only-testing:SnipSnapCloudTests/CloudAttachmentTransferTests/testTwentyFiveMiBDownloadVerifiesHashRetriesInterruptionAndUsesBoundedCache' >/dev/null || \
        fail_test "the package command missed the exact 25 MiB transfer test"
    for test_name in \
        testHundredMiBPerSnipLimitAcceptsInclusiveTotalAndRejectsOneByteOver \
        testQuotaUploadFailureDoesNotFalseAcceptBeforeRetry \
        testInterruptedUploadRetriesWithoutDuplicateAcceptance
    do
        /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
            "-only-testing:SnipSnapCloudTests/CloudAttachmentTransferTests/$test_name" >/dev/null || \
            fail_test "the package command missed $test_name"
    done
done

for line in 2 5; do
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '-only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testSyncEnableReportsEveryAttachmentAboveTheSnipSnapLimit' >/dev/null || \
        fail_test "the app command missed the over-limit setup action"
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '-only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testQuickComposerSendsWithoutOpeningTheEditor' >/dev/null || \
        fail_test "the app command missed the compact composer flow"
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '-only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testCompactListTabsCreateAndSwitchLists' >/dev/null || \
        fail_test "the app command missed the compact list-tab flow"
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '-only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testSharesMultipleSelectedSnips' >/dev/null || \
        fail_test "the app command missed the Share flow"
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '-only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testLocalAttachmentsPreviewRemoveAndSurviveRelaunch' >/dev/null || \
        fail_test "the app command missed the attachment flow"
done

for line in 3 6; do
    destination='platform=iOS Simulator,name=Example iPhone'
    [[ "$line" == 6 ]] && destination='platform=iOS Simulator,name=Example iPad'
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        "-scheme SnipSnapiOS -configuration Debug -destination $destination" >/dev/null || \
        fail_test "the Share extension process command missed $destination"
    for test_name in \
        testSharesSnipBackIntoSnipSnap \
        testShareExtensionImportsExactlyOnceWhileMainAppIsOpen \
        testShareExtensionImportsExactlyOnceWhileMainAppIsClosed \
        testShareExtensionDefersExactlyOnceWhileMainStoreIsUnavailable
    do
        /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
            "-only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/$test_name" >/dev/null || \
            fail_test "the Share extension process command missed $test_name"
    done
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        'CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=' >/dev/null || \
        fail_test "the Share extension process command was not ad-hoc signed"
done

[[ "$(/usr/bin/grep -Fc -- 'CODE_SIGNING_ALLOWED=NO' "$args_file")" == 4 ]] || \
    fail_test "one or more package or app-action tests allowed signing"

/usr/bin/grep -F -- 'run: ./scripts/test.sh --ios-only' \
    "$script_dir/../.github/workflows/ci.yml" >/dev/null || \
    fail_test "CI does not run iOS tests and bundle checks"

for slow_command in \
    'run: ./scripts/build.sh' \
    'run: ./scripts/build-matrix.sh --iphone-only' \
    'run: ./scripts/build-matrix.sh' \
    'run: ./scripts/release-matrix-tests.sh'
do
    if /usr/bin/grep -Fx -- "        $slow_command" \
        "$script_dir/../.github/workflows/ci.yml" >/dev/null
    then
        fail_test "CI still runs a slow build or release step: $slow_command"
    fi
done

/usr/bin/grep -F -- 'assertShareExtensionReportedLocalSave' \
    "$script_dir/../SnipSnapiOSUITests/SnipSnapiOSUITests.swift" >/dev/null || \
    fail_test "the unavailable-store process test does not assert extension save success"

[[ "$output" == *"Share fixture started:"* ]] || \
    fail_test "the release matrix did not report the local fixture start"
[[ "$output" == *"Share fixture stopped."* ]] || \
    fail_test "the release matrix did not stop the local fixture"

assert_fixture_cleaned_up
/bin/mkdir "$fixture_lock"
test_fixture_lock_owned=1
if SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
    SNIP_SNAP_RELEASE_TEST_ARGS_FILE="$test_root/collision-args" \
    SNIP_SNAP_DERIVED_DATA="$test_root/collision-derived" \
        "$script_dir/release-matrix-tests.sh" >/dev/null 2>&1
then
    fail_test "a second release matrix acquired the locked Share fixture port"
fi
[[ -d "$fixture_lock" ]] || fail_test "the collision removed another runner's lock"
[[ ! -e "$test_root/collision-args" ]] || fail_test "testing began despite the fixture collision"
/bin/rmdir "$fixture_lock"
test_fixture_lock_owned=0

print -r -- '#!/bin/zsh
exit 23' > "$test_root/bin/failing-xcodebuild"
/bin/chmod +x "$test_root/bin/failing-xcodebuild"
if SNIP_SNAP_XCODEBUILD="$test_root/bin/failing-xcodebuild" \
    SNIP_SNAP_DERIVED_DATA="$test_root/failure-derived" \
        "$script_dir/release-matrix-tests.sh" >/dev/null 2>&1
then
    fail_test "the release matrix hid an xcodebuild failure"
fi
assert_fixture_cleaned_up

print -r -- '#!/bin/zsh
/bin/kill -s "$SNIP_SNAP_RELEASE_TEST_SIGNAL" "$PPID"
exit 0' > "$test_root/bin/interrupted-xcodebuild"
/bin/chmod +x "$test_root/bin/interrupted-xcodebuild"
for test_signal in INT TERM; do
    if SNIP_SNAP_XCODEBUILD="$test_root/bin/interrupted-xcodebuild" \
        SNIP_SNAP_RELEASE_TEST_SIGNAL="$test_signal" \
        SNIP_SNAP_DERIVED_DATA="$test_root/interrupted-derived" \
            "$script_dir/release-matrix-tests.sh" >/dev/null 2>&1
    then
        fail_test "the release matrix hid $test_signal interruption"
    fi
    assert_fixture_cleaned_up
done

/usr/bin/grep -F -- 'URL(string: "http://127.0.0.1:58493/' \
    "$script_dir/../SnipSnapiOSUITests/SnipSnapiOSUITests.swift" >/dev/null || \
    fail_test "the UI test does not use the locked loopback fixture port"

print "Release matrix test checks passed."
