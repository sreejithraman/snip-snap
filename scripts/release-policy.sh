#!/bin/zsh

release_policy_fail() {
    print -u2 "release policy: $1"
    return 1
}

release_policy_valid_version() {
    [[ "$1" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]]
}

release_policy_version_is_greater() {
    local candidate="$1"
    local prior="$2"
    local candidate_major="${candidate%%.*}"
    local candidate_tail="${candidate#*.}"
    local candidate_minor="${candidate_tail%%.*}"
    local candidate_patch="${candidate_tail#*.}"
    local prior_major="${prior%%.*}"
    local prior_tail="${prior#*.}"
    local prior_minor="${prior_tail%%.*}"
    local prior_patch="${prior_tail#*.}"

    (( candidate_major > prior_major )) ||
        (( candidate_major == prior_major && candidate_minor > prior_minor )) ||
        (( candidate_major == prior_major && candidate_minor == prior_minor &&
            candidate_patch > prior_patch ))
}

release_policy_load_manifest() {
    local manifest_path="$1"
    local manifest_version
    local manifest_build

    [[ -f "$manifest_path" ]] || {
        release_policy_fail "missing $manifest_path"
        return 1
    }
    manifest_version="$(/usr/bin/plutil -extract version raw -o - "$manifest_path" 2>/dev/null)" || {
        release_policy_fail "release.json needs a string version"
        return 1
    }
    manifest_build="$(/usr/bin/plutil -extract build raw -o - "$manifest_path" 2>/dev/null)" || {
        release_policy_fail "release.json needs an integer build"
        return 1
    }

    release_policy_valid_version "$manifest_version" || {
        release_policy_fail "version must use stable MAJOR.MINOR.PATCH without leading zeroes"
        return 1
    }
    [[ "$manifest_build" =~ '^[1-9][0-9]*$' ]] || {
        release_policy_fail "build must be a positive integer"
        return 1
    }

    if [[ -n "${SNIP_SNAP_VERSION:-}" && "$SNIP_SNAP_VERSION" != "$manifest_version" ]]; then
        release_policy_fail "SNIP_SNAP_VERSION must match release.json ($manifest_version)"
        return 1
    fi
    if [[ -n "${SNIP_SNAP_BUILD_NUMBER:-}" &&
          "$SNIP_SNAP_BUILD_NUMBER" != "$manifest_build" ]]; then
        release_policy_fail "SNIP_SNAP_BUILD_NUMBER must match release.json ($manifest_build)"
        return 1
    fi

    typeset -g RELEASE_VERSION="$manifest_version"
    typeset -g RELEASE_BUILD_NUMBER="$manifest_build"
}

