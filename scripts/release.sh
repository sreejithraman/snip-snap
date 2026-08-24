#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
release_repo="${SNIP_SNAP_RELEASE_REPO:-sreejithraman/snip-snap}"
notary_profile="${SNIP_SNAP_NOTARY_PROFILE:-snip-snap-notary}"
signing_identity="${SNIP_SNAP_SIGNING_IDENTITY:-}"

source "$script_dir/release-policy.sh"
release_policy_preflight "$repo_dir" "$release_repo"
version="$RELEASE_VERSION"
build_number="$RELEASE_BUILD_NUMBER"

fail() {
    print -u2 "release: $1"
    exit 1
}

if [[ -z "$signing_identity" ]]; then
    signing_identity="$(/usr/bin/security find-identity -v -p codesigning | \
        /usr/bin/awk '/Developer ID Application/ && /\(K6239Y94G5\)/ { print $2; exit }')"
fi
[[ -n "$signing_identity" ]] || fail "install the team Developer ID Application identity"

release_root="${SNIP_SNAP_RELEASE_DIR:-$repo_dir/artifacts/release-$version-$build_number}"
archive_path="$release_root/SnipSnap.xcarchive"
export_path="$release_root/export"
submission_name="Snip-Snap-build-$build_number-$version-submission.dmg"
submission_dmg="$release_root/$submission_name"
release_zip="$release_root/Snip-Snap-$version.zip"
release_dmg="$release_root/Snip-Snap-$version.dmg"
app_path="$export_path/Snip Snap.app"
dmg_source="$release_root/dmg-source"

"$script_dir/test.sh"

if [[ -e "$release_root" &&
      ( ! -f "$submission_dmg" || ! -d "$app_path" ) ]]; then
    release_policy_require_new_notary_build "$notary_profile" "$build_number"
    incomplete_root="$release_root.incomplete-$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
    /bin/mv "$release_root" "$incomplete_root"
    print "Kept the incomplete release at $incomplete_root."
fi

if [[ -e "$release_root" ]]; then
    [[ -d "$release_root" ]] || fail "$release_root is not a directory"

    history_json="$(/usr/bin/xcrun notarytool history \
        --keychain-profile "$notary_profile" \
        --output-format json)" || fail "could not read Apple notarization history"
    if submission_entry="$(release_policy_notary_submission_entry \
        "$history_json" \
        "$submission_name")"; then
        submission_id="${submission_entry%%$'\t'*}"
        submission_status="${submission_entry#*$'\t'}"
        case "$submission_status" in
            Accepted)
                print "Resuming accepted Apple submission $submission_name."
                ;;
            "In Progress")
                wait_json="$(/usr/bin/xcrun notarytool wait "$submission_id" \
                    --keychain-profile "$notary_profile" \
                    --output-format json)" || fail "could not wait for $submission_name"
                wait_status="$(print -r -- "$wait_json" | /usr/bin/ruby -rjson -e \
                    'puts JSON.parse(STDIN.read).fetch("status")')" || \
                    fail "could not read Apple status for $submission_name"
                [[ "$wait_status" == Accepted ]] || \
                    fail "Apple submission $submission_name is $wait_status"
                ;;
            *)
                fail "Apple submission $submission_name is $submission_status"
                ;;
        esac
    else
        release_policy_require_new_notary_build "$notary_profile" "$build_number"
        release_policy_verify_app "$app_path"
        /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
        /usr/bin/codesign --verify --verbose=2 "$submission_dmg"
        /usr/bin/hdiutil verify "$submission_dmg"
        /usr/bin/xcrun notarytool submit "$submission_dmg" \
            --keychain-profile "$notary_profile" \
            --wait
    fi
else
    release_policy_require_new_notary_build "$notary_profile" "$build_number"
    /bin/mkdir -p "$release_root"

    /usr/bin/xcodebuild \
        -project "$repo_dir/SnipSnap.xcodeproj" \
        -scheme SnipSnap \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$archive_path" \
        ARCHS='arm64 x86_64' \
        CODE_SIGN_IDENTITY="$signing_identity" \
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
    /bin/mkdir -p "$dmg_source"
    /usr/bin/ditto "$app_path" "$dmg_source/Snip Snap.app"
    /bin/ln -s /Applications "$dmg_source/Applications"
    /usr/bin/hdiutil create \
        -volname "Snip Snap" \
        -srcfolder "$dmg_source" \
        -format UDZO \
        "$submission_dmg"
    /usr/bin/codesign \
        --sign "$signing_identity" \
        --timestamp \
        "$submission_dmg"
    /usr/bin/codesign --verify --verbose=2 "$submission_dmg"
    /usr/bin/hdiutil verify "$submission_dmg"

    /usr/bin/xcrun notarytool submit "$submission_dmg" \
        --keychain-profile "$notary_profile" \
        --wait
fi

[[ -d "$app_path" ]] || fail "Xcode did not export Snip Snap.app"
release_policy_verify_app "$app_path"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/usr/bin/codesign --verify --verbose=2 "$submission_dmg"
/usr/bin/hdiutil verify "$submission_dmg"

if ! /usr/bin/xcrun stapler validate "$submission_dmg" >/dev/null 2>&1; then
    /usr/bin/xcrun stapler staple "$submission_dmg"
fi
/usr/bin/xcrun stapler validate "$submission_dmg"
if ! /usr/bin/xcrun stapler validate "$app_path" >/dev/null 2>&1; then
    /usr/bin/xcrun stapler staple "$app_path"
fi
/usr/bin/xcrun stapler validate "$app_path"
/bin/cp -p "$submission_dmg" "$release_dmg"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_zip"

/usr/bin/hdiutil verify "$release_dmg"
/usr/sbin/spctl --assess --type open \
    --context context:primary-signature \
    --verbose=2 \
    "$release_dmg"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
/usr/bin/shasum -a 256 "$release_dmg" | /usr/bin/tee "$release_dmg.sha256"
/usr/bin/shasum -a 256 "$release_zip" | /usr/bin/tee "$release_zip.sha256"
release_policy_verify_checksum "$release_dmg" "$release_dmg.sha256"
release_policy_verify_checksum "$release_zip" "$release_zip.sha256"

print "Website release: $release_dmg"
print "Website checksum: $release_dmg.sha256"
print "Update release: $release_zip"
print "Update checksum: $release_zip.sha256"
