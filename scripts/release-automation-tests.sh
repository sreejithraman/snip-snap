#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source "$script_dir/release-policy.sh"
source "$script_dir/release-automation.sh"

test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-release-automation.XXXXXX)"
cleanup() {
    [[ "$test_root" == /private/tmp/snip-snap-release-automation.* ]] && /bin/rm -rf "$test_root"
}
trap cleanup EXIT

fail_test() {
    print -u2 "release automation test failed: $1"
    exit 1
}

assert_fails() {
    if "$@" >/dev/null 2>&1; then
        fail_test "expected failure: $*"
    fi
}

[[ "$(release_automation_build_number 1 6)" == 7 ]] || fail_test "wrong first build"
[[ "$(release_automation_build_number 2 6)" == 8 ]] || fail_test "build did not rise"
[[ "$(release_automation_build_number 1 7)" == 8 ]] || fail_test "offset change was ignored"
assert_fails release_automation_build_number 0 6
assert_fails release_automation_build_number 1 -1
[[ "$(release_automation_beta_tag 0.5.0 7)" == v0.5.0-beta.7 ]] || \
    fail_test "wrong beta tag"

zip="$test_root/Snip-Snap-0.5.0.zip"
dmg="$test_root/Snip-Snap-0.5.0.dmg"
record="$test_root/Snip-Snap-0.5.0-beta.7.json"
print -n 'zip bytes' > "$zip"
print -n 'dmg bytes' > "$dmg"
commit=0123456789abcdef0123456789abcdef01234567
record_appcast="$test_root/record-appcast.xml"
print '<rss><channel><item><enclosure url="https://github.test/releases/download/v0.5.0-beta.7/Snip-Snap-0.5.0.zip" length="9" sparkle:version="7" sparkle:shortVersionString="0.5.0" sparkle:edSignature="signed"/></item></channel></rss>' > "$record_appcast"
release_automation_write_record \
    "$record" 0.5.0 7 "$commit" https://github.test/runs/7 "$zip" "$dmg" \
    7 1 "$record_appcast"
release_automation_verify_record "$record" 0.5.0 7 "$zip" "$dmg" "$commit"
release_automation_verify_record_appcast "$record" "$record_appcast" 0.5.0 7
print '<rss><channel><item><enclosure url="https://github.test/other.zip" length="9" sparkle:version="7" sparkle:shortVersionString="0.5.0" sparkle:edSignature="signed"/></item></channel></rss>' > "$record_appcast"
assert_fails release_automation_verify_record_appcast "$record" "$record_appcast" 0.5.0 7
print '<rss><channel><item><enclosure url="https://github.test/releases/download/v0.5.0/Snip-Snap-0.5.0.zip" length="9" sparkle:version="7" sparkle:shortVersionString="0.5.0" sparkle:edSignature="signed"/></item></channel></rss>' > "$record_appcast"
release_automation_verify_record_appcast "$record" "$record_appcast" 0.5.0 7 default

gh_fixture="$test_root/gh"
print '#!/bin/zsh' > "$gh_fixture"
print 'case "$*" in' >> "$gh_fixture"
print '  *compare*) print ahead ;;' >> "$gh_fixture"
print '  *actions/runs/7/jobs*) print '\''{"jobs":[{"name":"Test release source","conclusion":"success","run_attempt":1},{"name":"Build signed Mac beta","conclusion":"success","run_attempt":1},{"name":"Upload internal TestFlight beta","conclusion":"success","run_attempt":1},{"name":"Publish Mac beta channels","conclusion":"failure","run_attempt":1},{"name":"Publish Mac beta channels","conclusion":"success","run_attempt":2}]}'\'' ;;' >> "$gh_fixture"
print '  *actions/runs/7*) print '\''{"status":"completed","conclusion":"success","head_sha":"0123456789abcdef0123456789abcdef01234567","head_branch":"main","event":"push","run_attempt":2}'\'' ;;' >> "$gh_fixture"
print '  *) exit 1 ;;' >> "$gh_fixture"
print 'esac' >> "$gh_fixture"
/bin/chmod +x "$gh_fixture"
SNIP_SNAP_GH="$gh_fixture"
release_policy_require_commit_on_main test/repo "$commit"
release_automation_verify_workflow_run "$record" test/repo "$commit"
assert_fails release_automation_verify_workflow_run \
    "$record" test/repo 1111111111111111111111111111111111111111
unset SNIP_SNAP_GH
print -n 'changed' >> "$zip"
assert_fails release_automation_verify_record "$record" 0.5.0 7 "$zip" "$dmg" "$commit"
print -n 'zip bytes' > "$zip"
assert_fails release_automation_verify_record "$record" 0.5.0 8 "$zip" "$dmg" "$commit"

beta_appcast="$test_root/beta.xml"
stable_appcast="$test_root/stable.xml"
print '<rss><channel><item><title>0.5.0</title><link>https://github.test/releases/tag/v0.5.0-beta.7</link><sparkle:version>7</sparkle:version><sparkle:shortVersionString>0.5.0</sparkle:shortVersionString><sparkle:channel>beta</sparkle:channel><sparkle:releaseNotesLink>https://github.test/Snip-Snap-0.5.0-beta.7.md</sparkle:releaseNotesLink><enclosure url="https://github.test/releases/download/v0.5.0-beta.7/Snip-Snap-0.5.0.zip" sparkle:version="7" sparkle:shortVersionString="0.5.0"/></item><item><title>0.4.1</title></item></channel></rss>' > "$beta_appcast"
old_item="$(/usr/bin/grep -o '<item><title>0.4.1</title></item>' "$beta_appcast")"
release_automation_require_appcast_channel "$beta_appcast" 0.5.0 7 beta
assert_fails release_automation_require_appcast_channel "$beta_appcast" 0.5.0 7 default
release_automation_promote_appcast \
    "$beta_appcast" "$stable_appcast" 0.5.0 7 v0.5.0-beta.7
