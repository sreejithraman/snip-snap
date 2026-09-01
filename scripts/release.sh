#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
release_repo="${SNIP_SNAP_RELEASE_REPO:-sreejithraman/snip-snap}"
notary_profile="${SNIP_SNAP_NOTARY_PROFILE:-}"
notary_keychain="${SNIP_SNAP_NOTARY_KEYCHAIN:-}"
notary_keychain_args=()
signing_identity="${SNIP_SNAP_SIGNING_IDENTITY:-}"
development_team=""
signing_temp_root=""
resolved_settings=""
export_options=""
mac_release_entitlements="${SNIP_SNAP_MAC_RELEASE_ENTITLEMENTS:-$repo_dir/Config/MacRelease.entitlements}"
cloudkit_container_identifier=""
product_bundle_identifier=""
provisioning_profile_specifier="${SNIP_SNAP_MAC_PROVISIONING_PROFILE_SPECIFIER:-}"
requested_build=""

source "$script_dir/release-policy.sh"
source "$script_dir/signing-policy.sh"

[[ -z "$notary_keychain" ]] || notary_keychain_args=(--keychain "$notary_keychain")

fail() {
    print -u2 "release: $1"
    exit 1
}

usage() {
    print -u2 "Usage: $0 --build-number NUMBER"
}

while (( $# )); do
    case "$1" in
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
[[ -n "$requested_build" ]] || fail "pass --build-number with the generated build number"

verify_release_cloudkit() {
    local archive_app_path="$archive_path/Products/Applications/Snip Snap.app"
    signing_policy_verify_production_cloudkit_app \
        "$archive_app_path" "$cloudkit_container_identifier" \
        "$development_team" "$product_bundle_identifier"
    signing_policy_verify_production_cloudkit_app \
        "$app_path" "$cloudkit_container_identifier" \
        "$development_team" "$product_bundle_identifier"
}

cleanup() {
    [[ -z "$signing_temp_root" || \
       "$signing_temp_root" != /private/tmp/snip-snap-release-signing.* ]] || \
        /bin/rm -rf "$signing_temp_root"
}
trap cleanup EXIT

signing_temp_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-release-signing.XXXXXX)"
resolved_settings="$signing_temp_root/build-settings.txt"
export_options="$signing_temp_root/export-options.plist"
mac_release_entitlements="$(signing_policy_entitlement_path \
    "$repo_dir" "$mac_release_entitlements")"
[[ -f "$mac_release_entitlements" ]] || \
    fail "copy Config/MacRelease.example.entitlements to the ignored Config/MacRelease.entitlements"
typeset -gx SNIP_SNAP_CODE_SIGN_ENTITLEMENTS="$mac_release_entitlements"
signing_policy_capture_build_settings \
    "$repo_dir" Release 'generic/platform=macOS' "$resolved_settings" \
    "$signing_temp_root/DerivedData"
development_team="$(signing_policy_resolve_setting \
    "$resolved_settings" DEVELOPMENT_TEAM)"
cloudkit_container_identifier="$(signing_policy_resolve_setting \
    "$resolved_settings" SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER)"
product_bundle_identifier="$(signing_policy_resolve_setting \
    "$resolved_settings" PRODUCT_BUNDLE_IDENTIFIER)"

if [[ -z "$signing_identity" && -n "$development_team" ]]; then
    signing_identity="$(/usr/bin/security find-identity -v -p codesigning | \
        /usr/bin/awk -v team="$development_team" \
        '/Developer ID Application/ && index($0, "(" team ")") { print $2; exit }')"
fi
typeset -gx SNIP_SNAP_SIGNING_IDENTITY="$signing_identity"
typeset -gx SNIP_SNAP_NOTARY_PROFILE="$notary_profile"
signing_policy_preflight release "$resolved_settings" "$repo_dir" || exit 1

release_policy_preflight "$repo_dir" "$release_repo" release "$requested_build"
version="$RELEASE_VERSION"
build_number="$RELEASE_BUILD_NUMBER"

release_root="${SNIP_SNAP_RELEASE_DIR:-$repo_dir/artifacts/release-$version-$build_number}"
archive_path="$release_root/SnipSnap.xcarchive"
export_path="$release_root/export"
submission_name="Snip-Snap-build-$build_number-$version-submission.dmg"
submission_dmg="$release_root/$submission_name"
release_zip="$release_root/Snip-Snap-$version.zip"
release_dmg="$release_root/Snip-Snap-$version.dmg"
app_path="$export_path/Snip Snap.app"
dmg_source="$release_root/dmg-source"

if [[ "${SNIP_SNAP_RELEASE_CHECKS_PASSED:-}" != YES ]]; then
    "$script_dir/test.sh"
fi

if [[ -e "$release_root" &&
      ( ! -f "$submission_dmg" || ! -d "$app_path" ) ]]; then
    release_policy_require_new_notary_build "$notary_profile" "$build_number" "$notary_keychain"
    incomplete_root="$release_root.incomplete-$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
    /bin/mv "$release_root" "$incomplete_root"
    print "Kept the incomplete release at $incomplete_root."
fi

if [[ -e "$release_root" ]]; then
    [[ -d "$release_root" ]] || fail "$release_root is not a directory"
    verify_release_cloudkit

    history_json="$(/usr/bin/xcrun notarytool history \
        --keychain-profile "$notary_profile" \
        "${notary_keychain_args[@]}" \
        --output-format json)" || fail "could not read Apple notarization history"
    if submission_entry="$(release_policy_notary_submission_entry \
        "$history_json" \
        "$submission_name")"; then
        submission_id="${submission_entry%%$'\t'*}"
        submission_status="${submission_entry#*$'\t'}"
        case "$submission_status" in
            Accepted)
                print "Resuming accepted Apple submission $submission_name."
                ;;
            "In Progress")
                wait_json="$(/usr/bin/xcrun notarytool wait "$submission_id" \
                    --keychain-profile "$notary_profile" \
                    "${notary_keychain_args[@]}" \
                    --output-format json)" || fail "could not wait for $submission_name"
                wait_status="$(print -r -- "$wait_json" | /usr/bin/ruby -rjson -e \
                    'puts JSON.parse(STDIN.read).fetch("status")')" || \
                    fail "could not read Apple status for $submission_name"
                [[ "$wait_status" == Accepted ]] || \
                    fail "Apple submission $submission_name is $wait_status"
                ;;
            *)
                fail "Apple submission $submission_name is $submission_status"
                ;;
        esac
    else
        release_policy_require_new_notary_build "$notary_profile" "$build_number" "$notary_keychain"
        release_policy_verify_app "$app_path"
        /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
        /usr/bin/codesign --verify --verbose=2 "$submission_dmg"
        /usr/bin/hdiutil verify "$submission_dmg"
        /usr/bin/xcrun notarytool submit "$submission_dmg" \
            --keychain-profile "$notary_profile" \
            "${notary_keychain_args[@]}" \
            --wait
    fi
