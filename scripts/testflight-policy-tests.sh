#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source "$script_dir/testflight-policy.sh"

test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-testflight-policy-tests.XXXXXX)"
cleanup() {
    [[ "$test_root" == /private/tmp/snip-snap-testflight-policy-tests.* ]] && \
        /bin/rm -rf "$test_root"
}
trap cleanup EXIT

fail_test() {
    print -u2 "TestFlight policy test failed: $1"
    exit 1
}

assert_succeeds() {
    "$@" >/dev/null 2>&1 || fail_test "expected success: $*"
}

assert_fails_with() {
    local expected="$1"
    shift
    local output
    if output="$("$@" 2>&1)"; then
        fail_test "expected failure: $*"
    fi
    [[ "$output" == *"$expected"* ]] || \
        fail_test "missing failure item $expected"
}

archive="$test_root/SnipSnap-iOS.xcarchive"
app="$archive/Products/Applications/Snip Snap iOS.app"
share="$app/PlugIns/SnipSnapShareExtension.appex"
/bin/mkdir -p "$share" "$archive/dSYMs/Snip Snap iOS.app.dSYM"

write_info() {
    local path="$1"
    local bundle_identifier="$2"
    /usr/bin/plutil -create xml1 "$path"
    /usr/bin/plutil -insert CFBundleIdentifier -string "$bundle_identifier" "$path"
    /usr/bin/plutil -insert CFBundleShortVersionString -string 0.3.0 "$path"
    /usr/bin/plutil -insert CFBundleVersion -string 4 "$path"
}

write_entitlements() {
    local path="$1"
    local bundle_identifier="$2"
    /usr/bin/plutil -create xml1 "$path"
    /usr/bin/plutil -insert application-identifier \
        -string "PREFIX12345.$bundle_identifier" "$path"
    /usr/bin/plutil -insert 'com\.apple\.developer\.team-identifier' \
        -string FAKE123456 "$path"
    /usr/bin/plutil -insert 'com\.apple\.security\.application-groups' \
        -json '["group.org.example.snipsnap"]' "$path"
}

write_info "$app/Info.plist" org.example.snipsnap.ios
write_info "$share/Info.plist" org.example.snipsnap.ios.share
write_entitlements "$app/fake-entitlements.plist" org.example.snipsnap.ios
write_entitlements "$share/fake-entitlements.plist" org.example.snipsnap.ios.share
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-container-identifiers' \
    -json '["iCloud.org.example.snipsnap"]' "$app/fake-entitlements.plist"
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-services' \
    -json '["CloudKit"]' "$app/fake-entitlements.plist"
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-container-environment' \
    -string Production "$app/fake-entitlements.plist"
/bin/cp "$script_dir/../SnipSnapiOS/PrivacyInfo.xcprivacy" \
    "$app/PrivacyInfo.xcprivacy"
/bin/cp "$script_dir/../SnipSnapShareExtension/PrivacyInfo.xcprivacy" \
    "$share/PrivacyInfo.xcprivacy"

fake_codesign="$test_root/codesign"
print -r -- '#!/bin/zsh
set -euo pipefail
bundle="${@: -1}"
if [[ "$*" == *"--entitlements"* ]]; then
    /bin/cat "$bundle/fake-entitlements.plist"
fi' > "$fake_codesign"
/bin/chmod +x "$fake_codesign"
typeset -gx SNIP_SNAP_CODESIGN="$fake_codesign"

verify_archive() {
    testflight_policy_verify_archive \
        "$archive" \
        org.example.snipsnap.ios \
        org.example.snipsnap.ios.share \
        FAKE123456 \
        group.org.example.snipsnap \
        iCloud.org.example.snipsnap \
        0.3.0 \
        4
}

assert_succeeds verify_archive

/usr/bin/plutil -replace 'com\.apple\.developer\.icloud-container-environment' \
    -string Development "$app/fake-entitlements.plist"
assert_fails_with 'signed CloudKit Production environment' verify_archive
/usr/bin/plutil -replace 'com\.apple\.developer\.icloud-container-environment' \
    -string Production "$app/fake-entitlements.plist"

/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-services' \
    -json '["CloudKit"]' "$share/fake-entitlements.plist"
assert_fails_with 'Share extension without CloudKit' verify_archive
/usr/bin/plutil -remove 'com\.apple\.developer\.icloud-services' \
    "$share/fake-entitlements.plist"

/usr/bin/plutil -replace CFBundleVersion -string 5 "$share/Info.plist"
assert_fails_with 'bundle build number' verify_archive
/usr/bin/plutil -replace CFBundleVersion -string 4 "$share/Info.plist"

/bin/mv "$share/PrivacyInfo.xcprivacy" "$share/PrivacyInfo.saved"
assert_fails_with 'Share extension privacy manifest' verify_archive
/bin/mv "$share/PrivacyInfo.saved" "$share/PrivacyInfo.xcprivacy"

print 'not a plist' > "$share/PrivacyInfo.xcprivacy"
assert_fails_with 'valid Share extension privacy manifest' verify_archive
/bin/cp "$script_dir/../SnipSnapShareExtension/PrivacyInfo.xcprivacy" \
    "$share/PrivacyInfo.xcprivacy"

/usr/bin/plutil -replace \
    'NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons' \
    -json '[]' "$app/PrivacyInfo.xcprivacy"
assert_fails_with 'app UserDefaults privacy reason' verify_archive
/bin/cp "$script_dir/../SnipSnapiOS/PrivacyInfo.xcprivacy" \
    "$app/PrivacyInfo.xcprivacy"

source_record="$archive/SnipSnapSource.plist"
assert_succeeds testflight_policy_write_source_record \
    "$source_record" abc123 true
assert_succeeds testflight_policy_verify_source_record "$archive" abc123
assert_fails_with 'checked source commit' \
    testflight_policy_verify_source_record "$archive" def456
assert_succeeds testflight_policy_write_source_record \
    "$source_record" abc123 false
assert_fails_with 'dirty worktree' \
    testflight_policy_verify_source_record "$archive" abc123
assert_succeeds testflight_policy_require_unchanged_source \
    abc123 ' M one' abc123 ' M one'
assert_fails_with 'source changed while the archive was being built' \
    testflight_policy_require_unchanged_source \
        abc123 '' def456 ''
assert_fails_with 'source changed while the archive was being built' \
    testflight_policy_require_unchanged_source \
        abc123 '' abc123 ' M one'

export_options="$test_root/ExportOptions.plist"
assert_succeeds testflight_policy_write_export_options "$export_options" FAKE123456
[[ "$(/usr/bin/plutil -extract method raw -o - "$export_options")" == \
    app-store-connect ]] || fail_test "wrong export method"
[[ "$(/usr/bin/plutil -extract destination raw -o - "$export_options")" == upload ]] || \
    fail_test "wrong export destination"
[[ "$(/usr/bin/plutil -extract iCloudContainerEnvironment raw -o - \
    "$export_options")" == Production ]] || fail_test "wrong CloudKit environment"
[[ "$(/usr/bin/plutil -extract manageAppVersionAndBuildNumber raw -o - \
    "$export_options")" == false ]] || fail_test "Xcode may change the checked build number"
[[ "$(/usr/bin/plutil -extract testFlightInternalTestingOnly raw -o - \
    "$export_options")" == false ]] || fail_test "build was limited to internal testing"

print "TestFlight policy checks passed."
