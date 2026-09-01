#!/bin/zsh
set -euo pipefail

action="${1:-}"
lane="${2:-}"
ci_root="${SNIP_SNAP_CI_ROOT:-}"
repo_dir="${SNIP_SNAP_REPO_DIR:-${0:A:h:h}}"
keychain="$ci_root/release.keychain-db"
keychain_password_file="$ci_root/keychain-password"
profile_record="$ci_root/profile-path"
repo_secret_record="$ci_root/repo-secret-paths"
local_xcconfig="$repo_dir/Config/Local.xcconfig"
testflight_entitlements="$repo_dir/Config/TestFlight.entitlements"
mac_release_entitlements="$repo_dir/Config/MacRelease.entitlements"
security_tool="${SNIP_SNAP_SECURITY_TOOL:-/usr/bin/security}"

fail() {
    print -u2 "CI Apple setup: $1"
    exit 1
}

safe_root() {
    [[ -n "$ci_root" && "${ci_root:t}" == snip-snap-release-* ]] || return 1
    if [[ -n "${RUNNER_TEMP:-}" ]]; then
        [[ "$ci_root" == "$RUNNER_TEMP"/snip-snap-release-* ]]
    else
        [[ "$ci_root" == /private/tmp/snip-snap-release-* ||
           "$ci_root" == /private/tmp/*/snip-snap-release-* ]]
    fi
}

write_secret() {
    local value="$1"
    local path="$2"
    [[ -n "$value" ]] || fail "a required protected value is missing"
    print -rn -- "$value" > "$path"
    /bin/chmod 600 "$path"
}

import_certificate() {
    local encoded_certificate="$1"
    local certificate_password="$2"
    local certificate_path="$3"

    print -rn -- "$encoded_certificate" | /usr/bin/base64 -D > "$certificate_path"
    /bin/chmod 600 "$certificate_path"
    "$security_tool" import "$certificate_path" \
        -k "$keychain" \
        -P "$certificate_password" \
        -T /usr/bin/codesign \
        -T /usr/bin/security
}

case "$action" in
    setup)
        safe_root || fail "SNIP_SNAP_CI_ROOT must end in snip-snap-release-*"
        [[ "$lane" == mac || "$lane" == ios ]] || fail "setup needs the mac or ios lane"
        [[ -n "${SNIP_SNAP_CI_CERTIFICATE_BASE64:-}" ]] || \
            fail "signing certificate is missing"
        [[ -n "${SNIP_SNAP_CI_CERTIFICATE_PASSWORD:-}" ]] || \
            fail "signing certificate password is missing"
        if [[ "$lane" == ios ]]; then
            [[ -n "${SNIP_SNAP_CI_DEVELOPMENT_CERTIFICATE_BASE64:-}" ]] || \
                fail "development signing certificate is missing"
            [[ -n "${SNIP_SNAP_CI_DEVELOPMENT_CERTIFICATE_PASSWORD:-}" ]] || \
                fail "development signing certificate password is missing"
        fi
        /bin/mkdir -p "$ci_root"
        lane_entitlements="$testflight_entitlements"
        [[ "$lane" == ios ]] || lane_entitlements="$mac_release_entitlements"
        for protected_path in "$local_xcconfig" "$lane_entitlements"; do
            [[ ! -e "$protected_path" ]] || \
                fail "refusing to replace existing ignored file $protected_path"
        done
        /usr/bin/printf '%s\n' \
            "$local_xcconfig" \
            "$lane_entitlements" > "$repo_secret_record"
        write_secret "${SNIP_SNAP_CI_LOCAL_XCCONFIG:-}" "$local_xcconfig"
        if [[ "$lane" == mac ]]; then
            write_secret "${SNIP_SNAP_CI_MAC_RELEASE_ENTITLEMENTS:-}" \
                "$mac_release_entitlements"
        else
            write_secret "${SNIP_SNAP_CI_TESTFLIGHT_ENTITLEMENTS:-}" \
                "$testflight_entitlements"
        fi
        write_secret "${SNIP_SNAP_CI_APPLE_API_PRIVATE_KEY:-}" "$ci_root/AuthKey.p8"
        [[ -n "${SHOWROOM_APPLE_KEY_ID:-}" ]] || fail "Apple key ID is missing"
        [[ -n "${SHOWROOM_APPLE_ISSUER_ID:-}" ]] || fail "Apple issuer ID is missing"

        /usr/bin/uuidgen > "$keychain_password_file"
        keychain_password="$(<"$keychain_password_file")"
        "$security_tool" create-keychain -p "$keychain_password" "$keychain"
        "$security_tool" set-keychain-settings -lut 21600 "$keychain"
        "$security_tool" unlock-keychain -p "$keychain_password" "$keychain"
        import_certificate \
            "${SNIP_SNAP_CI_CERTIFICATE_BASE64:-}" \
            "${SNIP_SNAP_CI_CERTIFICATE_PASSWORD:-}" \
            "$ci_root/signing.p12"
        if [[ "$lane" == ios ]]; then
            import_certificate \
                "${SNIP_SNAP_CI_DEVELOPMENT_CERTIFICATE_BASE64:-}" \
                "${SNIP_SNAP_CI_DEVELOPMENT_CERTIFICATE_PASSWORD:-}" \
                "$ci_root/development-signing.p12"
        fi
        "$security_tool" set-key-partition-list \
            -S apple-tool:,apple:,codesign: \
            -s -k "$keychain_password" "$keychain" >/dev/null
        "$security_tool" list-keychains -d user -s "$keychain"

        if [[ "$lane" == mac ]]; then
            [[ -n "${SNIP_SNAP_CI_MAC_PROFILE_BASE64:-}" ]] || fail "Mac profile is missing"
            print -n "$SNIP_SNAP_CI_MAC_PROFILE_BASE64" | \
                /usr/bin/base64 -D > "$ci_root/mac.provisionprofile"
            profile_plist="$ci_root/mac-profile.plist"
            "$security_tool" cms -D -i "$ci_root/mac.provisionprofile" > "$profile_plist"
            profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$profile_plist")"
            [[ -n "$profile_uuid" ]] || fail "Mac profile has no UUID"
            profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
            /bin/mkdir -p "$profile_dir"
            installed_profile="$profile_dir/$profile_uuid.provisionprofile"
            /bin/cp "$ci_root/mac.provisionprofile" "$installed_profile"
            print -r -- "$installed_profile" > "$profile_record"

            /usr/bin/xcrun notarytool store-credentials snip-snap-ci \
                --key "$ci_root/AuthKey.p8" \
                --key-id "$SHOWROOM_APPLE_KEY_ID" \
                --issuer "$SHOWROOM_APPLE_ISSUER_ID" \
                --keychain "$keychain"
        fi
        ;;
    cleanup)
        safe_root || exit 0
        if [[ -f "$repo_secret_record" ]]; then
            while IFS= read -r protected_path; do
                case "$protected_path" in
                    "$local_xcconfig"|"$testflight_entitlements"|"$mac_release_entitlements")
                        /bin/rm -f "$protected_path"
                        ;;
                esac
            done < "$repo_secret_record"
        fi
        if [[ -f "$profile_record" ]]; then
            installed_profile="$(<"$profile_record")"
            [[ "$installed_profile" == "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile ]] && \
                /bin/rm -f "$installed_profile"
        fi
        [[ ! -f "$keychain" ]] || "$security_tool" delete-keychain "$keychain" || true
        /bin/rm -rf "$ci_root"
        ;;
    *)
        print -u2 "Usage: $0 setup mac|ios | cleanup"
        exit 2
        ;;
esac
