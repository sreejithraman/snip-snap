#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
action="${1:-}"
archive_path=""
requested_build=""
temp_root=""
settings_file=""
derived_data=""
export_options=""
export_path=""
build_log=""
upload_log=""
xcodebuild_tool="${SNIP_SNAP_XCODEBUILD:-xcodebuild}"

source "$script_dir/release-policy.sh"
source "$script_dir/signing-policy.sh"
source "$script_dir/testflight-policy.sh"

usage() {
    print -u2 "Usage: $0 archive|validate|upload [--archive-path PATH] [--build-number NUMBER]"
}

fail() {
    print -u2 "TestFlight: $1"
    exit 1
}

[[ -n "$action" ]] || { usage; exit 2; }
shift
while (( $# )); do
    case "$1" in
        --archive-path)
            (( $# >= 2 )) || { usage; exit 2; }
            archive_path="$2"
            shift 2
            ;;
        --build-number)
            (( $# >= 2 )) || { usage; exit 2; }
            requested_build="$2"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done
[[ "$action" == archive || "$action" == validate || "$action" == upload ]] || {
    usage
    exit 2
}

release_policy_load_manifest "$repo_dir/release.json"
version="$RELEASE_VERSION"
build_number="$RELEASE_BUILD_NUMBER"
[[ -z "$requested_build" || "$requested_build" == "$build_number" ]] || \
    fail "--build-number must match release.json"
release_policy_require_project_versions "$repo_dir/Config/Shared.xcconfig"
if [[ "$action" == upload && "${SNIP_SNAP_CONFIRM_TESTFLIGHT_UPLOAD:-}" != YES ]]; then
    fail "set SNIP_SNAP_CONFIRM_TESTFLIGHT_UPLOAD=YES for this upload"
fi

testflight_entitlements="${SNIP_SNAP_TESTFLIGHT_ENTITLEMENTS:-$repo_dir/Config/TestFlight.entitlements}"
[[ -f "$testflight_entitlements" ]] || \
    fail "copy Config/TestFlight.example.entitlements to the ignored Config/TestFlight.entitlements"
typeset -gx SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS="$testflight_entitlements"
if [[ -n "${SHOWROOM_APPLE_TEAM_ID:-}" ]]; then
    typeset -gx SNIP_SNAP_DEVELOPMENT_TEAM="$SHOWROOM_APPLE_TEAM_ID"
fi

cleanup() {
    [[ -z "$temp_root" || "$temp_root" != /private/tmp/snip-snap-testflight.* ]] || \
        /bin/rm -rf "$temp_root"
}
trap cleanup EXIT

temp_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-testflight.XXXXXX)"
settings_file="$temp_root/build-settings.txt"
derived_data="$temp_root/DerivedData"
export_options="$temp_root/ExportOptions.plist"
export_path="$temp_root/export"

signing_policy_capture_build_settings \
    "$repo_dir" Release 'generic/platform=iOS' "$settings_file" \
    "$derived_data" SnipSnapiOS
signing_policy_preflight testflight "$settings_file" "$repo_dir" SnipSnapiOS

development_team="$(signing_policy_resolve_setting \
    "$settings_file" DEVELOPMENT_TEAM SnipSnapiOS)"
app_bundle_identifier="$(signing_policy_resolve_setting \
    "$settings_file" PRODUCT_BUNDLE_IDENTIFIER SnipSnapiOS)"
share_bundle_identifier="$(signing_policy_resolve_setting \
    "$settings_file" PRODUCT_BUNDLE_IDENTIFIER SnipSnapShareExtension)"
product_bundle_root="$(signing_policy_resolve_setting \
    "$settings_file" SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER SnipSnapiOS)"
app_group_identifier="$(signing_policy_resolve_setting \
    "$settings_file" SNIP_SNAP_APP_GROUP_IDENTIFIER SnipSnapiOS)"
cloudkit_container_identifier="$(signing_policy_resolve_setting \
    "$settings_file" SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER SnipSnapiOS)"

release_root="${SNIP_SNAP_TESTFLIGHT_DIR:-$repo_dir/artifacts/testflight-$version-$build_number}"
archive_path="${archive_path:-$release_root/SnipSnap-iOS.xcarchive}"
build_log="$release_root/archive.log"
upload_log="$release_root/upload.log"

authentication_args=()
if [[ -n "${SHOWROOM_APPLE_KEY_PATH:-}" || \
      -n "${SHOWROOM_APPLE_KEY_ID:-}" || \
      -n "${SHOWROOM_APPLE_ISSUER_ID:-}" ]]; then
    [[ -f "${SHOWROOM_APPLE_KEY_PATH:-}" && \
       -n "${SHOWROOM_APPLE_KEY_ID:-}" && \
       -n "${SHOWROOM_APPLE_ISSUER_ID:-}" ]] || \
        fail "the Apple API key inputs are incomplete"
    authentication_args=(
        -authenticationKeyPath "$SHOWROOM_APPLE_KEY_PATH"
        -authenticationKeyID "$SHOWROOM_APPLE_KEY_ID"
        -authenticationKeyIssuerID "$SHOWROOM_APPLE_ISSUER_ID"
    )
fi

archive_and_check() {
    local source_revision
    local source_state
    local source_is_clean=true

    source_revision="$(git -C "$repo_dir" rev-parse HEAD)"
    source_state="$(git -C "$repo_dir" status --porcelain)"
    [[ -z "$source_state" ]] || source_is_clean=false
    /bin/mkdir -p "$release_root"
    "$script_dir/test.sh" --without-mac-app-tests
    "$script_dir/build-matrix.sh"

    "$xcodebuild_tool" \
        -project "$repo_dir/SnipSnap.xcodeproj" \
        -scheme SnipSnapiOS \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$archive_path" \
        -derivedDataPath "$derived_data" \
        -allowProvisioningUpdates \
        "${authentication_args[@]}" \
        "CURRENT_PROJECT_VERSION=$build_number" \
        "DEVELOPMENT_TEAM=$development_team" \
        "MARKETING_VERSION=$version" \
        "SNIP_SNAP_APP_GROUP_IDENTIFIER=$app_group_identifier" \
        "SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER=$cloudkit_container_identifier" \
        "SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS=$testflight_entitlements" \
        "SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=$product_bundle_root" \
        archive > "$build_log" 2>&1 || \
        fail "archive failed; inspect $build_log"

    testflight_policy_require_unchanged_source \
        "$source_revision" "$source_state" \
        "$(git -C "$repo_dir" rev-parse HEAD)" \
        "$(git -C "$repo_dir" status --porcelain)"
    testflight_policy_write_source_record \
        "$archive_path/SnipSnapSource.plist" "$source_revision" "$source_is_clean"

    testflight_policy_verify_archive \
        "$archive_path" \
        "$app_bundle_identifier" \
        "$share_bundle_identifier" \
        "$development_team" \
        "$app_group_identifier" \
        "$cloudkit_container_identifier" \
        "$version" \
        "$build_number"
}

case "$action" in
    archive)
        archive_and_check
        print "TestFlight archive: $archive_path"
        ;;
    validate)
        testflight_policy_verify_archive \
            "$archive_path" \
            "$app_bundle_identifier" \
            "$share_bundle_identifier" \
            "$development_team" \
            "$app_group_identifier" \
            "$cloudkit_container_identifier" \
            "$version" \
            "$build_number"
        ;;
    upload)
        release_policy_require_source "$repo_dir" \
            "${SNIP_SNAP_RELEASE_REPO:-sreejithraman/snip-snap}"
        [[ -d "$archive_path" ]] || archive_and_check
        testflight_policy_verify_source_record \
            "$archive_path" "$(git -C "$repo_dir" rev-parse HEAD)"
        testflight_policy_verify_archive \
            "$archive_path" \
            "$app_bundle_identifier" \
            "$share_bundle_identifier" \
            "$development_team" \
            "$app_group_identifier" \
            "$cloudkit_container_identifier" \
            "$version" \
            "$build_number"
        testflight_policy_write_export_options "$export_options" "$development_team"
        "$xcodebuild_tool" \
            -exportArchive \
            -archivePath "$archive_path" \
            -exportPath "$export_path" \
            -exportOptionsPlist "$export_options" \
            -allowProvisioningUpdates \
            "${authentication_args[@]}" > "$upload_log" 2>&1 || \
            fail "upload failed; inspect $upload_log"
        print "Apple received Snip Snap $version ($build_number) for processing."
        ;;
esac
