#!/bin/zsh

signing_policy_fail() {
    print -u2 "signed-lane preflight: $1"
    return 1
}

signing_policy_resign_exported_mac_app() {
    local archive_app="$1"
    local exported_app="$2"
    local signing_identity="$3"
    local entitlements_path="$4"

    # Xcode expands build settings in the archive's signed entitlements.
    # codesign would preserve a literal $(...) from the source template.
    /usr/bin/codesign -d --entitlements :- "$archive_app" \
        > "$entitlements_path" 2>/dev/null || {
        signing_policy_fail "could not read archived Mac app entitlements"
        return 1
    }
    /usr/bin/plutil -lint "$entitlements_path" >/dev/null 2>&1 || {
        signing_policy_fail "archived Mac app entitlements are invalid"
        return 1
    }
    /usr/bin/codesign \
        --force \
        --sign "$signing_identity" \
        --options runtime \
        --entitlements "$entitlements_path" \
        --timestamp \
        --generate-entitlement-der \
        "$exported_app"
}

signing_policy_resolve_setting() {
    local settings_file="$1"
    local setting_name="$2"
    local target_name="${3:-}"
    local value

    if [[ -n "$target_name" ]] && ! /usr/bin/grep -Eq \
        '^Build settings for action .* and target .*:$' "$settings_file"; then
        target_name=""
    fi

    value="$(/usr/bin/awk -v wanted="$setting_name" -v target="$target_name" '
        BEGIN { in_target = (target == "") }
        /^Build settings for action .* and target .*:$/ {
            in_target = (target == "" || $0 == "Build settings for action build and target " target ":")
            next
        }
        !in_target { next }
        {
            separator = index($0, " = ")
            if (separator == 0) {
                next
            }
            name = substr($0, 1, separator - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name == wanted) {
                value = substr($0, separator + 3)
            }
        }
        END {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }
    ' "$settings_file")"
    [[ "$value" == *'$('* ]] && value=""
    print -r -- "$value"
}

signing_policy_capture_build_settings() {
    local repo_dir="$1"
    local configuration="$2"
    local destination="$3"
    local output_file="$4"
    local derived_data="${5:-}"
    local scheme="${6:-SnipSnap}"
    local xcodebuild_tool="${SNIP_SNAP_XCODEBUILD:-xcodebuild}"
    local -a shared_arguments
    local command=(
        "$xcodebuild_tool"
        -project "$repo_dir/SnipSnap.xcodeproj"
        -scheme "$scheme"
        -configuration "$configuration"
        -destination "$destination"
        -showBuildSettings
    )
    local share_command

    [[ -z "$derived_data" ]] || command+=( -derivedDataPath "$derived_data" )

    shared_arguments=()
    [[ -z "${SNIP_SNAP_DEVELOPMENT_TEAM:-}" ]] || \
        shared_arguments+=("DEVELOPMENT_TEAM=$SNIP_SNAP_DEVELOPMENT_TEAM")
    [[ -z "${SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER:-}" ]] || \
        shared_arguments+=("SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=$SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER")
    [[ -z "${SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER:-}" ]] || \
        shared_arguments+=("SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER=$SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER")
    [[ -z "${SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER:-}" ]] || \
        shared_arguments+=("SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER=$SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER")
    [[ -z "${SNIP_SNAP_APP_GROUP_IDENTIFIER:-}" ]] || \
        shared_arguments+=("SNIP_SNAP_APP_GROUP_IDENTIFIER=$SNIP_SNAP_APP_GROUP_IDENTIFIER")
    [[ -z "${SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER:-}" ]] || \
        shared_arguments+=("SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER=$SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER")
    [[ -z "${SNIP_SNAP_CODE_SIGN_ENTITLEMENTS:-}" ]] || \
        command+=("CODE_SIGN_ENTITLEMENTS=$SNIP_SNAP_CODE_SIGN_ENTITLEMENTS")
    [[ -z "${SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS:-}" ]] || \
        shared_arguments+=("SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS=$SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS")
    command+=("${shared_arguments[@]}")

    "${command[@]}" > "$output_file" 2> "$output_file.stderr" || {
        /bin/rm -f "$output_file.stderr"
        signing_policy_fail "could not resolve Xcode build settings"
        return 1
    }
    if [[ "$scheme" == SnipSnapiOS ]]; then
        share_command=(
            "$xcodebuild_tool"
            -project "$repo_dir/SnipSnap.xcodeproj"
            -target SnipSnapShareExtension
            -configuration "$configuration"
            -destination "$destination"
            -showBuildSettings
        )
        # Xcode rejects -derivedDataPath when build settings use -target.
        share_command+=("${shared_arguments[@]}")
        "${share_command[@]}" >> "$output_file" 2>> "$output_file.stderr" || {
            /bin/rm -f "$output_file.stderr"
            signing_policy_fail "could not resolve Share extension build settings"
            return 1
        }
    fi
    /bin/rm -f "$output_file.stderr"
}

