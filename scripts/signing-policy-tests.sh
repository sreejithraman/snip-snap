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
/usr/bin/plutil -insert aps-environment -string development "$entitlements"
/usr/bin/plutil -insert 'com\.apple\.developer\.aps-environment' \
    -string development "$entitlements"
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
/usr/bin/plutil -replace aps-environment -string production "$production_entitlements"
/usr/bin/plutil -replace 'com\.apple\.developer\.aps-environment' \
    -string production "$production_entitlements"
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
    'CloudKit service entitlement' \
    'Apple Push Notification environment entitlement'

wrong_entitlements="$test_root/Wrong.entitlements"
/usr/bin/plutil -create xml1 "$wrong_entitlements"
/usr/bin/plutil -insert 'com\.apple\.security\.application-groups' \
    -json '["group.org.example.other"]' "$wrong_entitlements"
wrong_cloudkit_container="iCloud.""org.example.other"
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-container-identifiers' \
    -json "[\"$wrong_cloudkit_container\"]" "$wrong_entitlements"
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
/bin/cp "$production_settings" "$release_settings"
SNIP_SNAP_SIGNING_IDENTITY='FAKE Developer ID identity' \
SNIP_SNAP_NOTARY_PROFILE='FAKE notary profile' \
SNIP_SNAP_MAC_PROVISIONING_PROFILE_SPECIFIER='Fake Developer ID Profile' \
    assert_succeeds signing_policy_preflight release "$release_settings" "$test_root"
SNIP_SNAP_SIGNING_IDENTITY='FAKE Developer ID identity' \
SNIP_SNAP_NOTARY_PROFILE='FAKE notary profile' \
SNIP_SNAP_MAC_PROVISIONING_PROFILE_SPECIFIER='Fake Developer ID Profile' \
    assert_fails_with_all \
        "signing_policy_preflight release '$complete' '$test_root'" \
        'CloudKit Production environment entitlement'

incomplete_release="$test_root/incomplete-release.txt"
print '    PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap' > "$incomplete_release"
unset SNIP_SNAP_SIGNING_IDENTITY SNIP_SNAP_NOTARY_PROFILE || true
assert_fails_with_all \
    "signing_policy_preflight release '$incomplete_release' '$test_root'" \
    DEVELOPMENT_TEAM \
    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER \
    CODE_SIGN_ENTITLEMENTS \
    SNIP_SNAP_SIGNING_IDENTITY \
    SNIP_SNAP_NOTARY_PROFILE \
    SNIP_SNAP_MAC_PROVISIONING_PROFILE_SPECIFIER

signed_app="$test_root/Snip Snap.app"
/bin/mkdir -p "$signed_app/Contents"
print 'fake profile' > "$signed_app/Contents/embedded.provisionprofile"
signed_entitlements="$test_root/signed-entitlements.plist"
/bin/cp "$production_entitlements" "$signed_entitlements"
signed_profile="$test_root/signed-profile.plist"
/usr/bin/plutil -create xml1 "$signed_profile"
/usr/bin/plutil -insert TeamIdentifier -json '["FAKE123456"]' "$signed_profile"
/usr/bin/plutil -insert ApplicationIdentifierPrefix -json '["PREFIX987"]' "$signed_profile"
/usr/bin/plutil -insert ExpirationDate -date '2099-01-01T00:00:00Z' "$signed_profile"
/usr/bin/plutil -insert Entitlements -json '{}' "$signed_profile"
/usr/bin/plutil -insert 'Entitlements.com\.apple\.application-identifier' \
    -string PREFIX987.org.example.snipsnap "$signed_profile"
/usr/bin/plutil -insert 'Entitlements.com\.apple\.developer\.icloud-container-identifiers' \
    -json '["iCloud.org.example.snipsnap"]' "$signed_profile"
/usr/bin/plutil -insert 'Entitlements.com\.apple\.developer\.icloud-services' \
    -json '["CloudKit"]' "$signed_profile"
