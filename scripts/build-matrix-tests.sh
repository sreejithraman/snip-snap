#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-build-matrix.XXXXXX)"
cleanup() {
    [[ "$test_root" == /private/tmp/snip-snap-build-matrix.* ]] && /bin/rm -rf "$test_root"
}
trap cleanup EXIT

fail_test() {
    print -u2 "build matrix test failed: $1"
    exit 1
}

/bin/mkdir -p "$test_root/bin"

print -r -- '#!/bin/zsh
set -euo pipefail
print -r -- "$@" >> "$SNIP_SNAP_BUILD_ARGS_FILE"
derived_data=""
scheme=""
while (( $# )); do
    case "$1" in
        -derivedDataPath)
            derived_data="$2"
            shift 2
            ;;
        -scheme)
            scheme="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
if [[ "$scheme" == SnipSnapiOS && "${SNIP_SNAP_FAKE_EMBED_EXTENSION:-YES}" != NO ]]; then
    app_path="$derived_data/Build/Products/Debug-iphonesimulator/Snip Snap iOS.app"
    extension_path="$app_path/PlugIns/SnipSnapShareExtension.appex"
    /bin/mkdir -p "$extension_path"
    if [[ "${SNIP_SNAP_FAKE_EMBED_EXTENSION:-YES}" == YES ]]; then
        : > "$app_path/Snip Snap iOS"
        if [[ "${SNIP_SNAP_FAKE_PRIVACY_MANIFESTS:-YES}" == YES ]]; then
            : > "$app_path/PrivacyInfo.xcprivacy"
            : > "$extension_path/PrivacyInfo.xcprivacy"
        fi
        : > "$extension_path/Info.plist"
        : > "$extension_path/SnipSnapShareExtension"
    fi
fi' > "$test_root/bin/xcodebuild"
/bin/chmod +x "$test_root/bin/xcodebuild"

args_file="$test_root/build-args"
SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
SNIP_SNAP_BUILD_ARGS_FILE="$args_file" \
SNIP_SNAP_DERIVED_DATA="$test_root/derived-data" \
    "$script_dir/build-matrix.sh" \
        --mac-destination 'platform=macOS,arch=arm64' \
        --iphone-destination 'platform=iOS Simulator,name=Example iPhone' \
        --ipad-destination 'platform=iOS Simulator,name=Example iPad' >/dev/null

[[ "$(/usr/bin/wc -l < "$args_file" | /usr/bin/tr -d ' ')" == 3 ]] || \
    fail_test "the matrix did not run exactly three builds"
/usr/bin/sed -n '1p' "$args_file" | /usr/bin/grep -F -- \
    '-scheme SnipSnap -configuration Debug -destination platform=macOS,arch=arm64' >/dev/null || \
    fail_test "the Mac destination override was not used"
/usr/bin/sed -n '2p' "$args_file" | /usr/bin/grep -F -- \
    '-scheme SnipSnapiOS -configuration Debug -destination platform=iOS Simulator,name=Example iPhone' >/dev/null || \
    fail_test "the iPhone destination override was not used"
/usr/bin/sed -n '2p' "$args_file" | /usr/bin/grep -F -- \
    'TARGETED_DEVICE_FAMILY=1' >/dev/null || \
    fail_test "the iPhone build did not select the phone family"
/usr/bin/sed -n '3p' "$args_file" | /usr/bin/grep -F -- \
    '-scheme SnipSnapiOS -configuration Debug -destination platform=iOS Simulator,name=Example iPad' >/dev/null || \
    fail_test "the iPad destination override was not used"
/usr/bin/sed -n '3p' "$args_file" | /usr/bin/grep -F -- \
    'TARGETED_DEVICE_FAMILY=2' >/dev/null || \
    fail_test "the iPad build did not select the tablet family"
[[ "$(/usr/bin/grep -Fc -- 'CODE_SIGNING_ALLOWED=NO' "$args_file")" == 3 ]] || \
    fail_test "one or more matrix builds allowed signing"

if failure_output="$(
    SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
    SNIP_SNAP_FAKE_EMBED_EXTENSION=NO \
    SNIP_SNAP_BUILD_ARGS_FILE="$test_root/missing-extension-args" \
    SNIP_SNAP_DERIVED_DATA="$test_root/missing-extension-derived-data" \
        "$script_dir/build-matrix.sh" 2>&1
)"; then
    fail_test "the matrix accepted an app without its embedded Share extension"
fi
[[ "$failure_output" == *'embedded Share extension'* ]] || \
    fail_test "the missing extension error did not name the failed check"

if failure_output="$(
    SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
    SNIP_SNAP_FAKE_EMBED_EXTENSION=EMPTY \
    SNIP_SNAP_BUILD_ARGS_FILE="$test_root/empty-extension-args" \
    SNIP_SNAP_DERIVED_DATA="$test_root/empty-extension-derived-data" \
        "$script_dir/build-matrix.sh" 2>&1
)"; then
    fail_test "the matrix accepted an empty Share extension bundle"
fi
[[ "$failure_output" == *'built Share extension bundle'* ]] || \
    fail_test "the empty extension error did not name the failed check"

if failure_output="$(
    SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
    SNIP_SNAP_FAKE_PRIVACY_MANIFESTS=NO \
    SNIP_SNAP_BUILD_ARGS_FILE="$test_root/missing-privacy-args" \
    SNIP_SNAP_DERIVED_DATA="$test_root/missing-privacy-derived-data" \
        "$script_dir/build-matrix.sh" 2>&1
)"; then
    fail_test "the matrix accepted app bundles without privacy manifests"
fi
[[ "$failure_output" == *'missing its privacy manifest'* ]] || \
    fail_test "the missing privacy manifest error did not name the failed check"

stale_root="$test_root/stale-derived-data"
for family in iphone ipad; do
    stale_extension="$stale_root/$family/Build/Products/Debug-iphonesimulator/Snip Snap iOS.app/PlugIns/SnipSnapShareExtension.appex"
    /bin/mkdir -p "$stale_extension"
    : > "$stale_extension/Info.plist"
    : > "$stale_extension/SnipSnapShareExtension"
done
if failure_output="$(
    SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
    SNIP_SNAP_FAKE_EMBED_EXTENSION=NO \
    SNIP_SNAP_BUILD_ARGS_FILE="$test_root/stale-extension-args" \
    SNIP_SNAP_DERIVED_DATA="$stale_root" \
        "$script_dir/build-matrix.sh" 2>&1
)"; then
    fail_test "the matrix accepted a stale Share extension from an earlier run"
fi
[[ "$failure_output" == *'embedded Share extension'* ]] || \
    fail_test "the stale extension error did not name the failed check"

print "Build matrix checks passed."
