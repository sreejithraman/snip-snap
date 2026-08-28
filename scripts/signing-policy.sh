#!/bin/zsh

signing_policy_fail() {
    print -u2 "signed-lane preflight: $1"
    return 1
}

signing_policy_resolve_setting() {
    local settings_file="$1"
    local setting_name="$2"
    local value

    value="$(/usr/bin/awk -v wanted="$setting_name" '
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
    local xcodebuild_tool="${SNIP_SNAP_XCODEBUILD:-xcodebuild}"
    local command=(
        "$xcodebuild_tool"
        -project "$repo_dir/SnipSnap.xcodeproj"
        -scheme SnipSnap
        -configuration "$configuration"
        -destination "$destination"
        -showBuildSettings
    )

    [[ -z "$derived_data" ]] || command+=( -derivedDataPath "$derived_data" )

    [[ -z "${SNIP_SNAP_DEVELOPMENT_TEAM:-}" ]] || \
        command+=("DEVELOPMENT_TEAM=$SNIP_SNAP_DEVELOPMENT_TEAM")
    [[ -z "${SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER:-}" ]] || \
        command+=("SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=$SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER")
    [[ -z "${SNIP_SNAP_APP_GROUP_IDENTIFIER:-}" ]] || \
        command+=("SNIP_SNAP_APP_GROUP_IDENTIFIER=$SNIP_SNAP_APP_GROUP_IDENTIFIER")
    [[ -z "${SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER:-}" ]] || \
        command+=("SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER=$SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER")
    [[ -z "${SNIP_SNAP_CODE_SIGN_ENTITLEMENTS:-}" ]] || \
        command+=("CODE_SIGN_ENTITLEMENTS=$SNIP_SNAP_CODE_SIGN_ENTITLEMENTS")

    "${command[@]}" > "$output_file" 2> "$output_file.stderr" || {
        /bin/rm -f "$output_file.stderr"
        signing_policy_fail "could not resolve Xcode build settings"
        return 1
    }
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

signing_policy_preflight() {
    local lane="$1"
    local settings_file="$2"
    local repo_dir="$3"
    local setting
    local value
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
        cloud|device)
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
        value="$(signing_policy_resolve_setting "$settings_file" "$setting")"
        if [[ -z "$value" ]]; then
            missing+=("$setting")
        elif [[ "$setting" == CODE_SIGN_ENTITLEMENTS ]]; then
            entitlement_setting="$value"
        fi
    done

    for setting in "${required_environment[@]}"; do
        [[ -n "${(P)setting:-}" ]] || missing+=("$setting")
    done

    if [[ -z "$entitlement_setting" && "$lane" == release ]]; then
        entitlement_setting="$(signing_policy_resolve_setting \
            "$settings_file" CODE_SIGN_ENTITLEMENTS)"
    fi
    if [[ -n "$entitlement_setting" ]]; then
        entitlement_path="$(signing_policy_entitlement_path \
            "$repo_dir" "$entitlement_setting")"
        [[ -f "$entitlement_path" ]] || missing+=("CODE_SIGN_ENTITLEMENTS file")
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