/usr/bin/plutil -insert 'Entitlements.com\.apple\.developer\.icloud-container-environment' \
    -string Production "$signed_profile"
/usr/bin/plutil -insert 'Entitlements.com\.apple\.developer\.aps-environment' \
    -string production "$signed_profile"
fake_codesign="$test_root/fake-codesign"
print -r -- '#!/bin/zsh
set -euo pipefail
if [[ "$*" == *"--entitlements"* ]]; then
    /bin/cat "$SNIP_SNAP_FAKE_SIGNED_ENTITLEMENTS"
fi' > "$fake_codesign"
/bin/chmod +x "$fake_codesign"
fake_security="$test_root/fake-security"
print -r -- '#!/bin/zsh
/bin/cat "$SNIP_SNAP_FAKE_PROFILE"' > "$fake_security"
/bin/chmod +x "$fake_security"
verify_profile_command="SNIP_SNAP_SECURITY='$fake_security' SNIP_SNAP_FAKE_PROFILE='$signed_profile' SNIP_SNAP_CODESIGN='$fake_codesign' SNIP_SNAP_FAKE_SIGNED_ENTITLEMENTS='$signed_entitlements' signing_policy_verify_production_cloudkit_app '$signed_app' iCloud.org.example.snipsnap FAKE123456 org.example.snipsnap"
SNIP_SNAP_CODESIGN="$fake_codesign" \
SNIP_SNAP_SECURITY="$fake_security" \
SNIP_SNAP_FAKE_SIGNED_ENTITLEMENTS="$signed_entitlements" \
SNIP_SNAP_FAKE_PROFILE="$signed_profile" \
    assert_succeeds signing_policy_verify_production_cloudkit_app \
        "$signed_app" iCloud.org.example.snipsnap FAKE123456 org.example.snipsnap
/usr/bin/plutil -replace 'Entitlements.com\.apple\.developer\.icloud-services' \
    -string '*' "$signed_profile"
SNIP_SNAP_CODESIGN="$fake_codesign" \
SNIP_SNAP_SECURITY="$fake_security" \
SNIP_SNAP_FAKE_SIGNED_ENTITLEMENTS="$signed_entitlements" \
SNIP_SNAP_FAKE_PROFILE="$signed_profile" \
    assert_succeeds signing_policy_verify_production_cloudkit_app \
        "$signed_app" iCloud.org.example.snipsnap FAKE123456 org.example.snipsnap
/usr/bin/plutil -replace 'Entitlements.com\.apple\.developer\.icloud-services' \
    -string CloudDocuments "$signed_profile"
assert_fails_with_all "$verify_profile_command" 'profile CloudKit service'
/usr/bin/plutil -replace 'Entitlements.com\.apple\.developer\.icloud-services' \
    -json '["CloudKit"]' "$signed_profile"
/bin/rm "$signed_app/Contents/embedded.provisionprofile"
assert_fails_with_all "$verify_profile_command" 'embedded Developer ID provisioning profile'
print 'fake profile' > "$signed_app/Contents/embedded.provisionprofile"
/usr/bin/plutil -replace TeamIdentifier -json '["FAKEWRONG1"]' "$signed_profile"
assert_fails_with_all "$verify_profile_command" 'profile team identifier'
/usr/bin/plutil -replace TeamIdentifier -json '["FAKE123456"]' "$signed_profile"
/usr/bin/plutil -replace 'Entitlements.com\.apple\.application-identifier' \
    -string PREFIX987.org.example.other "$signed_profile"
assert_fails_with_all "$verify_profile_command" 'profile application identifier'
/usr/bin/plutil -replace 'Entitlements.com\.apple\.application-identifier' \
    -string PREFIX987.org.example.snipsnap "$signed_profile"
/usr/bin/plutil -replace 'Entitlements.com\.apple\.developer\.icloud-container-identifiers' \
    -json '[]' "$signed_profile"
