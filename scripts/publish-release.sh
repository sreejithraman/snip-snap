#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
release_repo="${SNIP_SNAP_RELEASE_REPO:-sreejithraman/snip-snap}"
tap_repo="${SNIP_SNAP_TAP_REPO:-sreejithraman/homebrew-tap}"
tap_name="${SNIP_SNAP_TAP_NAME:-sreejithraman/tap}"
sparkle_account="${SNIP_SNAP_SPARKLE_KEY_ACCOUNT:-ed25519}"

source "$script_dir/release-policy.sh"
release_policy_preflight "$repo_dir" "$release_repo" publish
version="$RELEASE_VERSION"
build_number="$RELEASE_BUILD_NUMBER"

fail() {
    print -u2 "publish-release: $1"
    exit 1
}

release_root="${SNIP_SNAP_RELEASE_DIR:-$repo_dir/artifacts/release-$version-$build_number}"
release_zip="$release_root/Snip-Snap-$version.zip"
zip_checksum_file="$release_zip.sha256"
release_dmg="$release_root/Snip-Snap-$version.dmg"
dmg_checksum_file="$release_dmg.sha256"
[[ -f "$release_zip" ]] || fail "missing $release_zip; run release.sh first"
[[ -f "$zip_checksum_file" ]] || fail "missing $zip_checksum_file; run release.sh first"
[[ -f "$release_dmg" ]] || fail "missing $release_dmg; run release.sh first"
[[ -f "$dmg_checksum_file" ]] || fail "missing $dmg_checksum_file; run release.sh first"
release_policy_verify_checksum "$release_zip" "$zip_checksum_file"
release_policy_verify_checksum "$release_dmg" "$dmg_checksum_file"
/usr/bin/codesign --verify --verbose=2 "$release_dmg"
/usr/bin/hdiutil verify "$release_dmg"
/usr/bin/xcrun stapler validate "$release_dmg"
/usr/sbin/spctl --assess --type open \
    --context context:primary-signature \
    --verbose=2 \
    "$release_dmg"

