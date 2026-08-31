#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
source "$script_dir/signing-policy.sh"

test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-signing-policy.XXXXXX)"
cleanup() {
    [[ "$test_root" == /private/tmp/snip-snap-signing-policy.* ]] && /bin/rm -rf "$test_root"
}
trap cleanup EXIT

fail_test() {
    print -u2 "signing policy test failed: $1"
    exit 1
}

assert_succeeds() {
    "$@" >/dev/null 2>&1 || fail_test "expected success: $*"
}

assert_fails_with_all() {
    local output
    local expected
    local command="$1"
    shift
    if output="$(eval "$command" 2>&1)"; then
        fail_test "expected failure: $command"
    fi
    for expected in "$@"; do
        [[ "$output" == *"$expected"* ]] || \
            fail_test "missing failure item $expected"
    done
}

entitlements="$test_root/Fake.entitlements"
/usr/bin/plutil -create xml1 "$entitlements"
/usr/bin/plutil -insert 'com\.apple\.security\.application-groups' \
    -json '["group.org.example.snipsnap"]' "$entitlements"
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-container-identifiers' \
    -json '["iCloud.org.example.snipsnap"]' "$entitlements"
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-services' \
    -json '["CloudKit"]' "$entitlements"
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-container-environment' \
    -string Development "$entitlements"
complete="$test_root/complete-settings.txt"
print '    DEVELOPMENT_TEAM = FAKE123456' > "$complete"
print '    PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap' >> "$complete"
print '    SNIP_SNAP_APP_GROUP_IDENTIFIER = group.org.example.snipsnap' >> "$complete"
print '    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER = iCloud.org.example.snipsnap' >> "$complete"
print '    CODE_SIGN_ENTITLEMENTS = Fake.entitlements' >> "$complete"

share_entitlements_dir="$test_root/SnipSnapShareExtension"
/bin/mkdir -p "$share_entitlements_dir"
share_entitlements="$share_entitlements_dir/SnipSnapShareExtension.entitlements"
/usr/bin/plutil -create xml1 "$share_entitlements"
/usr/bin/plutil -insert 'com\.apple\.security\.application-groups' \
    -json '["$(SNIP_SNAP_APP_GROUP_IDENTIFIER)"]' "$share_entitlements"

assert_succeeds signing_policy_preflight cloud "$complete" "$test_root" SnipSnap
assert_succeeds signing_policy_preflight device "$complete" "$test_root" SnipSnapiOS

production_entitlements="$test_root/Production.entitlements"
/bin/cp "$entitlements" "$production_entitlements"
/usr/bin/plutil -replace 'com\.apple\.developer\.icloud-container-environment' \
    -string Production "$production_entitlements"
production_settings="$test_root/production-settings.txt"
/bin/cp "$complete" "$production_settings"
/usr/bin/sed -i '' 's/Fake.entitlements/Production.entitlements/' "$production_settings"
assert_fails_with_all \
    "signing_policy_preflight cloud '$production_settings' '$test_root' SnipSnap" \
    'CloudKit Development environment entitlement'
assert_succeeds signing_policy_preflight \
    testflight "$production_settings" "$test_root" SnipSnapiOS
assert_fails_with_all \
    "signing_policy_preflight testflight '$complete' '$test_root' SnipSnapiOS" \
    'CloudKit Production environment entitlement'

empty_entitlements="$test_root/Empty.entitlements"
/usr/bin/plutil -create xml1 "$empty_entitlements"
empty_settings="$test_root/empty-entitlements-settings.txt"
/bin/cp "$complete" "$empty_settings"
/usr/bin/sed -i '' 's/Fake.entitlements/Empty.entitlements/' "$empty_settings"
assert_fails_with_all \
    "signing_policy_preflight cloud '$empty_settings' '$test_root' SnipSnap" \
    'App Group entitlement' \
    'CloudKit container entitlement' \
    'CloudKit service entitlement'

wrong_entitlements="$test_root/Wrong.entitlements"
/usr/bin/plutil -create xml1 "$wrong_entitlements"
/usr/bin/plutil -insert 'com\.apple\.security\.application-groups' \
    -json '["group.org.example.other"]' "$wrong_entitlements"
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-container-identifiers' \
    -json '["iCloud.org.example.other"]' "$wrong_entitlements"
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-services' \
    -json '["CloudDocuments"]' "$wrong_entitlements"
wrong_settings="$test_root/wrong-entitlements-settings.txt"
/bin/cp "$complete" "$wrong_settings"
/usr/bin/sed -i '' 's/Fake.entitlements/Wrong.entitlements/' "$wrong_settings"
assert_fails_with_all \
    "signing_policy_preflight device '$wrong_settings' '$test_root' SnipSnapiOS" \
    'App Group entitlement' \
    'CloudKit container entitlement' \
    'CloudKit service entitlement'