assert_fails_with_all "$verify_profile_command" 'profile CloudKit container'
/usr/bin/plutil -replace 'Entitlements.com\.apple\.developer\.icloud-container-identifiers' \
    -json '["iCloud.org.example.snipsnap"]' "$signed_profile"
/usr/bin/plutil -replace 'Entitlements.com\.apple\.developer\.icloud-container-environment' \
    -string Development "$signed_profile"
assert_fails_with_all "$verify_profile_command" 'profile CloudKit Production environment'
/usr/bin/plutil -replace 'Entitlements.com\.apple\.developer\.icloud-container-environment' \
    -string Production "$signed_profile"
/usr/bin/plutil -replace 'Entitlements.com\.apple\.developer\.aps-environment' \
    -string development "$signed_profile"
assert_fails_with_all "$verify_profile_command" \
    'profile Apple Push Notification production environment'
/usr/bin/plutil -replace 'Entitlements.com\.apple\.developer\.aps-environment' \
    -string production "$signed_profile"
/usr/bin/plutil -replace ExpirationDate -date '2000-01-01T00:00:00Z' "$signed_profile"
assert_fails_with_all "$verify_profile_command" 'unexpired provisioning profile'
/usr/bin/plutil -replace ExpirationDate -date '2099-01-01T00:00:00Z' "$signed_profile"
wrong_signed_cloudkit_container="iCloud.""org.example.other"
/usr/bin/plutil -replace 'com\.apple\.developer\.icloud-container-identifiers' \
    -json "[\"$wrong_signed_cloudkit_container\"]" "$signed_entitlements"
SNIP_SNAP_CODESIGN="$fake_codesign" \
SNIP_SNAP_SECURITY="$fake_security" \
SNIP_SNAP_FAKE_SIGNED_ENTITLEMENTS="$signed_entitlements" \
SNIP_SNAP_FAKE_PROFILE="$signed_profile" \
    assert_fails_with_all \
        "SNIP_SNAP_SECURITY='$fake_security' SNIP_SNAP_FAKE_PROFILE='$signed_profile' SNIP_SNAP_CODESIGN='$fake_codesign' SNIP_SNAP_FAKE_SIGNED_ENTITLEMENTS='$signed_entitlements' signing_policy_verify_production_cloudkit_app '$signed_app' iCloud.org.example.snipsnap FAKE123456 org.example.snipsnap" \
        'signed CloudKit container'
/usr/bin/plutil -replace 'com\.apple\.developer\.icloud-container-identifiers' \
    -json '["iCloud.org.example.snipsnap"]' "$signed_entitlements"
/usr/bin/plutil -replace 'com\.apple\.developer\.icloud-container-environment' \
    -string Development "$signed_entitlements"
SNIP_SNAP_CODESIGN="$fake_codesign" \
SNIP_SNAP_SECURITY="$fake_security" \
SNIP_SNAP_FAKE_SIGNED_ENTITLEMENTS="$signed_entitlements" \
SNIP_SNAP_FAKE_PROFILE="$signed_profile" \
    assert_fails_with_all \
        "SNIP_SNAP_SECURITY='$fake_security' SNIP_SNAP_FAKE_PROFILE='$signed_profile' SNIP_SNAP_CODESIGN='$fake_codesign' SNIP_SNAP_FAKE_SIGNED_ENTITLEMENTS='$signed_entitlements' signing_policy_verify_production_cloudkit_app '$signed_app' iCloud.org.example.snipsnap FAKE123456 org.example.snipsnap" \
        'signed CloudKit Production environment'
/usr/bin/plutil -replace 'com\.apple\.developer\.icloud-container-environment' \
    -string Production "$signed_entitlements"
/usr/bin/plutil -replace 'com\.apple\.developer\.aps-environment' \
    -string development "$signed_entitlements"
