#!/bin/zsh

script_dir="${0:A:h}"
source "$script_dir/signing-policy.sh"

testflight_policy_fail() {
    print -u2 "TestFlight: $1"
    return 1
}

testflight_policy_write_export_options() {
    local output_file="$1"
    local development_team="$2"

    [[ -n "$development_team" ]] || {
        testflight_policy_fail "DEVELOPMENT_TEAM is missing"
        return 1
    }

    /usr/bin/plutil -create xml1 "$output_file"
    /usr/bin/plutil -insert destination -string upload "$output_file"
    /usr/bin/plutil -insert iCloudContainerEnvironment -string Production "$output_file"
    /usr/bin/plutil -insert manageAppVersionAndBuildNumber -bool NO "$output_file"
    /usr/bin/plutil -insert method -string app-store-connect "$output_file"
    /usr/bin/plutil -insert signingStyle -string automatic "$output_file"
    /usr/bin/plutil -insert stripSwiftSymbols -bool YES "$output_file"
    /usr/bin/plutil -insert teamID -string "$development_team" "$output_file"
    /usr/bin/plutil -insert testFlightInternalTestingOnly -bool NO "$output_file"
    /usr/bin/plutil -insert uploadSymbols -bool YES "$output_file"
}

testflight_policy_plist_value() {
    local file="$1"
    local key="$2"
    /usr/bin/plutil -extract "$key" raw -o - "$file" 2>/dev/null
}

testflight_policy_manifest_has_reason() {
    local manifest="$1"
    local category="$2"
    local reason="$3"
    local type_count
    local reason_count
    local type_index
    local reason_index
    local found_category
    local found_reason

    type_count="$(/usr/bin/plutil -extract NSPrivacyAccessedAPITypes raw -o - \
        "$manifest" 2>/dev/null)" || return 1
    [[ "$type_count" == <-> ]] || return 1
    for (( type_index = 0; type_index < type_count; type_index++ )); do
        found_category="$(/usr/bin/plutil -extract \
            "NSPrivacyAccessedAPITypes.$type_index.NSPrivacyAccessedAPIType" \
            raw -o - "$manifest" 2>/dev/null)" || continue
        [[ "$found_category" == "$category" ]] || continue
        reason_count="$(/usr/bin/plutil -extract \
            "NSPrivacyAccessedAPITypes.$type_index.NSPrivacyAccessedAPITypeReasons" \
            raw -o - "$manifest" 2>/dev/null)" || return 1
        [[ "$reason_count" == <-> ]] || return 1
        for (( reason_index = 0; reason_index < reason_count; reason_index++ )); do
            found_reason="$(/usr/bin/plutil -extract \
                "NSPrivacyAccessedAPITypes.$type_index.NSPrivacyAccessedAPITypeReasons.$reason_index" \
                raw -o - "$manifest" 2>/dev/null)" || continue
            [[ "$found_reason" == "$reason" ]] && return 0
        done
    done
    return 1
}

testflight_policy_write_source_record() {
    local output_file="$1"
    local source_revision="$2"
    local source_is_clean="$3"

    [[ -n "$source_revision" ]] || {
        testflight_policy_fail "source revision is missing"
        return 1
    }
    /usr/bin/plutil -create xml1 "$output_file"
    /usr/bin/plutil -insert sourceRevision -string "$source_revision" "$output_file"
    /usr/bin/plutil -insert sourceIsClean -bool "$source_is_clean" "$output_file"
}

testflight_policy_require_unchanged_source() {
    local starting_revision="$1"
    local starting_state="$2"
    local ending_revision="$3"
    local ending_state="$4"

    [[ "$starting_revision" == "$ending_revision" && \
       "$starting_state" == "$ending_state" ]] || {
        testflight_policy_fail "source changed while the archive was being built"
        return 1
    }
}

