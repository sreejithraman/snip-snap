#!/bin/zsh

signing_policy_fail() {
    print -u2 "signed-lane preflight: $1"
    return 1
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
            )
            required_environment=(
                SNIP_SNAP_SIGNING_IDENTITY
                SNIP_SNAP_NOTARY_PROFILE
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

    if [[ -z "$entitlement_setting" && "$lane" == release ]]; then
        entitlement_setting="$(signing_policy_resolve_setting \
            "$settings_file" CODE_SIGN_ENTITLEMENTS "$scheme")"
    fi
    if [[ -n "$entitlement_setting" ]]; then
        entitlement_path="$(signing_policy_entitlement_path \
            "$repo_dir" "$entitlement_setting")"
        if [[ ! -f "$entitlement_path" ]]; then
            missing+=("CODE_SIGN_ENTITLEMENTS file")
        elif ! /usr/bin/plutil -lint "$entitlement_path" >/dev/null 2>&1; then
            missing+=("valid entitlement plist")
        elif [[ "$lane" == cloud || "$lane" == device || "$lane" == testflight ]]; then
            signing_policy_plist_array_contains \
                "$entitlement_path" com.apple.security.application-groups \
                "$app_group_identifier" '$(SNIP_SNAP_APP_GROUP_IDENTIFIER)' || \
                missing+=("App Group entitlement")
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
            elif [[ "$lane" == testflight ]]; then
                signing_policy_plist_value_equals \
                    "$entitlement_path" \
                    com.apple.developer.icloud-container-environment \
                    Production || missing+=("CloudKit Production environment entitlement")
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

signing_policy_write_export_options() {
    local output_file="$1"
    local development_team="$2"

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
}