else
    release_policy_require_new_notary_build "$notary_profile" "$build_number" "$notary_keychain"
    /bin/mkdir -p "$release_root"

    /usr/bin/xcodebuild \
        -project "$repo_dir/SnipSnap.xcodeproj" \
        -scheme SnipSnap \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$archive_path" \
        ARCHS='arm64 x86_64' \
        CODE_SIGN_IDENTITY="$signing_identity" \
        CODE_SIGN_STYLE=Manual \
        CURRENT_PROJECT_VERSION="$build_number" \
        DEVELOPMENT_TEAM="$development_team" \
        MARKETING_VERSION="$version" \
        PROVISIONING_PROFILE_SPECIFIER="$provisioning_profile_specifier" \
        CODE_SIGN_ENTITLEMENTS="$mac_release_entitlements" \
        SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER="$cloudkit_container_identifier" \
        archive

    signing_policy_write_export_options \
        "$export_options" "$development_team" \
        "$product_bundle_identifier" "$provisioning_profile_specifier"

    /usr/bin/xcodebuild \
        -exportArchive \
        -archivePath "$archive_path" \
        -exportPath "$export_path" \
        -exportOptionsPlist "$export_options"

    [[ -d "$app_path" ]] || fail "Xcode did not export Snip Snap.app"
    release_policy_verify_app "$app_path"
    verify_release_cloudkit

    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
    /bin/mkdir -p "$dmg_source"
    /usr/bin/ditto "$app_path" "$dmg_source/Snip Snap.app"
    /bin/ln -s /Applications "$dmg_source/Applications"
    /usr/bin/hdiutil create \
        -volname "Snip Snap" \
        -srcfolder "$dmg_source" \
        -format UDZO \
        "$submission_dmg"
    /usr/bin/codesign \
        --sign "$signing_identity" \
        --timestamp \
        "$submission_dmg"
    /usr/bin/codesign --verify --verbose=2 "$submission_dmg"
    /usr/bin/hdiutil verify "$submission_dmg"

    /usr/bin/xcrun notarytool submit "$submission_dmg" \
        --keychain-profile "$notary_profile" \
        "${notary_keychain_args[@]}" \
        --wait
fi

[[ -d "$app_path" ]] || fail "Xcode did not export Snip Snap.app"
release_policy_verify_app "$app_path"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/usr/bin/codesign --verify --verbose=2 "$submission_dmg"
/usr/bin/hdiutil verify "$submission_dmg"

if ! /usr/bin/xcrun stapler validate "$submission_dmg" >/dev/null 2>&1; then
    /usr/bin/xcrun stapler staple "$submission_dmg"
fi
/usr/bin/xcrun stapler validate "$submission_dmg"
if ! /usr/bin/xcrun stapler validate "$app_path" >/dev/null 2>&1; then
    /usr/bin/xcrun stapler staple "$app_path"
fi
/usr/bin/xcrun stapler validate "$app_path"
/bin/cp -p "$submission_dmg" "$release_dmg"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_zip"

/usr/bin/hdiutil verify "$release_dmg"
/usr/sbin/spctl --assess --type open \
    --context context:primary-signature \
    --verbose=2 \
    "$release_dmg"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
/usr/bin/shasum -a 256 "$release_dmg" | /usr/bin/tee "$release_dmg.sha256"
/usr/bin/shasum -a 256 "$release_zip" | /usr/bin/tee "$release_zip.sha256"
release_policy_verify_checksum "$release_dmg" "$release_dmg.sha256"
release_policy_verify_checksum "$release_zip" "$release_zip.sha256"

print "Website release: $release_dmg"
print "Website checksum: $release_dmg.sha256"
print "Update release: $release_zip"
print "Update checksum: $release_zip.sha256"
