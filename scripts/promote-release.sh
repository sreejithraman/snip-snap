#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
release_repo="${SNIP_SNAP_RELEASE_REPO:-sreejithraman/snip-snap}"
tap_repo="${SNIP_SNAP_TAP_REPO:-sreejithraman/homebrew-tap}"
requested_build=""
requested_version=""

source "$script_dir/release-policy.sh"
source "$script_dir/release-automation.sh"

usage() {
    print -u2 "Usage: $0 --version MAJOR.MINOR.PATCH --build-number NUMBER"
}

fail() {
    print -u2 "promote release: $1"
    exit 1
}

while (( $# )); do
    case "$1" in
        --build-number)
            (( $# >= 2 )) || { usage; exit 2; }
            requested_build="$2"
            shift 2
            ;;
        --version)
            (( $# >= 2 )) || { usage; exit 2; }
            requested_version="$2"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done
[[ -n "$requested_build" ]] || { usage; exit 2; }
release_policy_valid_version "$requested_version" || { usage; exit 2; }

typeset -g RELEASE_VERSION="$requested_version"
release_policy_set_build_number "$requested_build"
version="$requested_version"
build_number="$RELEASE_BUILD_NUMBER"
beta_tag="$(release_automation_beta_tag "$version" "$build_number")"
stable_tag="v$version"
record_name="$(release_automation_record_name "$version" "$build_number")"

command -v gh >/dev/null || fail "install GitHub CLI"
command -v brew >/dev/null || fail "install Homebrew"
gh auth status >/dev/null || fail "sign in with GitHub CLI"
[[ "$(gh repo view "$release_repo" --json isPrivate --jq '.isPrivate')" == false ]] || \
    fail "$release_repo must be public"

temp_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-promote.XXXXXX)"
tap_checkout=""
cleanup() {
    [[ "$temp_root" == /private/tmp/snip-snap-promote.* ]] && /bin/rm -rf "$temp_root"
    [[ -z "$tap_checkout" || "$tap_checkout" != /private/tmp/snip-snap-stable-tap.* ]] || \
        /bin/rm -rf "$tap_checkout"
}
trap cleanup EXIT

beta_dir="$temp_root/beta"
existing_dir="$temp_root/existing"
release_checkout="$temp_root/snip-snap"
tap_checkout="$(/usr/bin/mktemp -d /private/tmp/snip-snap-stable-tap.XXXXXX)"
/bin/mkdir -p "$beta_dir" "$existing_dir"

for asset in \
    "Snip-Snap-$version.zip" "Snip-Snap-$version.zip.sha256" \
    "Snip-Snap-$version.dmg" "Snip-Snap-$version.dmg.sha256" "$record_name"; do
    gh release download "$beta_tag" --repo "$release_repo" \
        --pattern "$asset" --dir "$beta_dir" || fail "missing $asset on $beta_tag"
done

record_path="$beta_dir/$record_name"
release_zip="$beta_dir/Snip-Snap-$version.zip"
release_dmg="$beta_dir/Snip-Snap-$version.dmg"
zip_checksum_file="$release_zip.sha256"
dmg_checksum_file="$release_dmg.sha256"
source_commit="$(/usr/bin/plutil -extract commit raw -o - "$record_path")" || \
    fail "the beta record has no commit"
release_automation_verify_record \
    "$record_path" "$version" "$build_number" "$release_zip" "$release_dmg" "$source_commit"
release_policy_verify_checksum "$release_zip" "$zip_checksum_file"
release_policy_verify_checksum "$release_dmg" "$dmg_checksum_file"

[[ "$(release_automation_remote_tag_commit "$release_repo" "$beta_tag")" == \
   "$source_commit" ]] || \
    fail "the beta tag does not point at the recorded commit"
release_policy_require_commit_on_main "$release_repo" "$source_commit"
release_automation_verify_workflow_run "$record_path" "$release_repo" "$source_commit"

release_exists=0
if gh release view "$stable_tag" --repo "$release_repo" >/dev/null 2>&1; then
    release_exists=1
    [[ "$(release_automation_remote_tag_commit "$release_repo" "$stable_tag")" == \
       "$source_commit" ]] || \
        fail "the stable tag does not point at the recorded commit"
    for asset in \
        "Snip-Snap-$version.zip" "Snip-Snap-$version.zip.sha256" \
        "Snip-Snap-$version.dmg" "Snip-Snap-$version.dmg.sha256"; do
        gh release download "$stable_tag" --repo "$release_repo" \
            --pattern "$asset" --dir "$existing_dir"
    done
    release_policy_verify_checksum \
        "$existing_dir/Snip-Snap-$version.zip" "$zip_checksum_file" || \
        fail "the stable ZIP differs from the beta"
    release_policy_verify_checksum \
        "$existing_dir/Snip-Snap-$version.dmg" "$dmg_checksum_file" || \
        fail "the stable DMG differs from the beta"
elif git ls-remote --exit-code "https://github.com/$release_repo.git" \
    "refs/tags/$stable_tag" >/dev/null 2>&1; then
    fail "$stable_tag exists without a matching GitHub release"
fi

notes_name="Snip-Snap-$version.md"
beta_notes="$temp_root/beta-notes.md"
gh release view "$beta_tag" --repo "$release_repo" --json body --jq '.body' > "$beta_notes" || \
    fail "could not read beta notes"
if (( ! release_exists )); then
    gh release create "$stable_tag" \
        "$release_zip" "$zip_checksum_file" "$release_dmg" "$dmg_checksum_file" \
        --repo "$release_repo" \
        --target "$source_commit" \
        --title "Snip Snap $version" \
        --notes-file "$beta_notes"
fi

gh repo clone "$release_repo" "$release_checkout" -- --quiet
gh repo clone "$tap_repo" "$tap_checkout" -- --quiet
[[ -f "$release_checkout/appcast.xml" ]] || fail "the beta appcast is missing"
promoted_appcast="$temp_root/appcast.xml"
if release_automation_require_appcast_channel \
    "$release_checkout/appcast.xml" "$version" "$build_number" beta \
    >/dev/null 2>&1; then
    release_automation_verify_record_appcast \
        "$record_path" "$release_checkout/appcast.xml" "$version" "$build_number" beta
    release_automation_promote_appcast \
        "$release_checkout/appcast.xml" "$promoted_appcast" \
        "$version" "$build_number" "$beta_tag"
elif release_automation_require_appcast_channel \
    "$release_checkout/appcast.xml" "$version" "$build_number" default \
    >/dev/null 2>&1; then
    release_automation_verify_record_appcast \
        "$record_path" "$release_checkout/appcast.xml" "$version" "$build_number" default
    /bin/cp "$release_checkout/appcast.xml" "$promoted_appcast"
else
    fail "the appcast has no matching beta or stable item"
fi
release_automation_require_appcast_channel \
    "$promoted_appcast" "$version" "$build_number" default
/bin/cp "$promoted_appcast" "$release_checkout/appcast.xml"
/bin/cp "$beta_notes" "$release_checkout/$notes_name"

checksum="$(/usr/bin/awk 'NR == 1 { print $1 }' "$zip_checksum_file")"
cask_path="$tap_checkout/Casks/snip-snap.rb"
desired_cask="$temp_root/snip-snap.rb"
/usr/bin/sed \
    -e "s|@REPO@|$release_repo|g" \
    -e "s/@VERSION@/$version/g" \
    -e "s/@SHA256@/$checksum/g" \
    "$script_dir/snip-snap.rb.template" > "$desired_cask"
/usr/bin/ruby -c "$desired_cask" >/dev/null
if [[ -f "$cask_path" ]]; then
    current_cask_version="$(/usr/bin/sed -nE \
        's/^[[:space:]]*version "([0-9]+\.[0-9]+\.[0-9]+)".*$/\1/p' \
        "$cask_path" | /usr/bin/head -1)"
    if [[ -n "$current_cask_version" ]] &&
       release_policy_version_is_greater "$current_cask_version" "$version"; then
        fail "stable cask $current_cask_version is newer than $version"
    fi
fi
if [[ -f "$cask_path" ]] &&
   /usr/bin/grep -q "version \"$version\"" "$cask_path" &&
   ! /usr/bin/cmp -s "$cask_path" "$desired_cask"; then
    fail "the stable cask version already has different content"
fi
/bin/mkdir -p "${cask_path:h}"
/bin/cp "$desired_cask" "$cask_path"
brew style --cask "$cask_path"

if [[ -n "$(git -C "$release_checkout" status --short)" ]]; then
    git -C "$release_checkout" add appcast.xml "$notes_name"
    git -C "$release_checkout" commit -m "Promote Snip Snap $version"
    git -C "$release_checkout" push origin main
fi
if [[ -n "$(git -C "$tap_checkout" status --short)" ]]; then
    git -C "$tap_checkout" add Casks/snip-snap.rb
    git -C "$tap_checkout" commit -m "Publish Snip Snap $version cask"
    git -C "$tap_checkout" push origin main
fi

print "Promoted $beta_tag to $stable_tag with the same Mac files."
print "Select TestFlight build $version ($build_number) in App Store Connect."
