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
fake_brew="$test_root/brew"
print '#!/bin/zsh' > "$fake_brew"
print '[[ "$1" == tap ]] && exit 0' >> "$fake_brew"
print '[[ "$1" == untap ]] && exit 0' >> "$fake_brew"
print '[[ "$1" == --repository ]] && { print -r -- "$SNIP_SNAP_TEST_TAP"; exit 0; }' >> "$fake_brew"
print 'exit 1' >> "$fake_brew"
/bin/chmod +x "$fake_brew"
fake_tap="$test_root/homebrew-tap"
git init --quiet --initial-branch=main "$fake_tap"
SNIP_SNAP_TEST_TAP="$fake_tap"
export SNIP_SNAP_TEST_TAP
[[ "$(release_automation_brew_tool "$fake_brew")" == "$fake_brew" ]] || \
    fail_test "explicit Homebrew executable was ignored"
assert_fails release_automation_brew_tool "$test_root/missing-brew"
[[ "$(release_automation_tap_name sreejithraman/homebrew-tap)" == sreejithraman/tap ]] || \
    fail_test "wrong Homebrew tap name"
assert_fails release_automation_tap_name sreejithraman/tap
[[ "$(release_automation_working_tap_name abc123)" == snip-snap-release/abc123 ]] || \
    fail_test "wrong working Homebrew tap name"
assert_fails release_automation_working_tap_name invalid-suffix
[[ "$(release_automation_tap_checkout "$fake_brew" snip-snap-release/abc123 \
    sreejithraman/homebrew-tap)" == "$fake_tap" ]] || \
    fail_test "wrong Homebrew tap checkout"
release_automation_remove_working_tap "$fake_brew" snip-snap-release/abc123 || \
    fail_test "working Homebrew tap was not removed"
unset SNIP_SNAP_TEST_TAP

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
    7 1 "$record_appcast" 6 1
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
print '  *actions/runs/6/jobs*) print '\''{"jobs":[{"name":"Test beta candidate","conclusion":"success","run_attempt":1}]}'\'' ;;' >> "$gh_fixture"
print '  *actions/runs/6*) print '\''{"status":"completed","conclusion":"failure","head_sha":"0123456789abcdef0123456789abcdef01234567","head_branch":"main","event":"push","run_attempt":2}'\'' ;;' >> "$gh_fixture"
print '  *actions/runs/7/jobs*) print '\''{"jobs":[{"name":"Prepare release source","conclusion":"success","run_attempt":1},{"name":"Build signed Mac beta","conclusion":"success","run_attempt":1},{"name":"Upload internal TestFlight beta","conclusion":"success","run_attempt":1},{"name":"Publish Mac beta channels","conclusion":"failure","run_attempt":1},{"name":"Publish Mac beta channels","conclusion":"success","run_attempt":2}]}'\'' ;;' >> "$gh_fixture"
print '  *actions/runs/7*) print '\''{"status":"completed","conclusion":"success","head_sha":"0123456789abcdef0123456789abcdef01234567","head_branch":"main","event":"workflow_run","run_attempt":2}'\'' ;;' >> "$gh_fixture"
print '  *actions/runs/8/jobs*) print '\''{"jobs":[{"name":"Test release source","conclusion":"success","run_attempt":1},{"name":"Build signed Mac beta","conclusion":"success","run_attempt":1},{"name":"Upload internal TestFlight beta","conclusion":"success","run_attempt":1},{"name":"Publish Mac beta channels","conclusion":"success","run_attempt":1}]}'\'' ;;' >> "$gh_fixture"
print '  *actions/runs/8*) print '\''{"status":"completed","conclusion":"success","head_sha":"0123456789abcdef0123456789abcdef01234567","head_branch":"main","event":"push","run_attempt":1}'\'' ;;' >> "$gh_fixture"
print '  *) exit 1 ;;' >> "$gh_fixture"
print 'esac' >> "$gh_fixture"
/bin/chmod +x "$gh_fixture"
SNIP_SNAP_GH="$gh_fixture"
release_policy_require_commit_on_main test/repo "$commit"
release_automation_verify_workflow_run "$record" test/repo "$commit"
assert_fails release_automation_verify_workflow_run \
    "$record" test/repo 1111111111111111111111111111111111111111