SNIP_SNAP_CODESIGN="$fake_codesign" \
SNIP_SNAP_SECURITY="$fake_security" \
SNIP_SNAP_FAKE_SIGNED_ENTITLEMENTS="$signed_entitlements" \
SNIP_SNAP_FAKE_PROFILE="$signed_profile" \
    assert_fails_with_all \
        "SNIP_SNAP_SECURITY='$fake_security' SNIP_SNAP_FAKE_PROFILE='$signed_profile' SNIP_SNAP_CODESIGN='$fake_codesign' SNIP_SNAP_FAKE_SIGNED_ENTITLEMENTS='$signed_entitlements' signing_policy_verify_production_cloudkit_app '$signed_app' iCloud.org.example.snipsnap FAKE123456 org.example.snipsnap" \
        'signed Apple Push Notification production environment'

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
assert_succeeds signing_policy_write_export_options \
    "$export_options" FAKE123456 org.example.snipsnap 'Fake Developer ID Profile'
[[ "$(/usr/bin/plutil -extract teamID raw -o - "$export_options")" == FAKE123456 ]] || \
    fail_test "runtime export options missed the team"
[[ "$(/usr/bin/plutil -extract signingStyle raw -o - "$export_options")" == manual ]] || \
    fail_test "runtime export options missed manual signing"
[[ "$(/usr/bin/plutil -extract 'provisioningProfiles.org\.example\.snipsnap' raw -o - \
    "$export_options")" == 'Fake Developer ID Profile' ]] || \
    fail_test "runtime export options missed the Developer ID profile"

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
/usr/bin/plutil -lint "$repo_dir/Config/MacRelease.example.entitlements" >/dev/null || \
    fail_test "the Mac release entitlement template is not valid"
[[ "$(/usr/bin/plutil -extract \
    'com\.apple\.developer\.icloud-container-environment' raw -o - \
    "$repo_dir/Config/MacRelease.example.entitlements")" == Production ]] || \
    fail_test "the Mac release entitlement template is not Production"
[[ "$(/usr/bin/plutil -extract \
    'com\.apple\.developer\.aps-environment' raw -o - \
    "$repo_dir/Config/MacRelease.example.entitlements")" == production ]] || \
    fail_test "the Mac release entitlement template has no production push environment"
/usr/bin/grep -F '/Config/MacRelease.entitlements' "$repo_dir/.gitignore" >/dev/null || \
    fail_test "the local Mac release entitlement file is not ignored"
for required in \
    'SNIP_SNAP_MAC_RELEASE_ENTITLEMENTS' \
    'SNIP_SNAP_MAC_PROVISIONING_PROFILE_SPECIFIER' \
    'PROVISIONING_PROFILE_SPECIFIER="$provisioning_profile_specifier"' \
    'CODE_SIGN_ENTITLEMENTS="$mac_release_entitlements"' \
    'SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER="$cloudkit_container_identifier"'; do
    /usr/bin/grep -F -- "$required" "$script_dir/release.sh" >/dev/null || \
        fail_test "the Mac release command is missing $required"
done
[[ "$(/usr/bin/grep -c \
    'signing_policy_verify_production_cloudkit_app' "$script_dir/release.sh")" == 2 ]] || \
    fail_test "the Mac release command must verify the archive and export"
verify_lines=( ${(@f)$(/usr/bin/grep -n '^    verify_release_cloudkit$' \
    "$script_dir/release.sh" | /usr/bin/cut -d: -f1)} )
[[ "${#verify_lines[@]}" == 2 ]] || \
    fail_test "the Mac release command must gate fresh and resumed releases"
history_line="$(/usr/bin/grep -n 'history_json=' "$script_dir/release.sh" | \
    /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
dmg_line="$(/usr/bin/grep -n '/usr/bin/hdiutil create' "$script_dir/release.sh" | \
    /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
(( verify_lines[1] < history_line )) || \
    fail_test "the resumed release checks CloudKit after notarization work starts"
(( verify_lines[2] < dmg_line )) || \
    fail_test "the fresh release checks CloudKit after the release image is made"

print "Signing policy checks passed."
