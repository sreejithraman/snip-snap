#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-tracked-policy.XXXXXX)"
cleanup() {
    [[ "$test_root" == /private/tmp/snip-snap-tracked-policy.* ]] && /bin/rm -rf "$test_root"
}
trap cleanup EXIT

fail_test() {
    print -u2 "tracked-input policy test failed: $1"
    exit 1
}

new_repo() {
    local name="$1"
    local repo="$test_root/$name"
    /bin/mkdir -p "$repo"
    git -C "$repo" init -q
    print -r -- "$repo"
}

safe_repo="$(new_repo safe)"
print -r -- 'DEVELOPMENT_TEAM = FAKE123456' > "$safe_repo/fake-settings.xcconfig"
print -r -- 'PRODUCT_BUNDLE_IDENTIFIER = org.example.open-source-app' >> "$safe_repo/fake-settings.xcconfig"
print -r -- 'SNIP_SNAP_APP_GROUP_IDENTIFIER = group.org.example.snipsnap' >> "$safe_repo/fake-settings.xcconfig"
print -r -- 'SNIP_SNAP_CLOUD_DEV_APP_GROUP_IDENTIFIER = group.org.example.snipsnap.clouddev' >> "$safe_repo/fake-settings.xcconfig"
print -r -- 'SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER = iCloud.org.example.open-source-app' >> "$safe_repo/fake-settings.xcconfig"
print -r -- '/private/tmp/open-source-build' >> "$safe_repo/fake-settings.xcconfig"
print -r -- '<string>$(SNIP_SNAP_APP_GROUP_IDENTIFIER)</string>' > \
    "$safe_repo/fake.entitlements"
git -C "$safe_repo" add fake-settings.xcconfig fake.entitlements
"$script_dir/tracked-input-policy.sh" "$safe_repo" >/dev/null || \
    fail_test "safe public and fake values were rejected"

assert_rejected_without_value() {
    local name="$1"
    local value="$2"
    local line="$3"
    local file_name="${4:-input.txt}"
    local repo
    local output
    repo="$(new_repo "$name")"
    print -r -- "$line" > "$repo/$file_name"
    git -C "$repo" add "$file_name"
    if output="$("$script_dir/tracked-input-policy.sh" "$repo" 2>&1)"; then
        fail_test "$name was accepted"
    fi
    [[ "$output" != *"$value"* ]] || fail_test "$name exposed its value"
}

team_value="TEAM""123456"
assert_rejected_without_value team "$team_value" \
    "DEVELOPMENT_TEAM = $team_value"
commented_team_value="ABCD""123456"
assert_rejected_without_value team-with-fake-comment "$commented_team_value" \
    "DEVELOPMENT_TEAM = $commented_team_value // not a FAKE test value"
home_value="/Users/sample""-person/Projects/SnipSnap"
assert_rejected_without_value home sample-person "$home_value"
profile_line="PROVISIONING_PROFILE_""SPECIFIER = SampleProfile;"
assert_rejected_without_value profile SampleProfile "$profile_line"
identity_line="CODE_SIGN_""IDENTITY = \"Developer ID Application: Sample Person\";"
assert_rejected_without_value identity 'Sample Person' "$identity_line"
device_value="00000000-0000-0000-0000-000000000001"
device_line="SIMULATOR_""UDID = $device_value"
assert_rejected_without_value device "$device_value" "$device_line"
app_group_value="group.com.acme.snipsnap"
assert_rejected_without_value app-group "$app_group_value" \
    "SNIP_SNAP_APP_GROUP_IDENTIFIER = $app_group_value" \
    Fake.xcconfig

for credential_name in AuthKey_FAKE123.p8 distribution.p12 AppStore.mobileprovision; do
    credential_repo="$(new_repo "credential-${credential_name##*.}")"
    print 'fake credential bytes' > "$credential_repo/$credential_name"
    git -C "$credential_repo" add "$credential_name"
    if "$script_dir/tracked-input-policy.sh" "$credential_repo" >/dev/null 2>&1; then
        fail_test "$credential_name was accepted"
    fi
done

for key_prefix in PRIVATE 'OPENSSH PRIVATE' 'DSA PRIVATE'; do
    key_name="${key_prefix// /-}"
    private_key_repo="$(new_repo "private-key-$key_name")"
    print -- "-----BEGIN $key_prefix" 'KEY-----' > "$private_key_repo/key.txt"
    git -C "$private_key_repo" add key.txt
    if "$script_dir/tracked-input-policy.sh" "$private_key_repo" >/dev/null 2>&1; then
        fail_test "a $key_prefix key block was accepted"
    fi
done

print "Tracked-input policy checks passed."