later_candidate_record="$test_root/Snip-Snap-0.5.0-beta.7-later-candidate.json"
/usr/bin/ruby -rjson -e '
  record = JSON.parse(File.read(ARGV.fetch(0)))
  record["candidateWorkflow"]["runAttempt"] = 2
  File.write(ARGV.fetch(1), JSON.pretty_generate(record) + "\n")
' "$record" "$later_candidate_record"
assert_fails release_automation_verify_workflow_run \
    "$later_candidate_record" test/repo "$commit"
legacy_record="$test_root/Snip-Snap-0.5.0-beta.7-legacy.json"
/usr/bin/ruby -rjson -e '
  record = JSON.parse(File.read(ARGV.fetch(0)))
  record["schemaVersion"] = 2
  record.delete("candidateWorkflow")
  record["workflow"]["runID"] = 8
  record["workflow"]["runAttempt"] = 1
  record["workflow"]["testResult"] = "passed"
  File.write(ARGV.fetch(1), JSON.pretty_generate(record) + "\n")
' "$record" "$legacy_record"
release_automation_verify_record "$legacy_record" 0.5.0 7 "$zip" "$dmg" "$commit"
release_automation_verify_workflow_run "$legacy_record" test/repo "$commit"
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
beta_candidate_workflow="$script_dir/../.github/workflows/beta-candidate.yml"
[[ -f "$beta_candidate_workflow" ]] || fail_test "missing beta-candidate.yml"
/usr/bin/grep -F '${{ runner.temp }}' "$beta_workflow" >/dev/null && \
    fail_test "beta workflow uses runner context before a job starts"
for required in \
    'name: Beta candidate' \
    'workflow_dispatch:' \
    'group: beta-candidate-${{ github.ref }}' \
    'cancel-in-progress: true' \
    './scripts/test.sh' \
    './scripts/build-matrix.sh' \
    '"Shared/**"' \
    '".github/workflows/beta.yml"'; do
    /usr/bin/grep -F "$required" "$beta_candidate_workflow" >/dev/null || \
        fail_test "beta candidate workflow is missing $required"
done
/usr/bin/grep -F 'environment: apple-release' "$beta_candidate_workflow" >/dev/null && \
    fail_test "beta candidate uses the protected release environment"
/usr/bin/grep -F 'secrets.' "$beta_candidate_workflow" >/dev/null && \
    fail_test "beta candidate reads protected secrets"
for required in \
    'workflow_run:' \
    'Beta candidate' \
    'group: beta-publish-main' \
    'cancel-in-progress: false' \
    'Prepare release source' \
    "github.event.workflow_run.conclusion == 'success'" \
    'github.event.workflow_run.head_sha' \
    'Check current main' \
    'current=false' \
    'needs.prepare.outputs.current' \
    'SNIP_SNAP_CANDIDATE_RUN_ATTEMPT' \
    'SNIP_SNAP_CANDIDATE_RUN_ID' \
    'scripts/release-build-number.sh' \
    'scripts/testflight.sh upload --build-number' \
    'scripts/release.sh --build-number' \
    'scripts/publish-beta.sh --build-number' \
    'SNIP_SNAP_RELEASE_CHECKS_PASSED: YES' \
    'IOS_DEVELOPMENT_CERTIFICATE_BASE64' \
    'IOS_DEVELOPMENT_CERTIFICATE_PASSWORD' \
    'IOS_APP_DEVELOPMENT_PROFILE_BASE64' \
    'IOS_SHARE_DEVELOPMENT_PROFILE_BASE64' \
    'IOS_APP_STORE_PROFILE_BASE64' \
    'IOS_SHARE_APP_STORE_PROFILE_BASE64' \
    'IOS_APP_STORE_PROFILE_NAME' \
    'IOS_SHARE_APP_STORE_PROFILE_NAME' \
    'needs: [prepare, mac-build, ios-upload]' \
    'SNIP_SNAP_GENERATE_APPCAST=' \
    'gh auth setup-git --hostname github.com' \
    'export SNIP_SNAP_RUNNER_PATH="$PATH"' \
    'export SNIP_SNAP_GH="$(command -v gh)"' \
    'export SNIP_SNAP_GIT="$(command -v git)"' \
    'export HOMEBREW_GIT_PATH="$SNIP_SNAP_GIT"' \
    'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' \
    'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'; do
    /usr/bin/grep -F "$required" "$beta_workflow" >/dev/null || \
        fail_test "beta workflow is missing $required"