release_policy_require_project_versions() {
    local project_path="$1"
    local value
    local found_marketing=0
    local found_build=0

    while IFS= read -r value; do
        found_marketing=1
        [[ "$value" == "$RELEASE_VERSION" ]] || {
            release_policy_fail "Xcode MARKETING_VERSION $value does not match $RELEASE_VERSION"
            return 1
        }
    done < <(/usr/bin/sed -nE \
        's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$project_path")

    while IFS= read -r value; do
        found_build=1
        [[ "$value" == "$RELEASE_BUILD_NUMBER" ]] || {
            release_policy_fail "Xcode CURRENT_PROJECT_VERSION $value does not match $RELEASE_BUILD_NUMBER"
            return 1
        }
    done < <(/usr/bin/sed -nE \
        's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' "$project_path")

    (( found_marketing )) || {
        release_policy_fail "Xcode has no MARKETING_VERSION"
        return 1
    }
    (( found_build )) || {
        release_policy_fail "Xcode has no CURRENT_PROJECT_VERSION"
        return 1
    }
}

release_policy_require_source() {
    local repo_dir="$1"
    local release_repo="$2"
    local git_status
    local head
    local remote_head
    local is_private

    git_status="$(git -C "$repo_dir" status --porcelain --untracked-files=normal)" || {
        release_policy_fail "could not read Git status"
        return 1
    }
    [[ -z "$git_status" ]] || {
        release_policy_fail "release from a clean worktree"
        return 1
    }

    head="$(git -C "$repo_dir" rev-parse HEAD)" || {
        release_policy_fail "could not read HEAD"
        return 1
    }
    remote_head="$(git -C "$repo_dir" ls-remote origin refs/heads/main | \
        /usr/bin/awk 'NR == 1 { print $1 }')" || {
        release_policy_fail "could not read public origin/main"
        return 1
    }
    [[ -n "$remote_head" && "$head" == "$remote_head" ]] || {
        release_policy_fail "HEAD must equal current public origin/main"
        return 1
    }

    command -v gh >/dev/null || {
        release_policy_fail "install GitHub CLI"
        return 1
    }
    is_private="$(gh repo view "$release_repo" --json isPrivate --jq '.isPrivate')" || {
        release_policy_fail "could not read $release_repo"
        return 1
    }
    [[ "$is_private" == "false" ]] || {
        release_policy_fail "$release_repo must be public"
        return 1
    }
}

release_policy_preflight() {
    local repo_dir="$1"
    local release_repo="$2"
    local mode="${3:-release}"

    release_policy_load_manifest "$repo_dir/release.json" || return 1
    release_policy_require_project_versions \
        "$repo_dir/SnipSnap.xcodeproj/project.pbxproj" || return 1
    release_policy_require_source "$repo_dir" "$release_repo" || return 1
    case "$mode" in
        release)
            release_policy_require_new_version "$repo_dir" || return 1
            release_policy_require_new_build "$repo_dir/appcast.xml" || return 1
            ;;
        publish)
            release_policy_require_version_not_older "$repo_dir" || return 1
            release_policy_require_build_not_older "$repo_dir/appcast.xml" || return 1
            ;;
        *)
            release_policy_fail "unknown preflight mode $mode"
            return 1
            ;;
    esac
}

release_policy_latest_remote_version() {
    local repo_dir="$1"
    local tag_output
    local line
    local ref
    local prior
    local latest=""

    tag_output="$(git -C "$repo_dir" ls-remote --tags origin 'refs/tags/v*')" || {
        release_policy_fail "could not read release tags"
        return 1
    }
    for line in ${(f)tag_output}; do
        ref="${line#*$'\t'}"
        [[ "$ref" == *'^{}' ]] && continue
        prior="${ref#refs/tags/v}"
        release_policy_valid_version "$prior" || continue
        if [[ -z "$latest" ]] || release_policy_version_is_greater "$prior" "$latest"; then
            latest="$prior"
        fi
    done

    print "$latest"
}

release_policy_require_new_version() {
    local repo_dir="$1"
    local latest

    latest="$(release_policy_latest_remote_version "$repo_dir")" || return 1
    [[ -z "$latest" ]] && return 0
    release_policy_version_is_greater "$RELEASE_VERSION" "$latest" || {
        release_policy_fail "version $RELEASE_VERSION must be newer than v$latest"
        return 1
    }
}

release_policy_require_version_not_older() {
    local repo_dir="$1"
    local latest

    latest="$(release_policy_latest_remote_version "$repo_dir")" || return 1
    [[ -z "$latest" ]] && return 0
    if release_policy_version_is_greater "$latest" "$RELEASE_VERSION"; then
        release_policy_fail "version $RELEASE_VERSION is older than v$latest"
        return 1
    fi
}

release_policy_remote_tag_exists() {
    local repo_dir="$1"
    local version="$2"
    local tag_output

    tag_output="$(git -C "$repo_dir" ls-remote --tags origin "refs/tags/v$version")" ||
        return 1
    [[ -n "$tag_output" ]]
}