signing_policy_entitlement_path() {
    local repo_dir="$1"
    local setting="$2"
    local path="$setting"

    path="${path//\$\(SRCROOT\)/$repo_dir}"
    path="${path//\$\(PROJECT_DIR\)/$repo_dir}"
    [[ "$path" == /* ]] || path="$repo_dir/$path"
    print -r -- "$path"
}

signing_policy_plist_array_contains() {
    local file="$1"
    local key="$2"
    local wanted="$3"
    local allowed_placeholder="${4:-}"
    local escaped_key="${key//./\\.}"
    local count
    local index
    local value

    count="$(/usr/bin/plutil -extract "$escaped_key" raw -o - "$file" 2>/dev/null)" || \
        return 1
    [[ "$count" == <-> ]] || return 1
    for (( index = 0; index < count; index++ )); do
        value="$(/usr/bin/plutil -extract "$escaped_key.$index" raw -o - "$file" 2>/dev/null)" || \
            continue
        [[ "$value" == "$wanted" || \
           ( -n "$allowed_placeholder" && "$value" == "$allowed_placeholder" ) ]] && \
            return 0
    done
    return 1
}

signing_policy_profile_allows_cloudkit() {
    local file="$1"
    local key='com.apple.developer.icloud-services'
    local escaped_key="${key//./\\.}"
    local value

    value="$(/usr/bin/plutil -extract "$escaped_key" raw -o - "$file" 2>/dev/null)" || \
        return 1
    [[ "$value" == '*' ]] || \
        signing_policy_plist_array_contains "$file" "$key" CloudKit
}

signing_policy_plist_has_key() {
    local file="$1"
    local key="$2"
    local escaped_key="${key//./\\.}"
    /usr/bin/plutil -extract "$escaped_key" raw -o - "$file" >/dev/null 2>&1
}

signing_policy_plist_value_equals() {
    local file="$1"
    local key="$2"
    local wanted="$3"
    local escaped_key="${key//./\\.}"
    local value

    value="$(/usr/bin/plutil -extract "$escaped_key" raw -o - "$file" 2>/dev/null)" || \
        return 1
    [[ "$value" == "$wanted" ]]
}

signing_policy_preflight() {
    local lane="$1"
    local settings_file="$2"
    local repo_dir="$3"
    local scheme="${4:-SnipSnap}"
    local setting
    local value
    local app_group_identifier=""
    local cloudkit_container_identifier=""
    local entitlement_setting=""
    local entitlement_path=""
    local -a required_settings
    local -a required_environment
    local -a missing

    [[ -f "$settings_file" ]] || {
        signing_policy_fail "missing resolved build settings"
        return 1
    }

    case "$lane" in
        cloud|device|testflight)
            required_settings=(
                DEVELOPMENT_TEAM
                PRODUCT_BUNDLE_IDENTIFIER
                SNIP_SNAP_APP_GROUP_IDENTIFIER
                SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER
                CODE_SIGN_ENTITLEMENTS
            )
            required_environment=()
            ;;
        release)
            required_settings=(
                DEVELOPMENT_TEAM
                PRODUCT_BUNDLE_IDENTIFIER
                SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER
                CODE_SIGN_ENTITLEMENTS
            )
            required_environment=(
                SNIP_SNAP_SIGNING_IDENTITY
                SNIP_SNAP_NOTARY_PROFILE
                SNIP_SNAP_MAC_PROVISIONING_PROFILE_SPECIFIER
            )
            ;;
        *)
            signing_policy_fail "unknown lane $lane"
            return 1
            ;;
    esac

    for setting in "${required_settings[@]}"; do
        value="$(signing_policy_resolve_setting "$settings_file" "$setting" "$scheme")"
        if [[ -z "$value" ]]; then
            missing+=("$setting")
        elif [[ "$setting" == CODE_SIGN_ENTITLEMENTS ]]; then
            entitlement_setting="$value"
        elif [[ "$setting" == SNIP_SNAP_APP_GROUP_IDENTIFIER ]]; then
            app_group_identifier="$value"
        elif [[ "$setting" == SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER ]]; then
            cloudkit_container_identifier="$value"
        fi
    done

    for setting in "${required_environment[@]}"; do
        [[ -n "${(P)setting:-}" ]] || missing+=("$setting")
    done

    if [[ -n "$entitlement_setting" ]]; then
        entitlement_path="$(signing_policy_entitlement_path \
            "$repo_dir" "$entitlement_setting")"
        if [[ ! -f "$entitlement_path" ]]; then
            missing+=("CODE_SIGN_ENTITLEMENTS file")
        elif ! /usr/bin/plutil -lint "$entitlement_path" >/dev/null 2>&1; then
            missing+=("valid entitlement plist")
        else
            if [[ "$lane" != release ]]; then
                signing_policy_plist_array_contains \
                    "$entitlement_path" com.apple.security.application-groups \
                    "$app_group_identifier" '$(SNIP_SNAP_APP_GROUP_IDENTIFIER)' || \
                    missing+=("App Group entitlement")
            fi
            signing_policy_plist_array_contains \
                "$entitlement_path" com.apple.developer.icloud-container-identifiers \
                "$cloudkit_container_identifier" \
                '$(SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER)' || \
                missing+=("CloudKit container entitlement")
            signing_policy_plist_array_contains \
                "$entitlement_path" com.apple.developer.icloud-services CloudKit || \
                missing+=("CloudKit service entitlement")
            if [[ "$lane" == cloud ]]; then
                signing_policy_plist_value_equals \
                    "$entitlement_path" \
                    com.apple.developer.icloud-container-environment \
                    Development || missing+=("CloudKit Development environment entitlement")
            elif [[ "$lane" == testflight || "$lane" == release ]]; then
                signing_policy_plist_value_equals \
                    "$entitlement_path" \
                    com.apple.developer.icloud-container-environment \
                    Production || missing+=("CloudKit Production environment entitlement")
            fi
            if [[ "$scheme" == SnipSnapiOS ]]; then
                local expected_push_environment=development
                [[ "$lane" == testflight ]] && expected_push_environment=production
                signing_policy_plist_value_equals \
                    "$entitlement_path" aps-environment \
                    "$expected_push_environment" || \
                    missing+=("Apple Push Notification environment entitlement")
            elif [[ "$scheme" == SnipSnap ]]; then
                local expected_push_environment=development
                [[ "$lane" == release ]] && expected_push_environment=production
                signing_policy_plist_value_equals \
                    "$entitlement_path" com.apple.developer.aps-environment \
                    "$expected_push_environment" || \
                    missing+=("Apple Push Notification environment entitlement")
            fi
        fi
    fi

    if [[ ( "$lane" == cloud || "$lane" == device || "$lane" == testflight ) && \
          "$scheme" == SnipSnapiOS ]]; then
        local share_app_group_identifier=""
        local share_entitlement_setting=""
        local share_entitlements=""
        share_app_group_identifier="$(signing_policy_resolve_setting \
            "$settings_file" SNIP_SNAP_APP_GROUP_IDENTIFIER SnipSnapShareExtension)"
        share_entitlement_setting="$(signing_policy_resolve_setting \
            "$settings_file" CODE_SIGN_ENTITLEMENTS SnipSnapShareExtension)"
        if /usr/bin/grep -Eq \
            '^Build settings for action .* and target .*:$' "$settings_file"; then
            if [[ -z "$share_app_group_identifier" || \
                  "$share_app_group_identifier" != "$app_group_identifier" ]]; then
                missing+=("Share extension App Group build setting")
            fi
            if [[ -z "$share_entitlement_setting" ]]; then
                missing+=("Share extension CODE_SIGN_ENTITLEMENTS")
            else
                share_entitlements="$(signing_policy_entitlement_path \
                    "$repo_dir" "$share_entitlement_setting")"
            fi
        else
            share_app_group_identifier="$app_group_identifier"
            share_entitlements="$repo_dir/SnipSnapShareExtension/SnipSnapShareExtension.entitlements"
        fi
        if [[ -z "$share_entitlements" ]]; then
            :
        elif [[ ! -f "$share_entitlements" ]] || \
           ! /usr/bin/plutil -lint "$share_entitlements" >/dev/null 2>&1; then
            missing+=("valid Share extension entitlement plist")
        else
            signing_policy_plist_array_contains \
                "$share_entitlements" com.apple.security.application-groups \
                "$share_app_group_identifier" '$(SNIP_SNAP_APP_GROUP_IDENTIFIER)' || \
                missing+=("Share extension App Group entitlement")
            if signing_policy_plist_has_key \
                "$share_entitlements" com.apple.developer.icloud-container-identifiers || \
               signing_policy_plist_has_key \
                "$share_entitlements" com.apple.developer.icloud-services; then
                missing+=("Share extension must keep App Group-only cloud access")
            fi
        fi
    fi

    if (( ${#missing} )); then
        print -u2 "Signed lane: $lane (not ready)."
        print -u2 "Missing required inputs:"
        for setting in "${missing[@]}"; do
            print -u2 -- "- $setting"
        done
        return 1
    fi

    print "Signed lane: $lane (ready)."
}

signing_policy_verify_cloud_dev_profile() {
    local profile_path="$1" signed_entitlements="$2" platform="$3" bundle_id="$4" app_group="$5" container="$6" evidence_prefix="$7" expected_team="${8:-}"
    local security_tool="${SNIP_SNAP_SECURITY:-/usr/bin/security}"
    local identifier_key=application-identifier push_key=aps-environment
    [[ "$platform" != macos ]] || {
        identifier_key=com.apple.application-identifier
        push_key=com.apple.developer.aps-environment
    }
    local profile="$evidence_prefix-profile.plist" grants="$evidence_prefix-profile-entitlements.plist"
    local team signed_identifier profile_identifier expiration prefix count index item
    local identifier_matches=false
    local -a missing
    "$security_tool" cms -D -i "$profile_path" > "$profile" 2>/dev/null || {
        signing_policy_fail "Cloud Dev app needs an embedded Development provisioning profile"; return 1
    }
    /usr/bin/plutil -extract Entitlements xml1 -o "$grants" "$profile" >/dev/null 2>&1 || {
        signing_policy_fail "Cloud Dev provisioning profile has no valid entitlements"; return 1
    }
    team="$(/usr/bin/plutil -extract 'com\.apple\.developer\.team-identifier' raw -o - "$signed_entitlements" 2>/dev/null)" || missing+=("signed team identifier")
    [[ -n "$expected_team" && "$team" == "$expected_team" ]] || missing+=("configured signing team")
    signing_policy_plist_array_contains "$profile" TeamIdentifier "$team" || missing+=("profile team identifier")
    signing_policy_plist_value_equals "$grants" com.apple.developer.team-identifier "$team" || missing+=("profile entitlement team identifier")
    signed_identifier="$(/usr/bin/plutil -extract "${identifier_key//./\\.}" raw -o - "$signed_entitlements" 2>/dev/null)" || missing+=("signed application identifier")
    profile_identifier="$(/usr/bin/plutil -extract "${identifier_key//./\\.}" raw -o - "$grants" 2>/dev/null)" || missing+=("profile application identifier")
    count="$(/usr/bin/plutil -extract ApplicationIdentifierPrefix raw -o - "$profile" 2>/dev/null)" || count=""
    if [[ "$count" == <-> ]]; then
        for (( index = 0; index < count; index++ )); do
            prefix="$(/usr/bin/plutil -extract "ApplicationIdentifierPrefix.$index" raw -o - "$profile" 2>/dev/null)" || continue
            [[ "$profile_identifier" != "$prefix.$bundle_id" ]] || identifier_matches=true
        done
    fi
    $identifier_matches || missing+=("profile application prefix and bundle identifier")
    [[ -n "$signed_identifier" && "$signed_identifier" == "$profile_identifier" ]] || missing+=("signed/profile application identity agreement")
    # macOS authorizes team-prefixed groups through the signing team, without registration.
    # Registered group.* identifiers and every iOS group require profile grants.
    if [[ "$platform" == macos && -n "$expected_team" && "$app_group" == "$expected_team."* ]]; then
        : # The checked signing team authorizes this Mac-only identifier.
    elif [[ "$app_group" == group.* ]]; then
        signing_policy_plist_array_contains "$grants" com.apple.security.application-groups "$app_group" || missing+=("profile App Group grant")
    else
        missing+=("supported App Group identifier for this platform and signing team")
    fi
    expiration="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$profile" 2>/dev/null)" || missing+=("profile expiration date")
    if [[ -n "$expiration" ]] && ! /usr/bin/ruby -rtime -e 'exit(Time.parse(ARGV[0]) > Time.now ? 0 : 1)' "$expiration" 2>/dev/null; then
        missing+=("unexpired provisioning profile")
    fi
    if [[ -n "$container" ]]; then
        signing_policy_plist_array_contains "$grants" com.apple.developer.icloud-container-identifiers "$container" || missing+=("profile CloudKit container grant")
        signing_policy_profile_allows_cloudkit "$grants" || missing+=("profile CloudKit service grant")
        signing_policy_plist_value_equals "$grants" com.apple.developer.icloud-container-environment Development || \
            signing_policy_plist_array_contains "$grants" com.apple.developer.icloud-container-environment Development || \
            missing+=("profile Development environment grant")
        signing_policy_plist_value_equals "$grants" "$push_key" development || missing+=("profile development push grant")
    fi
    if (( ${#missing} )); then
        for item in "${missing[@]}"; do print -u2 -- "Cloud Dev provisioning profile: missing $item."; done
        return 1
    fi
}

signing_policy_verify_cloud_dev_signature() {
    local app_path="$1" expected_team="$2" evidence_path="$3"
    local codesign_tool="${SNIP_SNAP_CODESIGN:-/usr/bin/codesign}"
    "$codesign_tool" --verify --deep --strict -R '=anchor apple generic' "$app_path" >/dev/null 2>&1 || {
        signing_policy_fail "Cloud Dev app needs a valid Apple-issued signature"; return 1
    }
    "$codesign_tool" -d --verbose=4 "$app_path" > "$evidence_path" 2>&1 || {
        signing_policy_fail "could not inspect the Cloud Dev signing identity"; return 1
    }
    /usr/bin/awk -v expected_team="$expected_team" '
        /^Authority=Apple Development:/ { development = 1 }
        /^TeamIdentifier=/ { team = substr($0, 16) }
        END { exit !(development && expected_team != "" && team == expected_team) }
    ' "$evidence_path" || {
        signing_policy_fail "Cloud Dev app needs an Apple Development signature from the configured signing team"; return 1
    }
}

signing_policy_verify_cloud_dev_app() {
    local app_path="$1" platform="$2" bundle_id="$3" app_group="$4" container="$5" evidence_dir="$6" store_path="${7:-}" expected_team="${8:-}"
    local codesign_tool="${SNIP_SNAP_CODESIGN:-/usr/bin/codesign}"
    local info_dir="$app_path" profile_name=embedded.mobileprovision push_key=aps-environment
    if [[ "$platform" == macos ]]; then
        info_dir="$app_path/Contents"
        profile_name=embedded.provisionprofile
        push_key=com.apple.developer.aps-environment
    fi
    local signed_entitlements="$evidence_dir/signed-entitlements.plist"
    local item
    local -a missing
    signing_policy_verify_cloud_dev_signature "$app_path" "$expected_team" "$evidence_dir/main-signature.txt" || return 1
    "$codesign_tool" -d --entitlements :- "$app_path" > "$signed_entitlements" 2>/dev/null || {
        signing_policy_fail "could not inspect signed Cloud Dev entitlements"; return 1
    }
    signing_policy_plist_value_equals "$info_dir/Info.plist" CFBundleIdentifier "$bundle_id" || missing+=("app bundle identifier")
    signing_policy_plist_value_equals "$info_dir/Info.plist" SnipSnapCloudKitContainerIdentifier "$container" || missing+=("configured CloudKit container")
    signing_policy_plist_value_equals "$signed_entitlements" com.apple.developer.icloud-container-environment Development || missing+=("signed Development environment")
    signing_policy_plist_value_equals "$signed_entitlements" "$push_key" development || missing+=("signed development push environment")
    signing_policy_plist_array_contains "$signed_entitlements" com.apple.developer.icloud-container-identifiers "$container" || missing+=("signed CloudKit container")
    signing_policy_plist_array_contains "$signed_entitlements" com.apple.developer.icloud-services CloudKit || missing+=("signed CloudKit service")
    signing_policy_plist_array_contains "$signed_entitlements" com.apple.security.application-groups "$app_group" || missing+=("signed App Group")
    if [[ "$platform" == macos ]]; then
        [[ -n "$store_path" && "$store_path" == /* ]] && \
            signing_policy_plist_value_equals "$info_dir/Info.plist" SnipSnapDevelopmentStorePath "$store_path" || missing+=("embedded isolated Mac store path")
    else
        signing_policy_plist_value_equals "$info_dir/Info.plist" SnipSnapAppGroupIdentifier "$app_group" || missing+=("configured App Group")
    fi
    if (( ${#missing} )); then
        for item in "${missing[@]}"; do print -u2 -- "Signed Cloud Dev app: missing $item."; done
        return 1
    fi
    signing_policy_verify_cloud_dev_profile "$info_dir/$profile_name" "$signed_entitlements" "$platform" "$bundle_id" "$app_group" "$container" "$evidence_dir/main" "$expected_team" || return 1
    if [[ "$platform" == ios ]]; then
        local share="$app_path/PlugIns/SnipSnapShareExtension.appex"
        local share_entitlements="$evidence_dir/share-entitlements.plist"
        signing_policy_verify_cloud_dev_signature "$share" "$expected_team" "$evidence_dir/share-signature.txt" || return 1
        "$codesign_tool" -d --entitlements :- "$share" > "$share_entitlements" 2>/dev/null || {
            signing_policy_fail "could not inspect Cloud Dev Share extension entitlements"; return 1
        }
        signing_policy_plist_value_equals "$share/Info.plist" CFBundleIdentifier "$bundle_id.share" || missing+=("Share extension bundle identifier")
        signing_policy_plist_value_equals "$share/Info.plist" SnipSnapAppGroupIdentifier "$app_group" || missing+=("Share extension configured App Group")
        signing_policy_plist_array_contains "$share_entitlements" com.apple.security.application-groups "$app_group" || missing+=("Share extension signed App Group")
        ! signing_policy_plist_has_key "$share_entitlements" com.apple.developer.icloud-container-identifiers || missing+=("Share extension App Group-only access")
        ! signing_policy_plist_has_key "$share_entitlements" com.apple.developer.icloud-services || missing+=("Share extension App Group-only access")
        if (( ${#missing} )); then
            for item in "${missing[@]}"; do print -u2 -- "Signed Cloud Dev app: missing $item."; done
            return 1
        fi
        signing_policy_verify_cloud_dev_profile "$share/embedded.mobileprovision" "$share_entitlements" ios "$bundle_id.share" "$app_group" "" "$evidence_dir/share" "$expected_team" || return 1
    fi
}

signing_policy_verify_production_cloudkit_app() {
    local app_path="$1"
    local cloudkit_container_identifier="$2"
    local development_team="$3"
    local bundle_identifier="$4"
    local codesign_tool="${SNIP_SNAP_CODESIGN:-/usr/bin/codesign}"
    local security_tool="${SNIP_SNAP_SECURITY:-/usr/bin/security}"
    local temp_root=""
    local entitlements=""
    local profile="$app_path/Contents/embedded.provisionprofile"
    local profile_plist=""
    local profile_entitlements=""
    local expiration=""
    local application_identifier=""
    local prefix_count=""
    local prefix=""
    local prefix_index
    local app_identifier_matches=false
    local item
    local -a missing

    [[ -d "$app_path" ]] || {
        signing_policy_fail "missing signed app at $app_path"
        return 1
    }
    [[ -n "$cloudkit_container_identifier" ]] || {
        signing_policy_fail "CloudKit container identifier is missing"
        return 1
    }
    [[ -f "$profile" ]] || {
        signing_policy_fail "signed app has no embedded Developer ID provisioning profile"
        return 1
    }
    "$codesign_tool" --verify --deep --strict "$app_path" >/dev/null 2>&1 || {
        signing_policy_fail "signed app verification failed"
        return 1
    }

    temp_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-mac-cloudkit.XXXXXX)"
    entitlements="$temp_root/entitlements.plist"
    profile_plist="$temp_root/profile.plist"
    profile_entitlements="$temp_root/profile-entitlements.plist"
    if ! "$codesign_tool" -d --entitlements :- "$app_path" \
        > "$entitlements" 2>/dev/null; then
        /bin/rm -rf "$temp_root"
        signing_policy_fail "could not inspect signed app entitlements"
        return 1
    fi
    if ! "$security_tool" cms -D -i "$profile" > "$profile_plist" 2>/dev/null; then
        /bin/rm -rf "$temp_root"
        signing_policy_fail "could not inspect embedded Developer ID provisioning profile"
        return 1
    fi
    /usr/bin/plutil -extract Entitlements xml1 -o "$profile_entitlements" \
        "$profile_plist" 2>/dev/null || missing+=("profile entitlements")

    /usr/bin/plutil -lint "$entitlements" >/dev/null 2>&1 || \
        missing+=("valid signed app entitlements")
    signing_policy_plist_array_contains \
        "$entitlements" com.apple.developer.icloud-container-identifiers \
        "$cloudkit_container_identifier" || missing+=("signed CloudKit container")
    signing_policy_plist_array_contains \
        "$entitlements" com.apple.developer.icloud-services CloudKit || \
        missing+=("signed CloudKit service")
    signing_policy_plist_value_equals \
        "$entitlements" com.apple.developer.icloud-container-environment Production || \
        missing+=("signed CloudKit Production environment")
    signing_policy_plist_value_equals \
        "$entitlements" com.apple.developer.aps-environment production || \
        missing+=("signed Apple Push Notification production environment")
    signing_policy_plist_array_contains \
        "$profile_plist" TeamIdentifier "$development_team" || \
        missing+=("profile team identifier")
    application_identifier="$(/usr/bin/plutil -extract \
        'com\.apple\.application-identifier' raw -o - "$profile_entitlements" 2>/dev/null)"
    prefix_count="$(/usr/bin/plutil -extract ApplicationIdentifierPrefix raw -o - \
        "$profile_plist" 2>/dev/null)"
    if [[ "$prefix_count" == <-> ]]; then
        for (( prefix_index = 0; prefix_index < prefix_count; prefix_index++ )); do
            prefix="$(/usr/bin/plutil -extract \
                "ApplicationIdentifierPrefix.$prefix_index" raw -o - \
                "$profile_plist" 2>/dev/null)" || continue
            if [[ "$application_identifier" == "$prefix.$bundle_identifier" ]]; then
                app_identifier_matches=true
                break
            fi
        done
    fi
    $app_identifier_matches || missing+=("profile application identifier")
    signing_policy_plist_array_contains \
        "$profile_entitlements" com.apple.developer.icloud-container-identifiers \
        "$cloudkit_container_identifier" || missing+=("profile CloudKit container")
    signing_policy_profile_allows_cloudkit "$profile_entitlements" || \
        missing+=("profile CloudKit service")
    signing_policy_plist_value_equals \
        "$profile_entitlements" com.apple.developer.icloud-container-environment \
        Production || missing+=("profile CloudKit Production environment")
    signing_policy_plist_value_equals \
        "$profile_entitlements" com.apple.developer.aps-environment production || \
        missing+=("profile Apple Push Notification production environment")
    expiration="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$profile_plist" 2>/dev/null)" || \
        missing+=("profile expiration date")
    if [[ -n "$expiration" ]] && ! /usr/bin/ruby -rtime -e \
        'exit(Time.parse(ARGV[0]) > Time.now ? 0 : 1)' "$expiration"; then
        missing+=("unexpired provisioning profile")
    fi
    /bin/rm -rf "$temp_root"

    if (( ${#missing} )); then
        for item in "${missing[@]}"; do
            print -u2 -- "Signed Mac release: missing $item."
        done
        return 1
    fi
    print "Signed Mac release CloudKit checks passed."
}

signing_policy_write_export_options() {
    local output_file="$1"
    local development_team="$2"
    local bundle_identifier="${3:-}"
    local profile_specifier="${4:-}"
    local escaped_bundle_identifier="${bundle_identifier//./\\.}"

    [[ -n "$development_team" ]] || {
        signing_policy_fail "cannot create release export options without DEVELOPMENT_TEAM"
        return 1
    }
    /usr/bin/plutil -create xml1 "$output_file"
    /usr/bin/plutil -insert method -string developer-id "$output_file"
    /usr/bin/plutil -insert signingCertificate \
        -string 'Developer ID Application' "$output_file"
    /usr/bin/plutil -insert signingStyle -string manual "$output_file"
    /usr/bin/plutil -insert stripSwiftSymbols -bool YES "$output_file"
    /usr/bin/plutil -insert teamID -string "$development_team" "$output_file"
    if [[ -n "$bundle_identifier" && -n "$profile_specifier" ]]; then
        /usr/bin/plutil -insert provisioningProfiles -json '{}' "$output_file"
        /usr/bin/plutil -insert \
            "provisioningProfiles.$escaped_bundle_identifier" \
            -string "$profile_specifier" "$output_file"
    fi
}