done
/usr/bin/grep -E '^[[:space:]]+\./scripts/test\.sh$' "$beta_workflow" >/dev/null && \
    fail_test "beta delivery reruns candidate tests"
/usr/bin/grep -F 'workflow_dispatch:' "$beta_workflow" >/dev/null && \
    fail_test "beta delivery can bypass candidate checks"
promotion_workflow="$script_dir/../.github/workflows/promote-stable.yml"
for required in \
    'version:' \
    'gh auth setup-git --hostname github.com' \
    'export SNIP_SNAP_RUNNER_PATH="$PATH"' \
    'export SNIP_SNAP_GH="$(command -v gh)"' \
    'export SNIP_SNAP_GIT="$(command -v git)"' \
    'export HOMEBREW_GIT_PATH="$SNIP_SNAP_GIT"' \
    'scripts/promote-release.sh' \
    '--version "${{ inputs.version }}"' \
    '--build-number "${{ inputs.build }}"'; do
    /usr/bin/grep -F -- "$required" "$promotion_workflow" >/dev/null || \
        fail_test "stable workflow is missing $required"
done
for release_script in publish-beta.sh promote-release.sh; do
    /usr/bin/grep -F 'command "$git_tool" "$@"' \
        "$script_dir/$release_script" >/dev/null || \
        fail_test "$release_script does not use the explicit Git tool"
    /usr/bin/grep -F 'git clone --quiet "https://github.com/$release_repo.git"' \
        "$script_dir/$release_script" >/dev/null || \
        fail_test "$release_script does not use Git for its source checkout"
done
for release_script in publish-beta.sh promote-release.sh; do
    /usr/bin/grep -F 'export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${SNIP_SNAP_RUNNER_PATH:-$PATH}"' \
        "$script_dir/$release_script" >/dev/null || \
        fail_test "$release_script does not restore the runner tool path"
done

for retry_guard in \
    '"$gh_tool" release view "$beta_tag"' \
    'release_automation_verify_record'; do
    /usr/bin/grep -F "$retry_guard" "$script_dir/publish-beta.sh" >/dev/null || \
        fail_test "beta retry is missing $retry_guard"
done
for retry_guard in \
    '"$gh_tool" release view "$stable_tag"' \
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

ci_setup_repo="$test_root/ci-setup-repo"
ci_setup_root="$test_root/snip-snap-release-setup"
security_log="$test_root/security.log"
fake_security="$test_root/security"
/bin/mkdir -p "$ci_setup_repo/Config"
print -r -- '#!/bin/zsh
set -euo pipefail
print -r -- "$*" >> "$SNIP_SNAP_SECURITY_LOG"
[[ "$1" != create-keychain ]] || /usr/bin/touch "${@: -1}"
if [[ "$1" == cms ]]; then
    case "$*" in
        *ios-app-development*) uuid=00000000-0000-0000-0000-000000000001 ;;
        *ios-share-development*) uuid=00000000-0000-0000-0000-000000000002 ;;
        *ios-app-store*) uuid=00000000-0000-0000-0000-000000000003 ;;
        *ios-share-app-store*) uuid=00000000-0000-0000-0000-000000000004 ;;
        *) uuid=00000000-0000-0000-0000-000000000005 ;;
    esac
    print -r -- "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>UUID</key><string>$uuid</string></dict></plist>"
