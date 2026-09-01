#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source "$script_dir/release-policy.sh"

test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-release-policy.XXXXXX)"
cleanup() {
    [[ "$test_root" == /private/tmp/snip-snap-release-policy.* ]] && /bin/rm -rf "$test_root"
}
trap cleanup EXIT

fail_test() {
    print -u2 "release policy test failed: $1"
    exit 1
}

assert_succeeds() {
    "$@" >/dev/null 2>&1 || fail_test "expected success: $*"
}

assert_fails() {
    if "$@" >/dev/null 2>&1; then
        fail_test "expected failure: $*"
    fi
}

publish_keeps_all_appcast_versions() {
    /usr/bin/awk '
        BEGIN {
            safe = 1
        }

        function finish_call() {
            if (!keeps_all_versions) {
                safe = 0
            }
            in_call = 0
        }

        /^[[:space:]]*"\$sparkle_tool"([[:space:]]|$)/ {
            calls++
            in_call = 1
            keeps_all_versions = ($0 ~ /--maximum-versions[[:space:]]+0([[:space:]]|$)/)
            if ($0 !~ /\\[[:space:]]*$/) {
                finish_call()
            }
            next
        }

        in_call {
            if ($0 ~ /--maximum-versions[[:space:]]+0([[:space:]]|$)/) {
                keeps_all_versions = 1
            }
            if ($0 !~ /\\[[:space:]]*$/) {
                finish_call()
            }
        }

        END {
            if (in_call) {
                finish_call()
            }
            exit !(calls > 0 && safe != 0)
        }
    ' "$1"
}

assert_succeeds publish_keeps_all_appcast_versions "$script_dir/publish-beta.sh"
publish_missing_history_limit="$test_root/publish-missing-history-limit.sh"
/usr/bin/awk '
    /^[[:space:]]*"\$sparkle_tool"([[:space:]]|$)/ { in_call = 1 }
    in_call && !removed && sub(/--maximum-versions[[:space:]]+0/, "") { removed = 1 }
    { print }
    in_call && $0 !~ /\\[[:space:]]*$/ { in_call = 0 }
' "$script_dir/publish-beta.sh" > "$publish_missing_history_limit"
assert_fails publish_keeps_all_appcast_versions "$publish_missing_history_limit"

manifest="$test_root/release.json"
print '{"version":"0.1.0"}' > "$manifest"
assert_succeeds release_policy_load_manifest "$manifest"
[[ "$RELEASE_VERSION" == "0.1.0" ]] || fail_test "wrong manifest version"
assert_succeeds release_policy_set_build_number 1
[[ "$RELEASE_BUILD_NUMBER" == "1" ]] || fail_test "wrong manifest build"

SNIP_SNAP_VERSION="0.2.0"
assert_fails release_policy_load_manifest "$manifest"
unset SNIP_SNAP_VERSION
SNIP_SNAP_BUILD_NUMBER="2"
assert_fails release_policy_set_build_number 1
unset SNIP_SNAP_BUILD_NUMBER

print '{"version":"01.0.0"}' > "$manifest"
assert_fails release_policy_load_manifest "$manifest"
print '{"version":"0.1.0","build":1}' > "$manifest"
assert_fails release_policy_load_manifest "$manifest"
print '{"version":"0.1.0"}' > "$manifest"
assert_succeeds release_policy_load_release "$manifest" 1
assert_fails release_policy_set_build_number 0
assert_fails release_policy_set_build_number beta

assert_succeeds release_policy_version_is_greater 0.1.1 0.1.0
assert_succeeds release_policy_version_is_greater 0.2.0 0.1.9
assert_succeeds release_policy_version_is_greater 1.0.0 0.99.99
assert_fails release_policy_version_is_greater 0.1.0 0.1.0
assert_fails release_policy_version_is_greater 0.1.0 0.1.1

project="$test_root/project.pbxproj"
print 'MARKETING_VERSION = 0.1.0;' > "$project"
print 'CURRENT_PROJECT_VERSION = 1;' >> "$project"
assert_succeeds release_policy_require_project_versions "$project"
print 'MARKETING_VERSION = 0.2.0;' >> "$project"
assert_fails release_policy_require_project_versions "$project"

appcast="$test_root/appcast.xml"
print '<item sparkle:version="0" sparkle:shortVersionString="0.0.1"/>' > "$appcast"
assert_succeeds release_policy_require_new_build "$appcast"
print '<item><enclosure url="release.zip" sparkle:version="1" sparkle:shortVersionString="0.1.0"/></item>' > "$appcast"
assert_fails release_policy_require_new_build "$appcast"
assert_succeeds release_policy_require_build_not_older "$appcast"
assert_succeeds release_policy_appcast_contains_release "$appcast"
print '<item sparkle:version="2" sparkle:shortVersionString="0.2.0"/>' > "$appcast"
assert_fails release_policy_require_build_not_older "$appcast"

assert_succeeds release_policy_notary_history_contains_build \
    '{"history":[{"name":"Snip-Snap-build-1-0.0.9-submission.zip"}]}' \
    1
assert_fails release_policy_notary_history_contains_build \
    '{"history":[{"name":"Snip-Snap-build-2-0.1.0-submission.zip"}]}' \
    1