command -v gh >/dev/null || fail "install GitHub CLI"
command -v brew >/dev/null || fail "install Homebrew"
gh auth status >/dev/null || fail "sign in with GitHub CLI"
[[ "$tap_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
    fail "SNIP_SNAP_TAP_REPO must use owner/repo"

sparkle_tool="${SNIP_SNAP_GENERATE_APPCAST:-}"
if [[ -z "$sparkle_tool" ]]; then
    sparkle_tool="$(/usr/bin/find "$repo_dir" /private/tmp/snip-snap-derived-data \
        -type f -name generate_appcast -perm -111 2>/dev/null | /usr/bin/head -1)"
fi
[[ -x "$sparkle_tool" ]] || \
    fail "set SNIP_SNAP_GENERATE_APPCAST to Sparkle's generate_appcast tool"

temp_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-publish.XXXXXX)"
tap_checkout=""
dmg_attached=0
cleanup() {
    if (( dmg_attached )); then
        /usr/bin/hdiutil detach "$dmg_mount" >/dev/null 2>&1 || true
    fi
    [[ "$temp_root" == /private/tmp/snip-snap-publish.* ]] && /bin/rm -rf "$temp_root"
    if [[ "$tap_checkout" == */Library/Taps/*/homebrew-snip-snap-publish.* ]]; then
        /bin/rm -rf "$tap_checkout"
    fi
}
trap cleanup EXIT

feed_dir="$temp_root/feed"
release_checkout="$temp_root/snip-snap"
/bin/mkdir -p "$feed_dir"
gh repo clone "$release_repo" "$release_checkout" -- --quiet
tap_owner="${tap_repo%%/*}"
tap_parent="$(brew --repository)/Library/Taps/$tap_owner"
/bin/mkdir -p "$tap_parent"
tap_checkout="$(/usr/bin/mktemp -d "$tap_parent/homebrew-snip-snap-publish.XXXXXX")"
gh repo clone "$tap_repo" "$tap_checkout" -- --quiet

verification_dir="$temp_root/verify"
/bin/mkdir -p "$verification_dir"
/usr/bin/ditto -x -k "$release_zip" "$verification_dir"
release_policy_verify_app "$verification_dir/Snip Snap.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$verification_dir/Snip Snap.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$verification_dir/Snip Snap.app"

dmg_mount="$temp_root/dmg-mount"
/bin/mkdir -p "$dmg_mount"
/usr/bin/hdiutil attach \
    -nobrowse \
    -readonly \
    -mountpoint "$dmg_mount" \
    "$release_dmg" >/dev/null
dmg_attached=1
dmg_app="$dmg_mount/Snip Snap.app"
[[ -L "$dmg_mount/Applications" ]] || fail "DMG has no Applications link"
[[ "$(/usr/bin/readlink "$dmg_mount/Applications")" == /Applications ]] || \
    fail "DMG Applications link has the wrong target"
release_policy_verify_app "$dmg_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$dmg_app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$dmg_app"
release_policy_require_matching_apps \
    "$verification_dir/Snip Snap.app" \
    "$dmg_app"
/usr/bin/hdiutil detach "$dmg_mount" >/dev/null
dmg_attached=0

release_exists=0
if gh release view "v$version" --repo "$release_repo" >/dev/null 2>&1; then
    release_exists=1
    existing_release_dir="$temp_root/existing-release"
    /bin/mkdir -p "$existing_release_dir"
    gh release download "v$version" \
        --repo "$release_repo" \
        --pattern "Snip-Snap-$version.zip" \
        --dir "$existing_release_dir"
    gh release download "v$version" \
        --repo "$release_repo" \
        --pattern "Snip-Snap-$version.zip.sha256" \
        --dir "$existing_release_dir"
    gh release download "v$version" \
        --repo "$release_repo" \
        --pattern "Snip-Snap-$version.dmg" \
        --dir "$existing_release_dir"
    gh release download "v$version" \
        --repo "$release_repo" \
        --pattern "Snip-Snap-$version.dmg.sha256" \
        --dir "$existing_release_dir"
    release_policy_verify_checksum \
        "$existing_release_dir/Snip-Snap-$version.zip" \
        "$existing_release_dir/Snip-Snap-$version.zip.sha256" || \
        fail "GitHub v$version has a wrong checksum asset"
    release_policy_verify_checksum \
        "$existing_release_dir/Snip-Snap-$version.zip" \
        "$zip_checksum_file" || fail "GitHub v$version has different ZIP bytes"
    release_policy_verify_checksum \
        "$existing_release_dir/Snip-Snap-$version.dmg" \
        "$existing_release_dir/Snip-Snap-$version.dmg.sha256" || \
        fail "GitHub v$version has a wrong DMG checksum asset"
    release_policy_verify_checksum \
        "$existing_release_dir/Snip-Snap-$version.dmg" \
        "$dmg_checksum_file" || fail "GitHub v$version has different DMG bytes"
elif release_policy_remote_tag_exists "$repo_dir" "$version"; then
    fail "tag v$version exists without a matching GitHub release"
fi

/bin/cp -p "$release_zip" "$feed_dir/"
[[ ! -f "$release_checkout/appcast.xml" ]] || \
    /bin/cp -p "$release_checkout/appcast.xml" "$feed_dir/appcast.xml"

feed_notes="$feed_dir/Snip-Snap-$version.md"
if [[ -n "${SNIP_SNAP_RELEASE_NOTES_FILE:-}" ]]; then
    [[ -f "$SNIP_SNAP_RELEASE_NOTES_FILE" ]] || \
        fail "missing $SNIP_SNAP_RELEASE_NOTES_FILE"
    /bin/cp -p "$SNIP_SNAP_RELEASE_NOTES_FILE" "$feed_notes"
else
    print "Snip Snap $version" > "$feed_notes"
fi

if [[ -f "$release_checkout/appcast.xml" ]] &&
   release_policy_appcast_contains_release "$release_checkout/appcast.xml" >/dev/null 2>&1; then
    (( release_exists )) || fail "appcast already has $version ($build_number) without its release"
    expected_feed_dir="$temp_root/expected-feed"
    /bin/mkdir -p "$expected_feed_dir"
    /bin/cp -p "$release_zip" "$expected_feed_dir/"
    /bin/cp -p "$feed_notes" "$expected_feed_dir/"
    "$sparkle_tool" \
        --account "$sparkle_account" \
        --download-url-prefix "https://github.com/$release_repo/releases/download/v$version/" \
        --link "https://github.com/$release_repo/releases/tag/v$version" \
        --versions "$build_number" \
        "$expected_feed_dir"
    release_policy_require_matching_appcast_release \
        "$release_checkout/appcast.xml" \
        "$expected_feed_dir/appcast.xml"
else
    "$sparkle_tool" \
        --account "$sparkle_account" \
        --download-url-prefix "https://github.com/$release_repo/releases/download/v$version/" \
        --link "https://github.com/$release_repo/releases/tag/v$version" \
        --versions "$build_number" \
        "$feed_dir"
    release_policy_require_preserved_appcast_items \
        "$release_checkout/appcast.xml" \
        "$feed_dir/appcast.xml"
fi
release_policy_appcast_contains_release "$feed_dir/appcast.xml"

checksum="$(/usr/bin/awk 'NR == 1 { print $1 }' "$zip_checksum_file")"
cask_dir="$tap_checkout/Casks"
cask_path="$cask_dir/snip-snap.rb"
desired_cask="$temp_root/snip-snap.rb"
/usr/bin/sed \
    -e "s/@VERSION@/$version/g" \
    -e "s/@SHA256@/$checksum/g" \
    "$script_dir/snip-snap.rb.template" > "$desired_cask"
/usr/bin/ruby -c "$desired_cask" >/dev/null

if [[ -f "$cask_path" ]] &&
   /usr/bin/grep -q "version \"$version\"" "$cask_path" &&
   ! /usr/bin/cmp -s "$cask_path" "$desired_cask"; then
    fail "Homebrew cask $version already exists with different content"
fi
/bin/mkdir -p "$cask_dir"
/bin/cp "$desired_cask" "$cask_path"
brew style --cask "$cask_path"

if (( ! release_exists )); then
    gh release create "v$version" \
        "$release_zip" \
        "$zip_checksum_file" \
        "$release_dmg" \
        "$dmg_checksum_file" \
        --repo "$release_repo" \
        --target main \
        --title "Snip Snap $version" \
        --notes-file "$feed_notes"
fi

/bin/cp "$feed_dir/appcast.xml" "$release_checkout/appcast.xml"
/bin/cp "$feed_notes" "$release_checkout/Snip-Snap-$version.md"
if [[ -n "$(git -C "$release_checkout" status --short)" ]]; then
    git -C "$release_checkout" add appcast.xml "Snip-Snap-$version.md"
    git -C "$release_checkout" commit -m "Publish Snip Snap $version update"
    git -C "$release_checkout" push origin main
fi

if [[ -n "$(git -C "$tap_checkout" status --short)" ]]; then
    git -C "$tap_checkout" add Casks/snip-snap.rb
    git -C "$tap_checkout" commit -m "Publish Snip Snap $version cask"
    git -C "$tap_checkout" push origin main
fi

brew tap "$tap_name"
brew update

print "Published: https://github.com/$release_repo/releases/tag/v$version"
print "Sparkle feed: https://raw.githubusercontent.com/$release_repo/main/appcast.xml"
print "Install: brew install --cask $tap_name/snip-snap"
