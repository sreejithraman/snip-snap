#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
program="$0"
derived_data_prefix="${SNIP_SNAP_DERIVED_DATA:-/private/tmp/snip-snap-build-matrix}"
[[ "$derived_data_prefix" == /* ]] || {
    print -u2 "Build matrix: SNIP_SNAP_DERIVED_DATA must be an absolute path prefix."
    exit 2
}
derived_data_root="$(/usr/bin/mktemp -d "${derived_data_prefix}.XXXXXX")"
owner_marker="$derived_data_root/.snip-snap-build-matrix-owned"
/usr/bin/touch "$owner_marker"
cleanup() {
    [[ -f "$owner_marker" ]] && /bin/rm -rf "$derived_data_root"
}
trap cleanup EXIT
mac_destination="${SNIP_SNAP_MAC_DESTINATION:-platform=macOS}"
iphone_destination="${SNIP_SNAP_IPHONE_DESTINATION:-generic/platform=iOS Simulator}"
ipad_destination="${SNIP_SNAP_IPAD_DESTINATION:-generic/platform=iOS Simulator}"
xcodebuild_tool="${SNIP_SNAP_XCODEBUILD:-xcodebuild}"
source_packages="$derived_data_root/SourcePackages"
build_mac=YES
build_ipad=YES

usage() {
    print -u2 "Usage: $program [--iphone-only] [--mac-destination DESTINATION] [--iphone-destination DESTINATION] [--ipad-destination DESTINATION]"
}

while (( $# )); do
    case "$1" in
        --iphone-only)
            build_mac=NO
            build_ipad=NO
            shift
            ;;
        --mac-destination)
            (( $# >= 2 )) || { usage; exit 2; }
            mac_destination="$2"
            shift 2
            ;;
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

build() {
    local scheme="$1"
    local destination="$2"
    local derived_data="$3"
    local build_marker="$derived_data/.snip-snap-build-start"
    shift 3
    /bin/mkdir -p "$derived_data"
    /usr/bin/touch "$build_marker"
    "$xcodebuild_tool" \
        -project "$repo_dir/SnipSnap.xcodeproj" \
        -scheme "$scheme" \
        -configuration Debug \
        -destination "$destination" \
        -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$source_packages" \
        CODE_SIGNING_ALLOWED=NO \
        "$@" \
        build
}

assert_embedded_share_extension() {
    local derived_data="$1"
    local app_path="$derived_data/Build/Products/Debug-iphonesimulator/Snip Snap iOS.app"
    local app_executable="$app_path/Snip Snap iOS"
    local extension_path="$app_path/PlugIns/SnipSnapShareExtension.appex"
    local extension_executable="$extension_path/SnipSnapShareExtension"
    local build_marker="$derived_data/.snip-snap-build-start"
    [[ -d "$extension_path" ]] || {
        print -u2 "Build matrix: the iOS app is missing its embedded Share extension: $extension_path"
        return 1
    }
    [[ -f "$app_executable" && -f "$extension_path/Info.plist" && \
       -f "$extension_executable" ]] || {
        print -u2 "Build matrix: the iOS app does not contain a built Share extension bundle: $extension_path"
        return 1
    }
    [[ -f "$app_path/PrivacyInfo.xcprivacy" && \
       -f "$extension_path/PrivacyInfo.xcprivacy" ]] || {
        print -u2 "Build matrix: the iOS app or Share extension is missing its privacy manifest."
        return 1
    }
    [[ "$app_executable" -nt "$build_marker" && \
       "$extension_executable" -nt "$build_marker" ]] || {
        print -u2 "Build matrix: the iOS app or Share extension was not built in this matrix run."
        return 1
    }
}

if [[ "$build_mac" == YES ]]; then
    print "Build matrix: Mac"
    build SnipSnap "$mac_destination" "$derived_data_root/mac"
fi

print "Build matrix: iPhone Simulator and Share extension"
build SnipSnapiOS "$iphone_destination" "$derived_data_root/iphone" \
    TARGETED_DEVICE_FAMILY=1
assert_embedded_share_extension "$derived_data_root/iphone"

if [[ "$build_ipad" == YES ]]; then
    print "Build matrix: iPad Simulator and Share extension"
    build SnipSnapiOS "$ipad_destination" "$derived_data_root/ipad" \
        TARGETED_DEVICE_FAMILY=2
    assert_embedded_share_extension "$derived_data_root/ipad"
fi

if [[ "$build_mac" == YES && "$build_ipad" == YES ]]; then
    print "Unsigned Mac, iPhone, iPad, embedded Share extension, and privacy manifest builds passed."
else
    print "Unsigned iPhone, embedded Share extension, and privacy manifest build passed."
fi
