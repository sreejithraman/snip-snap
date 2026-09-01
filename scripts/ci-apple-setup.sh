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

case "$action" in
    setup)
        safe_root || fail "SNIP_SNAP_CI_ROOT must end in snip-snap-release-*"
        [[ "$lane" == mac || "$lane" == ios ]] || fail "setup needs the mac or ios lane"
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
        [[ -n "${SNIP_SNAP_CI_CERTIFICATE_BASE64:-}" ]] || fail "certificate is missing"
        [[ -n "${SNIP_SNAP_CI_CERTIFICATE_PASSWORD:-}" ]] || fail "certificate password is missing"
        [[ -n "${SHOWROOM_APPLE_KEY_ID:-}" ]] || fail "Apple key ID is missing"
        [[ -n "${SHOWROOM_APPLE_ISSUER_ID:-}" ]] || fail "Apple issuer ID is missing"

        print -n "$SNIP_SNAP_CI_CERTIFICATE_BASE64" | /usr/bin/base64 -D > "$ci_root/signing.p12"
        /usr/bin/uuidgen > "$keychain_password_file"
        keychain_password="$(<"$keychain_password_file")"
        /usr/bin/security create-keychain -p "$keychain_password" "$keychain"
        /usr/bin/security set-keychain-settings -lut 21600 "$keychain"
        /usr/bin/security unlock-keychain -p "$keychain_password" "$keychain"
        /usr/bin/security import "$ci_root/signing.p12" \
            -k "$keychain" \
            -P "$SNIP_SNAP_CI_CERTIFICATE_PASSWORD" \
            -T /usr/bin/codesign \
            -T /usr/bin/security
        /usr/bin/security set-key-partition-list \
            -S apple-tool:,apple:,codesign: \
            -s -k "$keychain_password" "$keychain" >/dev/null
        /usr/bin/security list-keychains -d user -s "$keychain"

        if [[ "$lane" == mac ]]; then
            [[ -n "${SNIP_SNAP_CI_MAC_PROFILE_BASE64:-}" ]] || fail "Mac profile is missing"
            print -n "$SNIP_SNAP_CI_MAC_PROFILE_BASE64" | \
                /usr/bin/base64 -D > "$ci_root/mac.provisionprofile"
            profile_plist="$ci_root/mac-profile.plist"
            /usr/bin/security cms -D -i "$ci_root/mac.provisionprofile" > "$profile_plist"
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
        [[ ! -f "$keychain" ]] || /usr/bin/security delete-keychain "$keychain" || true
        /bin/rm -rf "$ci_root"
        ;;
    *)
        print -u2 "Usage: $0 setup mac|ios | cleanup"
        exit 2
        ;;
esac
