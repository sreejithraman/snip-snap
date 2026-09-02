#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
release_repo="${SNIP_SNAP_RELEASE_REPO:-sreejithraman/snip-snap}"
tap_repo="${SNIP_SNAP_TAP_REPO:-sreejithraman/homebrew-tap}"
tap_owner="${tap_repo%%/*}"
tap_name="$tap_owner/${${tap_repo#*/}#homebrew-}"
sparkle_account="${SNIP_SNAP_SPARKLE_KEY_ACCOUNT:-ed25519}"
requested_build=""

source "$script_dir/release-policy.sh"
source "$script_dir/release-automation.sh"

usage() {
    print -u2 "Usage: $0 --build-number NUMBER"
}

fail() {
    print -u2 "publish beta: $1"
    exit 1
}

generate_beta_appcast() {
    local target_dir="$1"
    "$sparkle_tool" \
        "${sparkle_key_args[@]}" \
        --channel beta \
        --maximum-versions 0 \
        --download-url-prefix "https://github.com/$release_repo/releases/download/$beta_tag/" \
        --link "https://github.com/$release_repo/releases/tag/$beta_tag" \
        --full-release-notes-url \
            "https://raw.githubusercontent.com/$release_repo/main/$notes_name" \
        --versions "$build_number" \
        "$target_dir"
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
[[ -n "$requested_build" ]] || { usage; exit 2; }

release_policy_preflight "$repo_dir" "$release_repo" beta-publish "$requested_build"
version="$RELEASE_VERSION"
build_number="$RELEASE_BUILD_NUMBER"
beta_tag="$(release_automation_beta_tag "$version" "$build_number")"
source_commit="$(git -C "$repo_dir" rev-parse HEAD)"
run_url="${SNIP_SNAP_RUN_URL:-local}"
run_id="${GITHUB_RUN_ID:-}"
run_attempt="${GITHUB_RUN_ATTEMPT:-}"
release_root="${SNIP_SNAP_RELEASE_DIR:-$repo_dir/artifacts/release-$version-$build_number}"
release_zip="$release_root/Snip-Snap-$version.zip"
release_dmg="$release_root/Snip-Snap-$version.dmg"
zip_checksum_file="$release_zip.sha256"
dmg_checksum_file="$release_dmg.sha256"
record_name="$(release_automation_record_name "$version" "$build_number")"
record_path="$release_root/$record_name"

for path in "$release_zip" "$release_dmg" "$zip_checksum_file" "$dmg_checksum_file"; do
    [[ -f "$path" ]] || fail "missing $path"
done
release_policy_verify_checksum "$release_zip" "$zip_checksum_file"
release_policy_verify_checksum "$release_dmg" "$dmg_checksum_file"
brew_tool="${SNIP_SNAP_BREW:-$(command -v brew 2>/dev/null || true)}"
[[ -x "$brew_tool" ]] || fail "install Homebrew"
gh auth status >/dev/null || fail "sign in with GitHub CLI"

sparkle_tool="${SNIP_SNAP_GENERATE_APPCAST:-}"
if [[ -z "$sparkle_tool" ]]; then
    sparkle_tool="$(/usr/bin/find "$repo_dir" /private/tmp/snip-snap-derived-data \
        -type f -name generate_appcast -perm -111 2>/dev/null | /usr/bin/head -1)"
fi
[[ -x "$sparkle_tool" ]] || fail "set SNIP_SNAP_GENERATE_APPCAST"
sparkle_key_args=(--account "$sparkle_account")
if [[ -n "${SNIP_SNAP_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    [[ -f "$SNIP_SNAP_SPARKLE_PRIVATE_KEY_FILE" ]] || fail "missing Sparkle private key file"
    sparkle_key_args=(--ed-key-file "$SNIP_SNAP_SPARKLE_PRIVATE_KEY_FILE")
fi

temp_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-publish-beta.XXXXXX)"
cleanup() {
    [[ "$temp_root" == /private/tmp/snip-snap-publish-beta.* ]] && /bin/rm -rf "$temp_root"
}
trap cleanup EXIT

release_checkout="$temp_root/snip-snap"
feed_dir="$temp_root/feed"
expected_feed_dir="$temp_root/expected-feed"
existing_dir="$temp_root/existing"
/bin/mkdir -p "$feed_dir" "$expected_feed_dir" "$existing_dir"
gh repo clone "$release_repo" "$release_checkout" -- --quiet
"$brew_tool" tap "$tap_name"
tap_checkout="$("$brew_tool" --repository "$tap_name")"
[[ -d "$tap_checkout/.git" ]] || fail "could not open Homebrew tap $tap_name"
release_policy_require_build_not_older "$release_checkout/appcast.xml"

notes_name="Snip-Snap-$version-beta.$build_number.md"
notes_path="$release_root/$notes_name"
if [[ -n "${SNIP_SNAP_RELEASE_NOTES_FILE:-}" ]]; then
    [[ -f "$SNIP_SNAP_RELEASE_NOTES_FILE" ]] || fail "missing release notes"
    /bin/cp -p "$SNIP_SNAP_RELEASE_NOTES_FILE" "$notes_path"
elif [[ ! -f "$notes_path" ]]; then
    print "Snip Snap $version Beta $build_number" > "$notes_path"
fi

/bin/cp -p "$release_zip" "$feed_dir/"
/bin/cp -p "$notes_path" "$feed_dir/Snip-Snap-$version.md"
/bin/cp -p "$release_zip" "$expected_feed_dir/"
/bin/cp -p "$notes_path" "$expected_feed_dir/Snip-Snap-$version.md"
[[ ! -f "$release_checkout/appcast.xml" ]] || \
    /bin/cp -p "$release_checkout/appcast.xml" "$feed_dir/appcast.xml"

generate_beta_appcast "$expected_feed_dir"
release_automation_require_appcast_channel \
    "$expected_feed_dir/appcast.xml" "$version" "$build_number" beta

if [[ -f "$release_checkout/appcast.xml" ]] &&
   release_policy_appcast_contains_release "$release_checkout/appcast.xml" >/dev/null 2>&1; then
    release_policy_require_matching_appcast_release \
        "$release_checkout/appcast.xml" "$expected_feed_dir/appcast.xml"
    release_automation_require_appcast_channel \
        "$release_checkout/appcast.xml" "$version" "$build_number" beta
    /bin/cp -p "$release_checkout/appcast.xml" "$feed_dir/appcast.xml"
else
    generate_beta_appcast "$feed_dir"
    release_policy_require_preserved_appcast_items \
        "$release_checkout/appcast.xml" "$feed_dir/appcast.xml"
    release_automation_require_appcast_channel \
        "$feed_dir/appcast.xml" "$version" "$build_number" beta
fi

release_automation_write_record \
    "$record_path" "$version" "$build_number" "$source_commit" "$run_url" \
    "$release_zip" "$release_dmg" "$run_id" "$run_attempt" "$feed_dir/appcast.xml"
release_automation_verify_record \
    "$record_path" "$version" "$build_number" "$release_zip" "$release_dmg" "$source_commit"

release_exists=0
if gh release view "$beta_tag" --repo "$release_repo" >/dev/null 2>&1; then
    release_exists=1
    [[ "$(release_automation_remote_tag_commit "$release_repo" "$beta_tag")" == \
       "$source_commit" ]] || fail "the existing beta tag points at another commit"
    for asset in \
        "Snip-Snap-$version.zip" "Snip-Snap-$version.zip.sha256" \
        "Snip-Snap-$version.dmg" "Snip-Snap-$version.dmg.sha256" "$record_name"; do
        gh release download "$beta_tag" --repo "$release_repo" \
            --pattern "$asset" --dir "$existing_dir"
    done
    release_automation_verify_record \
        "$existing_dir/$record_name" "$version" "$build_number" \
        "$existing_dir/Snip-Snap-$version.zip" "$existing_dir/Snip-Snap-$version.dmg" \
        "$source_commit" || fail "the existing beta has different files"
    release_policy_verify_checksum \
        "$existing_dir/Snip-Snap-$version.zip" "$zip_checksum_file" || \
        fail "the existing beta ZIP differs"
    release_policy_verify_checksum \
        "$existing_dir/Snip-Snap-$version.dmg" "$dmg_checksum_file" || \
        fail "the existing beta DMG differs"
elif git ls-remote --exit-code "https://github.com/$release_repo.git" \
    "refs/tags/$beta_tag" >/dev/null 2>&1; then
    fail "$beta_tag exists without a matching GitHub prerelease"
fi

if (( ! release_exists )); then
    gh release create "$beta_tag" \
        "$release_zip" "$zip_checksum_file" "$release_dmg" "$dmg_checksum_file" "$record_path" \
        --repo "$release_repo" \
        --target "$source_commit" \
        --prerelease \
        --title "Snip Snap $version Beta $build_number" \
        --notes-file "$notes_path"
fi

checksum="$(/usr/bin/awk 'NR == 1 { print $1 }' "$zip_checksum_file")"
cask_path="$tap_checkout/Casks/snip-snap@beta.rb"
desired_cask="$temp_root/snip-snap@beta.rb"
/usr/bin/sed \
    -e "s|@REPO@|$release_repo|g" \
    -e "s/@VERSION@/$version/g" \
    -e "s/@BUILD@/$build_number/g" \
    -e "s/@TAG@/$beta_tag/g" \
    -e "s/@SHA256@/$checksum/g" \
    "$script_dir/snip-snap-beta.rb.template" > "$desired_cask"
/usr/bin/ruby -c "$desired_cask" >/dev/null
if [[ -f "$cask_path" ]] &&
   /usr/bin/grep -q "version \"$version-beta.$build_number\"" "$cask_path" &&
   ! /usr/bin/cmp -s "$cask_path" "$desired_cask"; then
    fail "the beta cask version already has different content"
fi
/bin/mkdir -p "${cask_path:h}"
/bin/cp "$desired_cask" "$cask_path"
"$brew_tool" style --cask "$cask_path"

/bin/cp "$feed_dir/appcast.xml" "$release_checkout/appcast.xml"
/bin/cp "$notes_path" "$release_checkout/$notes_name"
if [[ -n "$(git -C "$release_checkout" status --short)" ]]; then
    git -C "$release_checkout" add appcast.xml "$notes_name"
    git -C "$release_checkout" commit -m "Publish Snip Snap $version beta $build_number"
    git -C "$release_checkout" push origin main
fi
if [[ -n "$(git -C "$tap_checkout" status --short)" ]]; then
    git -C "$tap_checkout" add 'Casks/snip-snap@beta.rb'
    git -C "$tap_checkout" commit -m "Publish Snip Snap $version beta $build_number cask"
    git -C "$tap_checkout" push origin main
fi

print "GitHub prerelease: https://github.com/$release_repo/releases/tag/$beta_tag"
print "Sparkle channel: beta"
print "Homebrew: brew install --cask $tap_name/snip-snap@beta"