assert_fails release_policy_notary_history_contains_build \
    '{"message":"No submission history.","history":[]}' \
    1
entry="$(release_policy_notary_submission_entry \
    '{"history":[{"id":"submission-2","name":"Snip-Snap-build-2-0.1.1-submission.dmg","status":"Accepted"}]}' \
    'Snip-Snap-build-2-0.1.1-submission.dmg')"
[[ "$entry" == $'submission-2\tAccepted' ]] || \
    fail_test "wrong Apple submission entry"
assert_fails release_policy_notary_submission_entry \
    '{"history":[]}' \
    'Snip-Snap-build-2-0.1.1-submission.dmg'
[[ "$(release_policy_latest_notary_build \
    '{"history":[{"name":"Snip-Snap-build-5-0.2.0-submission.zip"},{"name":"Snip-Snap-build-2-0.1.0-submission.zip"}]}')" == "5" ]] || \
    fail_test "wrong latest Apple build"
assert_succeeds release_policy_require_new_notary_build_from_history \
    '{"history":[{"name":"Snip-Snap-build-5-0.2.0-submission.zip"}]}' \
    6
assert_fails release_policy_require_new_notary_build_from_history \
    '{"history":[{"name":"Snip-Snap-build-5-0.2.0-submission.zip"}]}' \
    3
assert_fails release_policy_require_new_notary_build_from_history \
    '{"history":[{"name":"Snip-Snap-build-5-0.2.0-submission.zip"}]}' \
    5
assert_succeeds release_policy_require_new_notary_build_from_history \
    '{"message":"No submission history.","history":[]}' \
    1

old_appcast="$test_root/old-appcast.xml"
new_appcast="$test_root/new-appcast.xml"
print '<rss><channel><item><title>0.0.1</title></item></channel></rss>' > "$old_appcast"
print '<rss><channel><item><title>0.1.0</title></item><item><title>0.0.1</title></item></channel></rss>' > "$new_appcast"
assert_succeeds release_policy_require_preserved_appcast_items "$old_appcast" "$new_appcast"
print '<rss><channel><item><title>changed</title></item></channel></rss>' > "$new_appcast"
assert_fails release_policy_require_preserved_appcast_items "$old_appcast" "$new_appcast"

print '<rss><channel><item><enclosure url="release.zip" length="10" sparkle:version="1" sparkle:shortVersionString="0.1.0" sparkle:edSignature="abc"/></item></channel></rss>' > "$old_appcast"
/bin/cp "$old_appcast" "$new_appcast"
assert_succeeds release_policy_appcast_contains_release "$old_appcast"
assert_succeeds release_policy_require_matching_appcast_release "$old_appcast" "$new_appcast"
print '<rss><channel><item><enclosure url="other.zip" length="10" sparkle:version="1" sparkle:shortVersionString="0.1.0" sparkle:edSignature="abc"/></item></channel></rss>' > "$new_appcast"
assert_fails release_policy_require_matching_appcast_release "$old_appcast" "$new_appcast"

update_root="$test_root/update"
/bin/mkdir -p "$update_root/scripts" "$update_root/Config"
/bin/cp "$script_dir/release-policy.sh" "$update_root/scripts/release-policy.sh"
/bin/cp "$script_dir/set-release.sh" "$update_root/scripts/set-release.sh"
print '{"version":"0.1.0"}' > "$update_root/release.json"
print 'MARKETING_VERSION = 0.1.0' > "$update_root/Config/Shared.xcconfig"
print 'CURRENT_PROJECT_VERSION = 1' >> "$update_root/Config/Shared.xcconfig"
assert_succeeds "$update_root/scripts/set-release.sh" 0.2.0
/usr/bin/grep -q 'MARKETING_VERSION = 0.2.0' \
    "$update_root/Config/Shared.xcconfig" || fail_test "set-release missed Xcode version"
/usr/bin/grep -q 'CURRENT_PROJECT_VERSION = 1' \
    "$update_root/Config/Shared.xcconfig" || fail_test "set-release changed the local build"
assert_fails "$update_root/scripts/set-release.sh" 0.1.0
assert_fails "$update_root/scripts/set-release.sh" 0.3.0 2

verified_app="$test_root/verified/Snip Snap.app"
/bin/mkdir -p "$verified_app/Contents/Resources"
print '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.1.0</string><key>CFBundleVersion</key><string>1</string></dict></plist>' > \
    "$verified_app/Contents/Info.plist"
print '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>NSPrivacyTracking</key><false/></dict></plist>' > \
    "$verified_app/Contents/Resources/PrivacyInfo.xcprivacy"
assert_succeeds release_policy_verify_app "$verified_app"
/bin/rm "$verified_app/Contents/Resources/PrivacyInfo.xcprivacy"
assert_fails release_policy_verify_app "$verified_app"

archive="$test_root/Snip-Snap-0.1.0.zip"
checksum="$archive.sha256"
print -n 'release bytes' > "$archive"
/usr/bin/shasum -a 256 "$archive" > "$checksum"
assert_succeeds release_policy_verify_checksum "$archive" "$checksum"
print -n 'changed' >> "$archive"
assert_fails release_policy_verify_checksum "$archive" "$checksum"

print "Release policy checks passed."
