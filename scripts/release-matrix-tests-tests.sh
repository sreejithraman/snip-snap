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
SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
SNIP_SNAP_RELEASE_TEST_ARGS_FILE="$args_file" \
SNIP_SNAP_DERIVED_DATA="$test_root/derived-data" \
    "$script_dir/release-matrix-tests.sh" \
        --iphone-destination 'platform=iOS Simulator,name=Example iPhone' \
        --ipad-destination 'platform=iOS Simulator,name=Example iPad' >/dev/null

[[ "$(/usr/bin/wc -l < "$args_file" | /usr/bin/tr -d ' ')" == 4 ]] || \
    fail_test "the release matrix did not run exactly four Simulator test commands"

for line in 1 3; do
    destination='platform=iOS Simulator,name=Example iPhone'
    [[ "$line" == 3 ]] && destination='platform=iOS Simulator,name=Example iPad'
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        "Packages/SnipSnapLibrary :: -scheme SnipSnapLibrary-Package -configuration Debug -destination $destination" >/dev/null || \
        fail_test "the package transfer test missed $destination"
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '-only-testing:SnipSnapCloudTests/CloudAttachmentTransferTests/testTwentyFiveMiBDownloadVerifiesHashRetriesInterruptionAndUsesBoundedCache' >/dev/null || \
        fail_test "the package command missed the exact 25 MiB transfer test"
done

for line in 2 4; do
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '-only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testSyncEnableReportsEveryAttachmentAboveTheSnipSnapLimit' >/dev/null || \
        fail_test "the app command missed the over-limit setup action"
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '-only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testSharesMultipleSelectedSnips' >/dev/null || \
        fail_test "the app command missed the Share flow"
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '-only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/testLocalAttachmentsPreviewRemoveAndSurviveRelaunch' >/dev/null || \
        fail_test "the app command missed the attachment flow"
done

[[ "$(/usr/bin/grep -Fc -- 'CODE_SIGNING_ALLOWED=NO' "$args_file")" == 4 ]] || \
    fail_test "one or more Simulator tests allowed signing"

/usr/bin/grep -F -- 'run: ./scripts/build.sh' \
    "$script_dir/../.github/workflows/ci.yml" >/dev/null || \
    fail_test "CI does not run the Release compile check"

print "Release matrix test checks passed."
