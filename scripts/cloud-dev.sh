#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
destination="generic/platform=iOS"
derived_data="${SNIP_SNAP_CLOUD_DEV_DERIVED_DATA:-$repo_dir/.build/cloud-dev}"
temp_root=""
xcodebuild_tool="${SNIP_SNAP_XCODEBUILD:-xcodebuild}"

source "$script_dir/signing-policy.sh"

usage() {
    print -u2 "Usage: $0 build [--destination DESTINATION] [--derived-data-path PATH]"
}

fail() {
    print -u2 "Cloud Dev: $1"
    exit 1
}

[[ "${1:-}" == build ]] || { usage; exit 2; }
shift
while (( $# )); do
    case "$1" in
        --destination)
            (( $# >= 2 )) || { usage; exit 2; }
            destination="$2"
            shift 2
            ;;
        --derived-data-path)
            (( $# >= 2 )) || { usage; exit 2; }
            derived_data="$2"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

cleanup() {
    [[ -z "$temp_root" || "$temp_root" != /private/tmp/snip-snap-cloud-dev.* ]] || \
        /bin/rm -rf "$temp_root"
}
trap cleanup EXIT

temp_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-cloud-dev.XXXXXX)"
base_settings="$temp_root/base-settings.txt"
cloud_dev_settings="$temp_root/cloud-dev-settings.txt"

signing_policy_capture_build_settings \
    "$repo_dir" Debug "$destination" "$base_settings" \
    "$temp_root/BaseDerivedData" SnipSnapiOS

base_product_identifier="$(signing_policy_resolve_setting \
    "$base_settings" SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER SnipSnapiOS)"
base_app_group_identifier="$(signing_policy_resolve_setting \
    "$base_settings" SNIP_SNAP_APP_GROUP_IDENTIFIER SnipSnapiOS)"
configured_cloud_dev_product_identifier="$(signing_policy_resolve_setting \
    "$base_settings" SNIP_SNAP_CLOUD_DEV_PRODUCT_BUNDLE_IDENTIFIER SnipSnapiOS)"
configured_cloud_dev_app_group_identifier="$(signing_policy_resolve_setting \
    "$base_settings" SNIP_SNAP_CLOUD_DEV_APP_GROUP_IDENTIFIER SnipSnapiOS)"
[[ -n "$base_product_identifier" ]] || fail "SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER is missing"
[[ -n "$base_app_group_identifier" ]] || fail "SNIP_SNAP_APP_GROUP_IDENTIFIER is missing"

cloud_dev_product_identifier="${SNIP_SNAP_CLOUD_DEV_PRODUCT_BUNDLE_IDENTIFIER:-${configured_cloud_dev_product_identifier:-$base_product_identifier.clouddev}}"
cloud_dev_app_group_identifier="${SNIP_SNAP_CLOUD_DEV_APP_GROUP_IDENTIFIER:-${configured_cloud_dev_app_group_identifier:-$base_app_group_identifier.clouddev}}"
[[ "$cloud_dev_product_identifier" != "$base_product_identifier" ]] || \
    fail "the Cloud Dev bundle root must differ from production"
[[ "$cloud_dev_app_group_identifier" != "$base_app_group_identifier" ]] || \
    fail "the Cloud Dev App Group must differ from production"

typeset -gx SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER="$cloud_dev_product_identifier"
typeset -gx SNIP_SNAP_APP_GROUP_IDENTIFIER="$cloud_dev_app_group_identifier"

signing_policy_capture_build_settings \
    "$repo_dir" Debug "$destination" "$cloud_dev_settings" \
    "$temp_root/CloudDevDerivedData" SnipSnapiOS
signing_policy_preflight cloud "$cloud_dev_settings" "$repo_dir" SnipSnapiOS

/bin/mkdir -p "$derived_data"
"$xcodebuild_tool" \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme SnipSnapiOS \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    "SNIP_SNAP_BUILD_LANE=cloud-dev" \
    "SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=$cloud_dev_product_identifier" \
    "SNIP_SNAP_APP_GROUP_IDENTIFIER=$cloud_dev_app_group_identifier" \
    "SNIP_SNAP_DISPLAY_NAME=Snip Snap Dev" \
    "SNIP_SNAP_SHARE_DISPLAY_NAME=Save to Snip Snap Dev" \
    "ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev" \
    build

print "Built Snip Snap Dev. It can stay installed beside TestFlight."
print "Build output: $derived_data"
