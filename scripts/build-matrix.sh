#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
program="$0"
derived_data_root="${SNIP_SNAP_DERIVED_DATA:-/tmp/snip-snap-build-matrix}"
mac_destination="${SNIP_SNAP_MAC_DESTINATION:-platform=macOS}"
iphone_destination="${SNIP_SNAP_IPHONE_DESTINATION:-generic/platform=iOS Simulator}"
ipad_destination="${SNIP_SNAP_IPAD_DESTINATION:-generic/platform=iOS Simulator}"
xcodebuild_tool="${SNIP_SNAP_XCODEBUILD:-xcodebuild}"
source_packages="$derived_data_root/SourcePackages"

usage() {
    print -u2 "Usage: $program [--mac-destination DESTINATION] [--iphone-destination DESTINATION] [--ipad-destination DESTINATION]"
}

while (( $# )); do
    case "$1" in
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
    shift 3
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
    local extension_path="$app_path/PlugIns/SnipSnapShareExtension.appex"
    [[ -d "$extension_path" ]] || {
        print -u2 "Build matrix: the iOS app is missing its embedded Share extension: $extension_path"
        return 1
    }
    [[ -f "$extension_path/Info.plist" && \
       -f "$extension_path/SnipSnapShareExtension" ]] || {
        print -u2 "Build matrix: the iOS app does not contain a built Share extension bundle: $extension_path"
        return 1
    }
}

print "Build matrix: Mac"
build SnipSnap "$mac_destination" "$derived_data_root/mac"

print "Build matrix: iPhone Simulator and Share extension"
build SnipSnapiOS "$iphone_destination" "$derived_data_root/iphone" \
    TARGETED_DEVICE_FAMILY=1
assert_embedded_share_extension "$derived_data_root/iphone"

print "Build matrix: iPad Simulator and Share extension"
build SnipSnapiOS "$ipad_destination" "$derived_data_root/ipad" \
    TARGETED_DEVICE_FAMILY=2
assert_embedded_share_extension "$derived_data_root/ipad"

print "Unsigned Mac, iPhone, iPad, and embedded Share extension builds passed."
