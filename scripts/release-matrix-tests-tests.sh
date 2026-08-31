#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-release-matrix-tests.XXXXXX)"
cleanup() {
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
print -r -- "$PWD :: $@" >> "$SNIP_SNAP_RELEASE_TEST_ARGS_FILE"' > \
    "$test_root/bin/xcodebuild"
/bin/chmod +x "$test_root/bin/xcodebuild"

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

/usr/bin/grep -F -- 'run: ./scripts/build.sh' \
    "$script_dir/../.github/workflows/ci.yml" >/dev/null || \
    fail_test "CI does not run the Release compile check"

/usr/bin/grep -F -- 'assertShareExtensionReportedLocalSave' \
    "$script_dir/../SnipSnapiOSUITests/SnipSnapiOSUITests.swift" >/dev/null || \
    fail_test "the unavailable-store process test does not assert extension save success"

[[ "$output" == *"Share fixture started:"* ]] || \
    fail_test "the release matrix did not report the local fixture start"
[[ "$output" == *"Share fixture stopped."* ]] || \
    fail_test "the release matrix did not stop the local fixture"

fixture_lock="/private/tmp/snip-snap-share-fixture-58493.lock"
[[ ! -e "$fixture_lock" ]] || fail_test "the successful run left the Share fixture lock behind"
/bin/mkdir "$fixture_lock"
if SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
    SNIP_SNAP_RELEASE_TEST_ARGS_FILE="$test_root/collision-args" \
    SNIP_SNAP_DERIVED_DATA="$test_root/collision-derived" \
        "$script_dir/release-matrix-tests.sh" >/dev/null 2>&1
then
    fail_test "a second release matrix acquired the locked Share fixture port"
fi
/bin/rmdir "$fixture_lock"

print -r -- '#!/bin/zsh
exit 23' > "$test_root/bin/failing-xcodebuild"
/bin/chmod +x "$test_root/bin/failing-xcodebuild"
if SNIP_SNAP_XCODEBUILD="$test_root/bin/failing-xcodebuild" \
    SNIP_SNAP_DERIVED_DATA="$test_root/failure-derived" \
        "$script_dir/release-matrix-tests.sh" >/dev/null 2>&1
then
    fail_test "the release matrix hid an xcodebuild failure"
fi
[[ ! -e "$fixture_lock" ]] || fail_test "the failed run left the Share fixture lock behind"

/usr/bin/grep -F -- 'URL(string: "http://127.0.0.1:58493/' \
    "$script_dir/../SnipSnapiOSUITests/SnipSnapiOSUITests.swift" >/dev/null || \
    fail_test "the UI test does not use the locked loopback fixture port"

print "Release matrix test checks passed."
