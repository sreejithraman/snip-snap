#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
release_repo="${SNIP_SNAP_RELEASE_REPO:-sreejithraman/snip-snap}"
notary_profile="${SNIP_SNAP_NOTARY_PROFILE:-snip-snap-notary}"

source "$script_dir/release-policy.sh"
release_policy_preflight "$repo_dir" "$release_repo"
version="$RELEASE_VERSION"
build_number="$RELEASE_BUILD_NUMBER"

fail() {
    print -u2 "release: $1"
    exit 1
}

if ! /usr/bin/security find-identity -v -p codesigning | \
    /usr/bin/grep -q 'Developer ID Application'; then
    fail "install a valid Developer ID Application identity"
fi

release_root="${SNIP_SNAP_RELEASE_DIR:-$repo_dir/artifacts/release-$version-$build_number}"
[[ ! -e "$release_root" ]] || fail "$release_root already exists"

archive_path="$release_root/SnipSnap.xcarchive"
export_path="$release_root/export"
submission_name="Snip-Snap-build-$build_number-$version-submission.zip"
submission_zip="$release_root/$submission_name"
release_zip="$release_root/Snip-Snap-$version.zip"
app_path="$export_path/Snip Snap.app"

release_policy_require_new_notary_build "$notary_profile" "$build_number"
"$script_dir/test.sh"

/bin/mkdir -p "$release_root"

/usr/bin/xcodebuild \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme SnipSnap \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" \
    ARCHS='arm64 x86_64' \
    CODE_SIGN_IDENTITY='Developer ID Application' \
    CODE_SIGN_STYLE=Manual \
    CURRENT_PROJECT_VERSION="$build_number" \
    DEVELOPMENT_TEAM=K6239Y94G5 \
    MARKETING_VERSION="$version" \
    archive

/usr/bin/xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$script_dir/release-export-options.plist"

[[ -d "$app_path" ]] || fail "Xcode did not export Snip Snap.app"
release_policy_verify_app "$app_path"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_zip"

/usr/bin/xcrun notarytool submit "$submission_zip" \
    --keychain-profile "$notary_profile" \
    --wait

/usr/bin/xcrun stapler staple "$app_path"
/usr/bin/xcrun stapler validate "$app_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_zip"

/usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
/usr/bin/shasum -a 256 "$release_zip" | /usr/bin/tee "$release_zip.sha256"
release_policy_verify_checksum "$release_zip" "$release_zip.sha256"

print "Release ready: $release_zip"
print "Checksum: $release_zip.sha256"
