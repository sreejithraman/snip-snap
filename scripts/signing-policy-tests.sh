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
print '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$entitlements"
complete="$test_root/complete-settings.txt"
print '    DEVELOPMENT_TEAM = FAKE123456' > "$complete"
print '    PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap' >> "$complete"
print '    SNIP_SNAP_APP_GROUP_IDENTIFIER = group.org.example.snipsnap' >> "$complete"
print '    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER = iCloud.org.example.snipsnap' >> "$complete"
print '    CODE_SIGN_ENTITLEMENTS = Fake.entitlements' >> "$complete"

assert_succeeds signing_policy_preflight cloud "$complete" "$test_root"
assert_succeeds signing_policy_preflight device "$complete" "$test_root"

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