release_policy_latest_appcast_build() {
    local appcast_path="$1"
    local matches
    local build
    local latest=0

    [[ -f "$appcast_path" ]] || {
        print 0
        return 0
    }
    matches="$(/usr/bin/grep -Eo 'sparkle:version(=\"|>)[0-9]+' "$appcast_path" 2>/dev/null | \
        /usr/bin/grep -Eo '[0-9]+$' || true)"
    for build in ${(f)matches}; do
        (( build > latest )) && latest="$build"
    done
    print "$latest"
}

release_policy_require_new_build() {
    local appcast_path="$1"
    local latest

    latest="$(release_policy_latest_appcast_build "$appcast_path")" || return 1
    (( RELEASE_BUILD_NUMBER > latest )) || {
        release_policy_fail "build $RELEASE_BUILD_NUMBER must be greater than published build $latest"
        return 1
    }
}

release_policy_require_build_not_older() {
    local appcast_path="$1"
    local latest

    latest="$(release_policy_latest_appcast_build "$appcast_path")" || return 1
    if (( latest > RELEASE_BUILD_NUMBER )); then
        release_policy_fail "build $RELEASE_BUILD_NUMBER is older than published build $latest"
        return 1
    fi
}

release_policy_notary_submission_names() {
    local history_json="$1"

    print -r -- "$history_json" | /usr/bin/ruby -rjson -e '
        data = JSON.parse(STDIN.read)
        history = data.fetch("history")
        raise "history is not an array" unless history.is_a?(Array)
        history.each do |entry|
          next unless entry.is_a?(Hash)
          name = entry["name"]
          puts name if name.is_a?(String)
        end
    '
}

release_policy_notary_history_contains_build() {
    local history_json="$1"
    local build_number="$2"
    local submission_name
    local names

    names="$(release_policy_notary_submission_names "$history_json")" || return 1
    for submission_name in ${(f)names}; do
        [[ "$submission_name" == "Snip-Snap-build-$build_number-"* ]] && return 0
    done
    return 1
}

release_policy_latest_notary_build() {
    local history_json="$1"
    local submission_name
    local build_number
    local latest=0
    local names

    names="$(release_policy_notary_submission_names "$history_json")" || return 1
    for submission_name in ${(f)names}; do
        [[ "$submission_name" == Snip-Snap-build-<->-* ]] || continue
        build_number="${submission_name#Snip-Snap-build-}"
        build_number="${build_number%%-*}"
        (( build_number > latest )) && latest="$build_number"
    done
    print "$latest"
}

release_policy_require_new_notary_build_from_history() {
    local history_json="$1"
    local build_number="$2"
    local latest

    latest="$(release_policy_latest_notary_build "$history_json")" || return 1
    (( build_number > latest )) || {
        release_policy_fail "build $build_number must be greater than Apple build $latest"
        return 1
    }
}

release_policy_require_new_notary_build() {
    local profile="$1"
    local build_number="$2"
    local history_json

    history_json="$(/usr/bin/xcrun notarytool history \
        --keychain-profile "$profile" \
        --output-format json)" || {
        release_policy_fail "could not read Apple notarization history with profile $profile"
        return 1
    }
    release_policy_require_new_notary_build_from_history "$history_json" "$build_number"
}

release_policy_verify_app() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    local app_version
    local app_build

    [[ -f "$plist" ]] || {
        release_policy_fail "missing app Info.plist"
        return 1
    }
    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" || {
        release_policy_fail "could not read app version"
        return 1
    }
    app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" || {
        release_policy_fail "could not read app build"
        return 1
    }
    [[ "$app_version" == "$RELEASE_VERSION" ]] || {
        release_policy_fail "app version $app_version does not match $RELEASE_VERSION"
        return 1
    }
    [[ "$app_build" == "$RELEASE_BUILD_NUMBER" ]] || {
        release_policy_fail "app build $app_build does not match $RELEASE_BUILD_NUMBER"
        return 1
    }
}