release_automation_require_appcast_channel "$stable_appcast" 0.5.0 7 default
/usr/bin/grep -q 'releases/tag/v0.5.0<' "$stable_appcast" || \
    fail_test "promotion kept the beta tag"
/usr/bin/grep -q 'Snip-Snap-0.5.0.md<' "$stable_appcast" || \
    fail_test "promotion kept the beta notes"
[[ "$(/usr/bin/grep -o '<item><title>0.4.1</title></item>' "$stable_appcast")" == "$old_item" ]] || \
    fail_test "promotion changed another appcast item"
assert_fails release_automation_promote_appcast \
    "$stable_appcast" "$test_root/again.xml" 0.5.0 7 v0.5.0-beta.7

for workflow in beta.yml promote-stable.yml; do
    workflow_path="$script_dir/../.github/workflows/$workflow"
    [[ -f "$workflow_path" ]] || fail_test "missing $workflow"
    /usr/bin/grep -F 'environment: apple-release' "$workflow_path" >/dev/null || \
        fail_test "$workflow does not use apple-release"
done

beta_workflow="$script_dir/../.github/workflows/beta.yml"
/usr/bin/grep -F '${{ runner.temp }}' "$beta_workflow" >/dev/null && \
    fail_test "beta workflow uses runner context before a job starts"
for required in \
    'cancel-in-progress: false' \
    'scripts/release-build-number.sh' \
    'scripts/testflight.sh upload --build-number' \
    'scripts/release.sh --build-number' \
    'scripts/publish-beta.sh --build-number' \
    'scripts/build-matrix.sh' \
    'SNIP_SNAP_RELEASE_CHECKS_PASSED: YES' \
    'needs: [test, mac-build, ios-upload]' \
    'SNIP_SNAP_GENERATE_APPCAST=' \
    '"Shared/**"' \
    'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' \
    'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'; do
    /usr/bin/grep -F "$required" "$beta_workflow" >/dev/null || \
        fail_test "beta workflow is missing $required"
done
promotion_workflow="$script_dir/../.github/workflows/promote-stable.yml"
for required in \
    'version:' \
    'scripts/promote-release.sh' \
    '--version "${{ inputs.version }}"' \
    '--build-number "${{ inputs.build }}"'; do
    /usr/bin/grep -F -- "$required" "$promotion_workflow" >/dev/null || \
        fail_test "stable workflow is missing $required"
done

for retry_guard in \
    'gh release view "$beta_tag"' \
    'release_automation_verify_record'; do
    /usr/bin/grep -F "$retry_guard" "$script_dir/publish-beta.sh" >/dev/null || \
        fail_test "beta retry is missing $retry_guard"
done
for retry_guard in \
    'gh release view "$stable_tag"' \
    'release_automation_remote_tag_commit' \
    'matching beta or stable item' \
    'release_policy_verify_checksum'; do
    /usr/bin/grep -F "$retry_guard" "$script_dir/promote-release.sh" >/dev/null || \
        fail_test "stable retry is missing $retry_guard"
done
/usr/bin/grep -F 'Casks/snip-snap@beta.rb' "$script_dir/publish-beta.sh" >/dev/null || \
    fail_test "beta publish does not use the beta cask"
/usr/bin/grep -F 'Casks/snip-snap.rb' "$script_dir/promote-release.sh" >/dev/null || \
    fail_test "stable promotion does not use the stable cask"

/usr/bin/ruby -c "$script_dir/snip-snap-beta.rb.template" >/dev/null || \
    fail_test "invalid beta cask template"

ci_repo="$test_root/ci-repo"
ci_root="${RUNNER_TEMP:-$test_root}/snip-snap-release-cleanup"
/bin/mkdir -p "$ci_repo/Config" "$ci_root"
for protected_name in Local.xcconfig TestFlight.entitlements MacRelease.entitlements; do
    print -n secret > "$ci_repo/Config/$protected_name"
done
/usr/bin/printf '%s\n' \
    "$ci_repo/Config/Local.xcconfig" \
    "$ci_repo/Config/TestFlight.entitlements" \
    "$ci_repo/Config/MacRelease.entitlements" > "$ci_root/repo-secret-paths"
print -n keep > "$ci_repo/Config/keep.txt"
SNIP_SNAP_CI_ROOT="$ci_root" SNIP_SNAP_REPO_DIR="$ci_repo" \
    "$script_dir/ci-apple-setup.sh" cleanup
for protected_name in Local.xcconfig TestFlight.entitlements MacRelease.entitlements; do
    [[ ! -e "$ci_repo/Config/$protected_name" ]] || \
        fail_test "CI cleanup kept $protected_name"
done
[[ -f "$ci_repo/Config/keep.txt" ]] || fail_test "CI cleanup removed an unrelated file"

print "Release automation checks passed."