corrupt_entitlements="$test_root/Corrupt.entitlements"
print 'not a plist' > "$corrupt_entitlements"
corrupt_settings="$test_root/corrupt-entitlements-settings.txt"
/bin/cp "$complete" "$corrupt_settings"
/usr/bin/sed -i '' 's/Fake.entitlements/Corrupt.entitlements/' "$corrupt_settings"
assert_fails_with_all \
    "signing_policy_preflight cloud '$corrupt_settings' '$test_root' SnipSnap" \
    'valid entitlement plist'

fake_xcodebuild="$test_root/fake-xcodebuild"
fake_xcodebuild_args="$test_root/fake-xcodebuild-args"
print -r -- '#!/bin/zsh
print -r -- "$@" >> "$SNIP_SNAP_FAKE_XCODEBUILD_ARGS"
target=SnipSnapiOS
for (( index = 1; index <= $#; index++ )); do
    if [[ "${@[$index]}" == -target ]]; then
        next=$(( index + 1 ))
        target="${@[$next]}"
    fi
done
print -r -- "Build settings for action build and target $target:"
print -r -- "    DEVELOPMENT_TEAM = FAKE123456"
if [[ "$target" == SnipSnapShareExtension ]]; then
    print -r -- "    PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap.ios.share"
    print -r -- "    CODE_SIGN_ENTITLEMENTS = SnipSnapShareExtension/SnipSnapShareExtension.entitlements"
else
    print -r -- "    PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap.ios"
    print -r -- "    CODE_SIGN_ENTITLEMENTS = $SNIP_SNAP_FAKE_ENTITLEMENTS"
fi
print -r -- "    SNIP_SNAP_APP_GROUP_IDENTIFIER = group.org.example.snipsnap"
print -r -- "    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER = iCloud.org.example.snipsnap"
print -r -- "    SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap"' > \
    "$fake_xcodebuild"
/bin/chmod +x "$fake_xcodebuild"
SNIP_SNAP_XCODEBUILD="$fake_xcodebuild" \
SNIP_SNAP_FAKE_XCODEBUILD_ARGS="$fake_xcodebuild_args" \
SNIP_SNAP_FAKE_ENTITLEMENTS="$entitlements" \
    assert_succeeds "$script_dir/signed-lane-preflight.sh" cloud \
        --scheme SnipSnapiOS \
        --configuration Debug \
        --destination 'generic/platform=iOS'
/usr/bin/grep -F -- '-scheme SnipSnapiOS' "$fake_xcodebuild_args" >/dev/null || \
    fail_test "the signed-lane scheme did not reach xcodebuild"

SNIP_SNAP_XCODEBUILD="$fake_xcodebuild" \
SNIP_SNAP_FAKE_XCODEBUILD_ARGS="$fake_xcodebuild_args" \
SNIP_SNAP_FAKE_ENTITLEMENTS="$production_entitlements" \
SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS="$production_entitlements" \
    assert_succeeds "$script_dir/signed-lane-preflight.sh" testflight \
        --scheme SnipSnapiOS \
        --configuration Release \
        --destination 'generic/platform=iOS'
/usr/bin/grep -F -- \
    "SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS=$production_entitlements" \
    "$fake_xcodebuild_args" >/dev/null || \
    fail_test "the TestFlight entitlement input did not reach xcodebuild"

incomplete_cloud="$test_root/incomplete-cloud.txt"
print '    PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap' > "$incomplete_cloud"
assert_fails_with_all \
    "signing_policy_preflight cloud '$incomplete_cloud' '$test_root'" \
    DEVELOPMENT_TEAM \
    SNIP_SNAP_APP_GROUP_IDENTIFIER \
    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER \
    CODE_SIGN_ENTITLEMENTS
assert_fails_with_all \
    "signing_policy_preflight device '$incomplete_cloud' '$test_root'" \
    DEVELOPMENT_TEAM \
    SNIP_SNAP_APP_GROUP_IDENTIFIER \
    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER \
    CODE_SIGN_ENTITLEMENTS
assert_fails_with_all \
    "signing_policy_preflight testflight '$incomplete_cloud' '$test_root' SnipSnapiOS" \
    DEVELOPMENT_TEAM \
    SNIP_SNAP_APP_GROUP_IDENTIFIER \
    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER \
    CODE_SIGN_ENTITLEMENTS

missing_entitlements="$test_root/missing-entitlements.txt"
/bin/cp "$complete" "$missing_entitlements"
/usr/bin/sed -i '' 's/Fake.entitlements/Missing.entitlements/' "$missing_entitlements"
assert_fails_with_all \
    "signing_policy_preflight cloud '$missing_entitlements' '$test_root'" \
    'CODE_SIGN_ENTITLEMENTS file'

release_settings="$test_root/release-settings.txt"
print '    DEVELOPMENT_TEAM = FAKE123456' > "$release_settings"
print '    PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap' >> "$release_settings"
print '    CODE_SIGN_ENTITLEMENTS =' >> "$release_settings"
SNIP_SNAP_SIGNING_IDENTITY='FAKE Developer ID identity' \
SNIP_SNAP_NOTARY_PROFILE='FAKE notary profile' \
    assert_succeeds signing_policy_preflight release "$release_settings" "$test_root"

incomplete_release="$test_root/incomplete-release.txt"
print '    PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap' > "$incomplete_release"
unset SNIP_SNAP_SIGNING_IDENTITY SNIP_SNAP_NOTARY_PROFILE || true
assert_fails_with_all \
    "signing_policy_preflight release '$incomplete_release' '$test_root'" \
    DEVELOPMENT_TEAM \
    SNIP_SNAP_SIGNING_IDENTITY \
    SNIP_SNAP_NOTARY_PROFILE

resolved_override="$test_root/resolved-override.txt"
print '    DEVELOPMENT_TEAM =' > "$resolved_override"
print '    DEVELOPMENT_TEAM = FAKE123456' >> "$resolved_override"
[[ "$(signing_policy_resolve_setting "$resolved_override" DEVELOPMENT_TEAM)" == \
    FAKE123456 ]] || fail_test "the last resolved override did not win"

multi_target="$test_root/multi-target-settings.txt"
print 'Build settings for action build and target SnipSnapiOS:' > "$multi_target"
print '    CODE_SIGN_ENTITLEMENTS = Fake.entitlements' >> "$multi_target"
print 'Build settings for action build and target SnipSnapShareExtension:' >> "$multi_target"
print '    CODE_SIGN_ENTITLEMENTS = SnipSnapShareExtension/SnipSnapShareExtension.entitlements' \
    >> "$multi_target"
[[ "$(signing_policy_resolve_setting \
    "$multi_target" CODE_SIGN_ENTITLEMENTS SnipSnapiOS)" == Fake.entitlements ]] || \
    fail_test "the app target resolved the Share extension entitlement file"
[[ "$(signing_policy_resolve_setting \
    "$multi_target" CODE_SIGN_ENTITLEMENTS SnipSnapShareExtension)" == \
    SnipSnapShareExtension/SnipSnapShareExtension.entitlements ]] || \
    fail_test "the Share extension target did not resolve its own entitlement file"

multi_target_complete="$test_root/multi-target-complete.txt"
print 'Build settings for action build and target SnipSnapiOS:' > "$multi_target_complete"
/usr/bin/sed -n '/^[[:space:]]/p' "$complete" >> "$multi_target_complete"
print 'Build settings for action build and target SnipSnapShareExtension:' \
    >> "$multi_target_complete"
print '    CODE_SIGN_ENTITLEMENTS = SnipSnapShareExtension/SnipSnapShareExtension.entitlements' \
    >> "$multi_target_complete"
print '    SNIP_SNAP_APP_GROUP_IDENTIFIER = group.org.example.snipsnap' \
    >> "$multi_target_complete"
assert_succeeds signing_policy_preflight \
    device "$multi_target_complete" "$test_root" SnipSnapiOS

mismatched_share_group="$test_root/mismatched-share-group.txt"
/bin/cp "$multi_target_complete" "$mismatched_share_group"
/usr/bin/sed -i '' '$s/group\.org\.example\.snipsnap/group.org.example.other/' \
    "$mismatched_share_group"
assert_fails_with_all \
    "signing_policy_preflight device '$mismatched_share_group' '$test_root' SnipSnapiOS" \
    'Share extension App Group build setting'

missing_share_target="$test_root/missing-share-target.txt"
print 'Build settings for action build and target SnipSnapiOS:' > "$missing_share_target"
/usr/bin/sed -n '/^[[:space:]]/p' "$complete" >> "$missing_share_target"
print 'Build settings for action build and target SnipSnapShareExtension:' \
    >> "$missing_share_target"
assert_fails_with_all \
    "signing_policy_preflight device '$missing_share_target' '$test_root' SnipSnapiOS" \
    'Share extension CODE_SIGN_ENTITLEMENTS'

export_options="$test_root/export-options.plist"
assert_succeeds signing_policy_write_export_options "$export_options" FAKE123456
[[ "$(/usr/bin/plutil -extract teamID raw -o - "$export_options")" == FAKE123456 ]] || \
    fail_test "runtime export options missed the team"
[[ "$(/usr/bin/plutil -extract signingStyle raw -o - "$export_options")" == manual ]] || \
    fail_test "runtime export options missed manual signing"

/usr/bin/grep -F '#include? "Local.xcconfig"' \
    "$repo_dir/Config/Debug.xcconfig" \
    "$repo_dir/Config/Release.xcconfig" >/dev/null || \
    fail_test "the optional local override is not wired"
[[ -z "$(/usr/bin/sed -nE \
    's/^[[:space:]]*DEVELOPMENT_TEAM = (.*)$/\1/p' \
    "$repo_dir/Config/Shared.xcconfig")" ]] || \
    fail_test "the shared team default is not blank"
/usr/bin/grep -F 'CODE_SIGN_ENTITLEMENTS =' \
    "$repo_dir/Config/Debug.xcconfig" >/dev/null || \
    fail_test "Debug does not clear entitlements"

print "Signing policy checks passed."