release_policy_verify_checksum() {
    local archive_path="$1"
    local checksum_path="$2"
    local expected
    local actual

    [[ -f "$archive_path" ]] || {
        release_policy_fail "missing $archive_path"
        return 1
    }
    [[ -f "$checksum_path" ]] || {
        release_policy_fail "missing $checksum_path"
        return 1
    }
    expected="$(/usr/bin/awk 'NR == 1 { print $1 }' "$checksum_path")"
    actual="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{ print $1 }')" || {
        release_policy_fail "could not hash $archive_path"
        return 1
    }
    [[ -n "$expected" && "$actual" == "$expected" ]] || {
        release_policy_fail "release ZIP does not match its checksum"
        return 1
    }
}

release_policy_appcast_contains_release() {
    local appcast_path="$1"

    release_policy_release_enclosure "$appcast_path" >/dev/null || {
        release_policy_fail "appcast is missing release $RELEASE_VERSION ($RELEASE_BUILD_NUMBER)"
        return 1
    }
}

release_policy_release_enclosure() {
    local appcast_path="$1"

    [[ -f "$appcast_path" ]] || return 1
    /usr/bin/perl -0 -e '
        my ($build, $version, $path) = @ARGV;
        open my $file, "<", $path or exit 1;
        local $/;
        my $xml = <$file>;
        while ($xml =~ m{<item\b.*?</item>}sg) {
            my $item = $&;
            my $has_build =
                $item =~ /sparkle:version="\Q$build\E"/ ||
                $item =~ m{<sparkle:version>\Q$build\E</sparkle:version>};
            my $has_version =
                $item =~ /sparkle:shortVersionString="\Q$version\E"/ ||
                $item =~ m{<sparkle:shortVersionString>\Q$version\E</sparkle:shortVersionString>};
            next unless $has_build && $has_version;
            if ($item =~ m{<enclosure\b[^>]*>}s) {
                print $&;
                exit 0;
            }
            exit 1;
        }
        exit 1;
    ' "$RELEASE_BUILD_NUMBER" "$RELEASE_VERSION" "$appcast_path"
}

release_policy_require_matching_appcast_release() {
    local existing_appcast="$1"
    local expected_appcast="$2"
    local existing_enclosure
    local expected_enclosure

    existing_enclosure="$(release_policy_release_enclosure "$existing_appcast")" || {
        release_policy_fail "existing appcast has no matching release enclosure"
        return 1
    }
    expected_enclosure="$(release_policy_release_enclosure "$expected_appcast")" || {
        release_policy_fail "could not generate the expected release enclosure"
        return 1
    }
    [[ "$existing_enclosure" == "$expected_enclosure" ]] || {
        release_policy_fail "existing appcast release does not match the notarized ZIP"
        return 1
    }
}

release_policy_require_preserved_appcast_items() {
    local old_appcast="$1"
    local new_appcast="$2"
    local old_hashes
    local new_hashes
    local item_hash

    [[ -f "$old_appcast" ]] || return 0
    [[ -f "$new_appcast" ]] || {
        release_policy_fail "missing generated appcast"
        return 1
    }
    old_hashes="$(/usr/bin/perl -MDigest::SHA=sha256_hex -0ne \
        'while (/<item\b.*?<\/item>/sg) { print sha256_hex($&), "\n" }' \
        "$old_appcast")" || {
        release_policy_fail "could not read prior appcast entries"
        return 1
    }
    new_hashes="$(/usr/bin/perl -MDigest::SHA=sha256_hex -0ne \
        'while (/<item\b.*?<\/item>/sg) { print sha256_hex($&), "\n" }' \
        "$new_appcast")" || {
        release_policy_fail "could not read generated appcast entries"
        return 1
    }
    for item_hash in ${(f)old_hashes}; do
        /usr/bin/grep -Fqx -- "$item_hash" <<< "$new_hashes" || {
            release_policy_fail "generated appcast changed a prior release entry"
            return 1
        }
    done
}
