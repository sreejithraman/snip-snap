#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
destination="generic/platform=iOS"
derived_data="${SNIP_SNAP_CLOUD_DEV_DERIVED_DATA:-$repo_dir/.build/cloud-dev}"
temp_root=""
xcodebuild_tool="${SNIP_SNAP_XCODEBUILD:-xcodebuild}"
platform=ios
slot=""
result_json=""
store_path=""

source "$script_dir/signing-policy.sh"

usage() {
    print -u2 "Usage: $0 build [--platform ios|macos] [--slot SLOT] [--destination DESTINATION] [--derived-data-path PATH] [--result-json PATH] [--store-path PATH]"
}

fail() {
    print -u2 "Cloud Dev: $1"
    exit 1
}

[[ "${1:-}" == build ]] || { usage; exit 2; }
shift
while (( $# )); do
    case "$1" in
        --platform|--slot|--result-json|--store-path)
            (( $# >= 2 )) || { usage; exit 2; }
            case "$1" in
                --platform) platform="$2" ;;
                --slot) slot="$2" ;;
                --result-json) result_json="$2" ;;
                --store-path) store_path="$2" ;;
            esac
            shift 2
            ;;
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
case "$platform" in
    ios) scheme=SnipSnapiOS ;;
    macos)
        scheme=SnipSnap
        [[ "$destination" != generic/platform=iOS ]] || destination='platform=macOS'
        ;;
    *) usage; exit 2 ;;
esac
[[ -z "$slot" || ( "$slot" =~ '^[1-9][0-9]*$' && "$slot" -le 1000 ) ]] || \
    fail "slot must be a number from 1 through 1000"

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
    "$temp_root/BaseDerivedData" "$scheme"

base_product_identifier="$(signing_policy_resolve_setting \
    "$base_settings" PRODUCT_BUNDLE_IDENTIFIER "$scheme")"
base_app_group_identifier="$(signing_policy_resolve_setting \
    "$base_settings" SNIP_SNAP_APP_GROUP_IDENTIFIER "$scheme")"
dev_product_setting=SNIP_SNAP_DEV_IOS_PRODUCT_BUNDLE_IDENTIFIER
[[ "$platform" != macos ]] || dev_product_setting=SNIP_SNAP_DEV_MAC_PRODUCT_BUNDLE_IDENTIFIER
configured_dev_product_identifier="$(signing_policy_resolve_setting \
    "$base_settings" "$dev_product_setting" "$scheme")"
configured_dev_app_group_identifier="$(signing_policy_resolve_setting \
    "$base_settings" SNIP_SNAP_DEV_APP_GROUP_IDENTIFIER "$scheme")"
[[ -n "$base_product_identifier" ]] || fail "the product bundle identifier is missing"
[[ -n "$base_app_group_identifier" ]] || fail "SNIP_SNAP_APP_GROUP_IDENTIFIER is missing"

dev_suffix=.dev
[[ -z "$slot" ]] || dev_suffix=".cloud.dev$slot"
dev_product_identifier="${(P)dev_product_setting:-${configured_dev_product_identifier:-$base_product_identifier$dev_suffix}}"
dev_share_product_identifier="$dev_product_identifier.share"
dev_app_group_identifier="${SNIP_SNAP_DEV_APP_GROUP_IDENTIFIER:-${configured_dev_app_group_identifier:-$base_app_group_identifier$dev_suffix}}"
[[ "$dev_product_identifier" != "$base_product_identifier" ]] || \
    fail "the Dev app bundle identifier must differ from production"
[[ "$dev_app_group_identifier" != "$base_app_group_identifier" ]] || \
    fail "the Cloud Dev App Group must differ from production"
if [[ -n "$slot" ]]; then
    [[ "$dev_product_identifier" == *.cloud.dev$slot && \
       "$dev_app_group_identifier" == *.cloud.dev$slot ]] || \
        fail "run identities must end in .cloud.dev$slot to isolate them from ordinary Dev apps"
fi

if [[ "$platform" == ios ]]; then
    typeset -gx SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER="$dev_product_identifier"
    typeset -gx SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER="$dev_share_product_identifier"
fi
typeset -gx SNIP_SNAP_APP_GROUP_IDENTIFIER="$dev_app_group_identifier"

# Resolve the isolated Mac app's signing settings.
if [[ "$platform" == macos ]]; then
    typeset -gx SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER="$dev_product_identifier"
fi
signing_policy_capture_build_settings \
    "$repo_dir" Debug "$destination" "$cloud_dev_settings" \
    "$temp_root/CloudDevDerivedData" "$scheme"
signing_policy_preflight cloud "$cloud_dev_settings" "$repo_dir" "$scheme"

development_team="$(signing_policy_resolve_setting \
    "$cloud_dev_settings" DEVELOPMENT_TEAM "$scheme")"
cloudkit_container_identifier="$(signing_policy_resolve_setting \
    "$cloud_dev_settings" SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER "$scheme")"
app_entitlements="$(signing_policy_resolve_setting \
    "$cloud_dev_settings" CODE_SIGN_ENTITLEMENTS "$scheme")"
display_name='Snip Snap Dev'
[[ -z "$slot" ]] || display_name="Snip Snap Cloud Dev $slot"
product_name='Snip Snap iOS'
platform_arguments=(
    "SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER=$dev_product_identifier"
    "SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER=$dev_share_product_identifier"
    "SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS=$app_entitlements"
    "SNIP_SNAP_SHARE_DISPLAY_NAME=Save to $display_name"
)
if [[ "$platform" == macos ]]; then
    product_name=SnipSnapCloudDev
    [[ -z "$slot" ]] || product_name="SnipSnapCloudDev$slot"
    platform_arguments=(
        "SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=$dev_product_identifier"
        "SNIP_SNAP_PRODUCT_NAME=$product_name"
        "INFOPLIST_KEY_CFBundleDisplayName=$display_name"
        "CODE_SIGN_ENTITLEMENTS=$app_entitlements"
        "SNIP_SNAP_DEV_STORE_PATH=$store_path"
    )
fi

/bin/mkdir -p "$derived_data"
"$xcodebuild_tool" \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    "DEVELOPMENT_TEAM=$development_team" \
    REGISTER_APP_GROUPS=YES \
    "SNIP_SNAP_BUILD_LANE=cloud-dev" \
    "${platform_arguments[@]}" \
    "SNIP_SNAP_APP_GROUP_IDENTIFIER=$dev_app_group_identifier" \
    "SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER=$cloudkit_container_identifier" \
    SNIP_SNAP_CLOUDKIT_ENVIRONMENT=Development \
    "SNIP_SNAP_DISPLAY_NAME=$display_name" \
    "ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev" \
    build

if [[ -n "$result_json" ]]; then
    products_directory=Debug-iphoneos
    [[ "$platform" != macos ]] || products_directory=Debug
    /bin/mkdir -p "${result_json:h}"
    /usr/bin/python3 - "$result_json" "$derived_data/Build/Products/$products_directory/$product_name.app" \
        "$dev_product_identifier" "$dev_app_group_identifier" "$cloudkit_container_identifier" "$development_team" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps(dict(zip(
    ('app_path', 'bundle_id', 'app_group', 'container', 'team'), sys.argv[2:]))) + '\n')
PY
fi
print "Built $display_name. It can stay installed beside the release app."
print "Build output: $derived_data"