fi' > "$fake_security"
/bin/chmod +x "$fake_security"
encoded_distribution="$(print -n distribution | /usr/bin/base64)"
encoded_development="$(print -n development | /usr/bin/base64)"
encoded_profile="$(print -n profile | /usr/bin/base64)"
/usr/bin/env \
    HOME="$test_root/home" \
    RUNNER_TEMP="$test_root" \
    SNIP_SNAP_CI_ROOT="$ci_setup_root" \
    SNIP_SNAP_REPO_DIR="$ci_setup_repo" \
    SNIP_SNAP_SECURITY_TOOL="$fake_security" \
    SNIP_SNAP_SECURITY_LOG="$security_log" \
    SNIP_SNAP_CI_LOCAL_XCCONFIG=local-settings \
    SNIP_SNAP_CI_TESTFLIGHT_ENTITLEMENTS=testflight-entitlements \
    SNIP_SNAP_CI_APPLE_API_PRIVATE_KEY=api-key \
    SNIP_SNAP_CI_CERTIFICATE_BASE64="$encoded_distribution" \
    SNIP_SNAP_CI_CERTIFICATE_PASSWORD=distribution-password \
    SNIP_SNAP_CI_DEVELOPMENT_CERTIFICATE_BASE64="$encoded_development" \
    SNIP_SNAP_CI_DEVELOPMENT_CERTIFICATE_PASSWORD=development-password \
    SNIP_SNAP_CI_IOS_APP_DEVELOPMENT_PROFILE_BASE64="$encoded_profile" \
    SNIP_SNAP_CI_IOS_SHARE_DEVELOPMENT_PROFILE_BASE64="$encoded_profile" \
    SNIP_SNAP_CI_IOS_APP_STORE_PROFILE_BASE64="$encoded_profile" \
    SNIP_SNAP_CI_IOS_SHARE_APP_STORE_PROFILE_BASE64="$encoded_profile" \
    SHOWROOM_APPLE_KEY_ID=key-id \
    SHOWROOM_APPLE_ISSUER_ID=issuer-id \
    "$script_dir/ci-apple-setup.sh" setup ios
for certificate in signing.p12 development-signing.p12; do
    [[ "$(/usr/bin/stat -f '%Lp' "$ci_setup_root/$certificate")" == 600 ]] || \
        fail_test "CI setup left $certificate readable"
    /usr/bin/grep -F "import $ci_setup_root/$certificate" "$security_log" >/dev/null || \
        fail_test "CI setup did not import $certificate"
done
[[ ! -e "$ci_setup_root/development-signing-password" ]] || \
    fail_test "CI setup wrote the development certificate password"
[[ "$(/usr/bin/wc -l < "$ci_setup_root/profile-paths" | /usr/bin/tr -d ' ')" == 4 ]] || \
    fail_test "CI setup did not record all iOS profiles"
while IFS= read -r installed_profile; do
    [[ -f "$installed_profile" ]] || fail_test "CI setup did not install $installed_profile"
    [[ "$(/usr/bin/stat -f '%Lp' "$installed_profile")" == 600 ]] || \
        fail_test "CI setup left $installed_profile readable"
done < "$ci_setup_root/profile-paths"

missing_development_repo="$test_root/missing-development-repo"
missing_development_root="$test_root/snip-snap-release-missing-development"
/bin/mkdir -p "$missing_development_repo/Config"
if missing_output="$(/usr/bin/env \
    RUNNER_TEMP="$test_root" \
    SNIP_SNAP_CI_ROOT="$missing_development_root" \
    SNIP_SNAP_REPO_DIR="$missing_development_repo" \
    SNIP_SNAP_SECURITY_TOOL="$fake_security" \
    SNIP_SNAP_SECURITY_LOG="$security_log" \
    SNIP_SNAP_CI_LOCAL_XCCONFIG=local-settings \
    SNIP_SNAP_CI_TESTFLIGHT_ENTITLEMENTS=testflight-entitlements \
    SNIP_SNAP_CI_APPLE_API_PRIVATE_KEY=api-key \
    SNIP_SNAP_CI_CERTIFICATE_BASE64="$encoded_distribution" \
    SNIP_SNAP_CI_CERTIFICATE_PASSWORD=distribution-password \
    SNIP_SNAP_CI_DEVELOPMENT_CERTIFICATE_PASSWORD=development-password \
    SHOWROOM_APPLE_KEY_ID=key-id \
    SHOWROOM_APPLE_ISSUER_ID=issuer-id \
    "$script_dir/ci-apple-setup.sh" setup ios 2>&1)"; then
    fail_test "CI setup accepted a missing development certificate"
fi
[[ "$missing_output" == *"development signing certificate is missing"* ]] || \
    fail_test "CI setup hid the missing development certificate"
[[ ! -e "$missing_development_root" ]] || \
    fail_test "CI setup changed state before validating development signing inputs"

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