testflight_policy_verify_source_record() {
    local archive_path="$1"
    local source_revision="$2"
    local source_record="$archive_path/SnipSnapSource.plist"

    [[ -f "$source_record" ]] || {
        testflight_policy_fail "archive source record is missing"
        return 1
    }
    [[ "$(testflight_policy_plist_value "$source_record" sourceRevision)" == \
        "$source_revision" ]] || {
        testflight_policy_fail "archive does not match the checked source commit"
        return 1
    }
    [[ "$(testflight_policy_plist_value "$source_record" sourceIsClean)" == true ]] || {
        testflight_policy_fail "archive was created from a dirty worktree"
        return 1
    }
}

testflight_policy_verify_archive() {
    local archive_path="$1"
    local app_bundle_identifier="$2"
    local share_bundle_identifier="$3"
    local development_team="$4"
    local app_group_identifier="$5"
    local cloudkit_container_identifier="$6"
    local version="$7"
    local build_number="$8"
    local codesign_tool="${SNIP_SNAP_CODESIGN:-/usr/bin/codesign}"
    local app_path="$archive_path/Products/Applications/Snip Snap iOS.app"
    local share_path="$app_path/PlugIns/SnipSnapShareExtension.appex"
    local app_info="$app_path/Info.plist"
    local share_info="$share_path/Info.plist"
    local temp_root=""
    local app_entitlements=""
    local share_entitlements=""
    local -a missing

    [[ -d "$archive_path" ]] || missing+=("archive")
    [[ -d "$app_path" ]] || missing+=("iOS app")
    [[ -d "$share_path" ]] || missing+=("embedded Share extension")
    [[ -f "$app_info" ]] || missing+=("app Info.plist")
    [[ -f "$share_info" ]] || missing+=("Share extension Info.plist")
    [[ -f "$app_path/PrivacyInfo.xcprivacy" ]] || missing+=("app privacy manifest")
    [[ -f "$share_path/PrivacyInfo.xcprivacy" ]] || \
        missing+=("Share extension privacy manifest")
    if [[ ! -d "$archive_path/dSYMs" ]] || \
       ! /usr/bin/find "$archive_path/dSYMs" -maxdepth 1 -name '*.app.dSYM' -print -quit | \
            /usr/bin/grep -q .; then
        missing+=("app dSYM")
    fi

    if (( ${#missing} )); then
        print -u2 "TestFlight archive is not ready."
        for item in "${missing[@]}"; do
            print -u2 -- "- $item"
        done
        return 1
    fi

    /usr/bin/plutil -lint "$app_path/PrivacyInfo.xcprivacy" >/dev/null 2>&1 || \
        missing+=("valid app privacy manifest")
    /usr/bin/plutil -lint "$share_path/PrivacyInfo.xcprivacy" >/dev/null 2>&1 || \
        missing+=("valid Share extension privacy manifest")
    testflight_policy_manifest_has_reason \
        "$app_path/PrivacyInfo.xcprivacy" NSPrivacyAccessedAPICategoryUserDefaults CA92.1 || \
        missing+=("app UserDefaults privacy reason")
    for reason in C617.1 3B52.1; do
        testflight_policy_manifest_has_reason \
            "$app_path/PrivacyInfo.xcprivacy" \
            NSPrivacyAccessedAPICategoryFileTimestamp "$reason" || \
            missing+=("app FileTimestamp privacy reason $reason")
    done
    for reason in 1C8F.1 CA92.1; do
        testflight_policy_manifest_has_reason \
            "$share_path/PrivacyInfo.xcprivacy" \
            NSPrivacyAccessedAPICategoryUserDefaults "$reason" || \
            missing+=("Share extension UserDefaults privacy reason $reason")
    done
    testflight_policy_manifest_has_reason \
        "$share_path/PrivacyInfo.xcprivacy" \
        NSPrivacyAccessedAPICategoryFileTimestamp C617.1 || \
        missing+=("Share extension FileTimestamp privacy reason")

    "$codesign_tool" --verify --deep --strict "$app_path" >/dev/null 2>&1 || {
        testflight_policy_fail "app signature verification failed"
        return 1
    }
    "$codesign_tool" --verify --strict "$share_path" >/dev/null 2>&1 || {
        testflight_policy_fail "Share extension signature verification failed"
        return 1
    }

    temp_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-testflight-policy.XXXXXX)"
    app_entitlements="$temp_root/app-entitlements.plist"
    share_entitlements="$temp_root/share-entitlements.plist"
    if ! "$codesign_tool" -d --entitlements :- "$app_path" \
        > "$app_entitlements" 2>/dev/null; then
        /bin/rm -rf "$temp_root"
        testflight_policy_fail "could not inspect app entitlements"
        return 1
    fi
    if ! "$codesign_tool" -d --entitlements :- "$share_path" \
        > "$share_entitlements" 2>/dev/null; then
        /bin/rm -rf "$temp_root"
        testflight_policy_fail "could not inspect Share extension entitlements"
        return 1
    fi

    /usr/bin/plutil -lint "$app_entitlements" >/dev/null 2>&1 || \
        missing+=("valid signed app entitlements")
    /usr/bin/plutil -lint "$share_entitlements" >/dev/null 2>&1 || \
        missing+=("valid signed Share extension entitlements")

    [[ "$(testflight_policy_plist_value "$app_info" CFBundleIdentifier)" == \
        "$app_bundle_identifier" ]] || missing+=("app bundle ID")
    [[ "$(testflight_policy_plist_value \
        "$app_info" ITSAppUsesNonExemptEncryption)" == false ]] || \
        missing+=("app export compliance declaration")
    [[ "$(testflight_policy_plist_value "$share_info" CFBundleIdentifier)" == \
        "$share_bundle_identifier" ]] || missing+=("Share extension bundle ID")
    for info in "$app_info" "$share_info"; do
        [[ "$(testflight_policy_plist_value "$info" CFBundleShortVersionString)" == \
            "$version" ]] || missing+=("bundle version")
        [[ "$(testflight_policy_plist_value "$info" CFBundleVersion)" == \
            "$build_number" ]] || missing+=("bundle build number")
    done

    signing_policy_plist_array_contains \
        "$app_entitlements" com.apple.security.application-groups \
        "$app_group_identifier" || missing+=("signed app App Group")
    signing_policy_plist_array_contains \
        "$share_entitlements" com.apple.security.application-groups \
        "$app_group_identifier" || missing+=("signed Share extension App Group")
    signing_policy_plist_array_contains \
        "$app_entitlements" com.apple.developer.icloud-container-identifiers \
        "$cloudkit_container_identifier" || missing+=("signed CloudKit container")
    signing_policy_plist_array_contains \
        "$app_entitlements" com.apple.developer.icloud-services CloudKit || \
        missing+=("signed CloudKit service")
    signing_policy_plist_value_equals \
        "$app_entitlements" com.apple.developer.icloud-container-environment Production || \
        missing+=("signed CloudKit Production environment")
    signing_policy_plist_value_equals \
        "$app_entitlements" com.apple.developer.team-identifier "$development_team" || \
        missing+=("signed app team")
    signing_policy_plist_value_equals \
        "$share_entitlements" com.apple.developer.team-identifier "$development_team" || \
        missing+=("signed Share extension team")
    [[ "$(testflight_policy_plist_value \
        "$app_entitlements" application-identifier)" == *".$app_bundle_identifier" ]] || \
        missing+=("signed app identifier")
    [[ "$(testflight_policy_plist_value \
        "$share_entitlements" application-identifier)" == *".$share_bundle_identifier" ]] || \
        missing+=("signed Share extension identifier")

    if signing_policy_plist_has_key \
        "$share_entitlements" com.apple.developer.icloud-container-identifiers || \
       signing_policy_plist_has_key \
        "$share_entitlements" com.apple.developer.icloud-services || \
       signing_policy_plist_has_key \
        "$share_entitlements" com.apple.developer.icloud-container-environment; then
        missing+=("Share extension without CloudKit")
    fi
    /bin/rm -rf "$temp_root"
    if (( ${#missing} )); then
        print -u2 "TestFlight archive is not ready."
        for item in "${missing[@]}"; do
            print -u2 -- "- $item"
        done
        return 1
    fi

    print "TestFlight archive checks passed."
}
