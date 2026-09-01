#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
requested_version="${1:-}"

source "$script_dir/release-policy.sh"

release_policy_valid_version "$requested_version" || {
    print -u2 "usage: $0 MAJOR.MINOR.PATCH"
    exit 1
}
(( $# == 1 )) || {
    print -u2 "usage: $0 MAJOR.MINOR.PATCH"
    exit 1
}

release_policy_load_manifest "$repo_dir/release.json"
current_version="$RELEASE_VERSION"

if release_policy_version_is_greater "$current_version" "$requested_version"; then
    release_policy_fail "version cannot move back from $current_version to $requested_version"
    exit 1
fi
temp_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-set-release.XXXXXX)"
cleanup() {
    [[ "$temp_root" == /private/tmp/snip-snap-set-release.* ]] && /bin/rm -rf "$temp_root"
}
trap cleanup EXIT

manifest="$repo_dir/release.json"
settings="$repo_dir/Config/Shared.xcconfig"
new_manifest="$temp_root/release.json"
new_settings="$temp_root/Shared.xcconfig"
manifest_backup="$temp_root/release.backup.json"

/bin/cp "$manifest" "$new_manifest"
/bin/cp "$manifest" "$manifest_backup"
/bin/cp "$settings" "$new_settings"
/usr/bin/plutil -replace version -string "$requested_version" "$new_manifest"
/usr/bin/sed -E -i '' \
    "s/(MARKETING_VERSION = )[^[:space:]]+/\\1$requested_version/" \
    "$new_settings"

typeset -g RELEASE_VERSION="$requested_version"
release_policy_require_project_versions "$new_settings"

/bin/cp "$new_manifest" "$manifest"
if ! /bin/cp "$new_settings" "$settings"; then
    /bin/cp "$manifest_backup" "$manifest"
    release_policy_fail "could not update build settings; release.json was restored"
    exit 1
fi

print "Set Snip Snap marketing version to $requested_version."
