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

notes_asset="$test_root/Snip-Snap-0.5.0-ios.txt"
notes_remote="$test_root/notes-remote"
notes_download="$test_root/notes-download"
notes_gh="$test_root/notes-gh"
/bin/mkdir -p "$notes_remote" "$notes_download"
print 'iOS changes' > "$notes_asset"
for note_form in github.md mac.txt ios.txt; do
    expected_note="$test_root/expected-$note_form"
    published_note="$test_root/published-$note_form"
    print 'published notes' > "$expected_note"
    release_automation_require_matching_notes_file "$published_note" "$expected_note"
    /bin/cp "$expected_note" "$published_note"
    release_automation_require_matching_notes_file "$published_note" "$expected_note"
    print 'changed notes' > "$expected_note"
    assert_fails release_automation_require_matching_notes_file "$published_note" "$expected_note"
done
body_gh="$test_root/body-gh"
print '#!/bin/zsh' > "$body_gh"
print 'print -r -- "$SNIP_SNAP_TEST_NOTES_BODY"' >> "$body_gh"
/bin/chmod +x "$body_gh"
export SNIP_SNAP_TEST_NOTES_BODY='iOS changes'
release_automation_require_matching_notes_body "$body_gh" v0.5.0 test/repo "$notes_asset"
SNIP_SNAP_TEST_NOTES_BODY='old body'
assert_fails release_automation_require_matching_notes_body "$body_gh" v0.5.0 test/repo "$notes_asset"
unset SNIP_SNAP_TEST_NOTES_BODY
cat > "$notes_gh" <<'GH'
#!/bin/zsh
set -euo pipefail
case "$2" in
    view) /bin/ls "$SNIP_SNAP_TEST_NOTES_REMOTE" ;;
    upload)
        [[ ! -e "$SNIP_SNAP_TEST_NOTES_REMOTE/${4:t}" ]]
        /bin/cp "$4" "$SNIP_SNAP_TEST_NOTES_REMOTE/"
        ;;
    download)
        /bin/cp "$SNIP_SNAP_TEST_NOTES_REMOTE/$7" "$9/"
        ;;
    *) exit 1 ;;
esac
GH
/bin/chmod +x "$notes_gh"
export SNIP_SNAP_TEST_NOTES_REMOTE="$notes_remote"
# A missing asset after partial release creation is uploaded, then verified.
release_automation_ensure_notes_asset "$notes_gh" v0.5.0 test/repo "$notes_asset" "$notes_download"
/usr/bin/cmp "$notes_asset" "$notes_download/${notes_asset:t}"
/bin/rm "$notes_download/${notes_asset:t}"
# An unchanged asset is reused. A changed asset fails without replacement.
release_automation_ensure_notes_asset "$notes_gh" v0.5.0 test/repo "$notes_asset" "$notes_download"
/bin/rm "$notes_download/${notes_asset:t}"
print 'different notes' > "$notes_remote/${notes_asset:t}"
assert_fails release_automation_ensure_notes_asset "$notes_gh" v0.5.0 test/repo "$notes_asset" "$notes_download"
[[ "$(<"$notes_remote/${notes_asset:t}")" == 'different notes' ]] || fail_test "replaced existing notes"
unset SNIP_SNAP_TEST_NOTES_REMOTE

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

# Execute the real prepare step against local release tags, without Apple inputs.
/usr/bin/ruby - "$beta_workflow" "$script_dir" "$test_root" <<'RUBY'
require "yaml"
require "fileutils"
require "open3"
require "shellwords"

workflow = YAML.load_file(ARGV.fetch(0))
scripts = ARGV.fetch(1)
root = File.join(ARGV.fetch(2), "prepare-release")
remote = File.join(root, "origin.git")
repo = File.join(root, "checkout")
FileUtils.mkdir_p(File.join(repo, "scripts"))
FileUtils.mkdir_p(File.join(repo, "Config"))

def git!(*args)
  output, status = Open3.capture2e("git", *args)
  abort "prepare release fixture failed: #{output}" unless status.success?
end

git!("init", "--quiet", "--bare", remote)
git!("-C", repo, "init", "--quiet", "--initial-branch=main")
git!("-C", repo, "-c", "user.name=Release Test", "-c", "user.email=release@example.invalid",
     "-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "Fixture")
git!("-C", repo, "remote", "add", "origin", remote)
git!("-C", repo, "tag", "v0.6.0")
git!("-C", repo, "tag", "v0.7.0-beta.139")
git!("-C", repo, "push", "--quiet", "origin", "--tags")
%w[release-policy.sh release-automation.sh release-build-number.sh].each do |name|
  FileUtils.cp(File.join(scripts, name), File.join(repo, "scripts", name))
end

step = workflow.fetch("jobs").fetch("prepare").fetch("steps").find { |entry| entry["id"] == "release" }
abort "missing release prepare step" unless step
command_file = File.join(root, "prepare.sh")
File.write(command_file, step.fetch("run"))
shell = Shellwords.split(step.fetch("shell", "bash --noprofile --norc -e {0}"))
command = shell.map { |argument| argument == "{0}" ? command_file : argument }
outputs = File.join(root, "outputs")

def prepare(command, repo, outputs, version, settings_version = version)
  File.write(File.join(repo, "Config", "release.json"), %({"version":"#{version}"}\n))
  File.write(File.join(repo, "Config", "Shared.xcconfig"),
             "MARKETING_VERSION = #{settings_version}\nCURRENT_PROJECT_VERSION = 1\n")
  File.write(outputs, "")
  log, status = Open3.capture2e(
    { "GITHUB_RUN_NUMBER" => "132", "GITHUB_OUTPUT" => outputs,
      "SNIP_SNAP_VERSION" => nil, "SNIP_SNAP_BUILD_NUMBER" => nil, "SNIP_SNAP_BUILD_OFFSET" => nil },
    *command, chdir: repo
  )
  [log, status, File.read(outputs)]
end

%w[0.6.0 0.5.9].each do |version|
  log, status, values = prepare(command, repo, outputs, version)
  abort "prepare release test failed: published version #{version} started delivery" if status.success?
  abort "prepare release test failed: missing published-version diagnostic" unless log.include?("must be newer than v0.6.0")
  abort "prepare release test failed: rejected version emitted release outputs" unless values.empty?
end

log, status, values = prepare(command, repo, outputs, "0.6.1")
abort "prepare release test failed: next version was rejected: #{log}" unless status.success?
abort "prepare release test failed: wrong version or generated build: #{values}" unless values == "version=0.6.1\nbuild=138\n"

log, status, values = prepare(command, repo, outputs, "0.6.1", "0.6.0")
abort "prepare release test failed: inconsistent Xcode version started delivery" if status.success?
abort "prepare release test failed: missing Xcode-version diagnostic" unless log.include?("MARKETING_VERSION")
abort "prepare release test failed: inconsistent version emitted release outputs" unless values.empty?

git!("-C", repo, "remote", "set-url", "origin", File.join(root, "missing-origin.git"))
log, status, values = prepare(command, repo, outputs, "0.6.1")
abort "prepare release test failed: unavailable release tags started delivery" if status.success?
abort "prepare release test failed: missing tag-fetch diagnostic" unless log.include?("could not read release tags")
abort "prepare release test failed: unavailable tags emitted release outputs" unless values.empty?

%w[mac-build ios-upload].each do |name|
  dependencies = Array(workflow.fetch("jobs").fetch(name).fetch("needs"))
  abort "prepare release test failed: #{name} bypasses prepare" unless dependencies.include?("prepare")
end
RUBY

[[ -f "$beta_candidate_workflow" ]] || fail_test "missing beta-candidate.yml"
/usr/bin/grep -F '${{ runner.temp }}' "$beta_workflow" >/dev/null && \
    fail_test "beta workflow uses runner context before a job starts"
/usr/bin/grep -F 'environment: apple-release' "$beta_candidate_workflow" >/dev/null && \
    fail_test "beta candidate uses the protected release environment"
/usr/bin/grep -F 'secrets.' "$beta_candidate_workflow" >/dev/null && \
    fail_test "beta candidate reads protected secrets"
for required in \
    'workflow_run:' \
    "github.event.workflow_run.conclusion == 'success'" \
    'needs.prepare.outputs.current' \
    'SNIP_SNAP_RELEASE_CHECKS_PASSED: YES'; do
    /usr/bin/grep -F "$required" "$beta_workflow" >/dev/null || \
        fail_test "beta workflow is missing $required"
done
/usr/bin/grep -F 'workflow_dispatch:' "$beta_workflow" >/dev/null && \
    fail_test "beta delivery can bypass candidate checks"
# Delivery follows the candidate workflow that runs the tests, and does not run them again.
/usr/bin/ruby - "$beta_candidate_workflow" "$beta_workflow" <<'RUBY' || \
    fail_test "beta delivery is not tied to the tested candidate"
require "yaml"

candidate = YAML.load_file(ARGV.fetch(0))
delivery = YAML.load_file(ARGV.fetch(1))
triggers = delivery.fetch("on") { delivery.fetch(true) }
followed = Array(triggers.fetch("workflow_run").fetch("workflows"))
abort "beta delivery does not follow #{candidate.fetch("name")}" unless followed.include?(candidate.fetch("name"))
runs = lambda do |workflow|
  workflow.fetch("jobs").values.flat_map { |job| job.fetch("steps", []) }.map { |step| step["run"] }.compact
end
abort "beta candidate does not run scripts/test.sh" unless runs.call(candidate).any? { |run| run.include?("scripts/test.sh") }
abort "beta delivery reruns candidate tests" if runs.call(delivery).any? { |run| run.include?("scripts/test.sh") }
RUBY

# Run the real retry guards of publish-beta.sh and promote-release.sh against fake GitHub and
# Git. A matching stable release is verified and kept; every mismatch stops before a release is made.
retry_root="$test_root/release-retry"
retry_commit=1111111111111111111111111111111111111111
/bin/mkdir -p "$retry_root/beta" "$retry_root/published"
for retry_file in Snip-Snap-0.5.0.zip Snip-Snap-0.5.0.dmg; do
    print -rn -- "$retry_file bytes" > "$retry_root/beta/$retry_file"
    /usr/bin/shasum -a 256 "$retry_root/beta/$retry_file" > "$retry_root/beta/$retry_file.sha256"
    /bin/cp "$retry_root/beta/$retry_file" "$retry_root/beta/$retry_file.sha256" "$retry_root/published/"
done
/bin/cat > "$retry_root/gh" <<'STUB'
#!/bin/zsh
print -r -- "$*" >> "$RETRY_GH_LOG"
case "$1 $2" in
    'release view') [[ "$RETRY_RELEASE_EXISTS" == 1 ]] ;;
    'release download') /bin/cp "$RETRY_PUBLISHED/$7" "$9/$7" ;;
    'release create') ;;
    *) exit 1 ;;
esac
STUB
/bin/cat > "$retry_root/git" <<'STUB'
#!/bin/zsh
[[ "$1" == ls-remote ]] || exit 1
if [[ "$2" == --exit-code ]]; then
    [[ -n "$RETRY_TAG_COMMIT" ]]
    exit
fi
[[ -z "$RETRY_TAG_COMMIT" ]] || print -r -- "$RETRY_TAG_COMMIT"$'\t'"$3"
STUB
/bin/cat > "$retry_root/run.zsh" <<'STUB'
set -euo pipefail
source "$RETRY_SCRIPTS/release-policy.sh"
source "$RETRY_SCRIPTS/release-automation.sh"
fail() { print -u2 "retry guard: $1"; exit 1; }
git() { command "$RETRY_ROOT/git" "$@"; }
gh_tool="$RETRY_ROOT/gh"
release_repo=test/snip-snap
version=0.5.0
beta_tag=v0.5.0-beta.7
stable_tag=v0.5.0
source_commit="$RETRY_COMMIT"
existing_dir="$RETRY_ROOT/existing"
release_zip="$RETRY_ROOT/beta/Snip-Snap-0.5.0.zip"
release_dmg="$RETRY_ROOT/beta/Snip-Snap-0.5.0.dmg"
zip_checksum_file="$release_zip.sha256"
dmg_checksum_file="$release_dmg.sha256"
ios_notes="$RETRY_ROOT/ios.txt"
stable_notes="$RETRY_ROOT/notes.md"
eval "$(/usr/bin/awk '/^release_exists=0$/,/^fi$/' "$RETRY_SCRIPTS/$RETRY_SCRIPT")"
if [[ "$RETRY_SCRIPT" == promote-release.sh ]]; then
    eval "$(/usr/bin/awk '/^if \(\( ! release_exists \)\); then$/,/^fi$/' "$RETRY_SCRIPTS/$RETRY_SCRIPT")"
fi
print -r -- "release_exists=$release_exists"
STUB
/bin/chmod +x "$retry_root/gh" "$retry_root/git"
for retry_script in publish-beta.sh promote-release.sh; do
    /usr/bin/awk '/^release_exists=0$/,/^fi$/' "$script_dir/$retry_script" | \
        /usr/bin/grep -F 'release view' >/dev/null || \
        fail_test "$retry_script has no retry guard to run"
done

run_release_retry() {
    /bin/rm -rf "$retry_root/existing"
    /bin/mkdir -p "$retry_root/existing"
    : > "$retry_root/gh.log"
    RETRY_SCRIPTS="$script_dir" RETRY_ROOT="$retry_root" RETRY_COMMIT="$retry_commit" \
        RETRY_GH_LOG="$retry_root/gh.log" RETRY_PUBLISHED="$retry_root/published" \
        RETRY_SCRIPT="$1" RETRY_RELEASE_EXISTS="$2" RETRY_TAG_COMMIT="$3" \
        /bin/zsh "$retry_root/run.zsh" > "$retry_root/output" 2>&1
}
require_release_retry_stopped() {
    /usr/bin/grep -F 'retry guard:' "$retry_root/output" >/dev/null || \
        fail_test "$1 did not stop in its guard: $(<"$retry_root/output")"
    /usr/bin/grep -F 'release create' "$retry_root/gh.log" >/dev/null && \
        fail_test "$1 created a release"
    return 0
}

run_release_retry promote-release.sh 1 "$retry_commit" || \
    fail_test "stable retry rejected the matching release: $(<"$retry_root/output")"
/usr/bin/grep -Fx 'release_exists=1' "$retry_root/output" >/dev/null || \
    fail_test "stable retry did not keep the existing release"
/usr/bin/grep -F 'release download v0.5.0 ' "$retry_root/gh.log" >/dev/null || \
    fail_test "stable retry did not check the published files"
/usr/bin/grep -F 'release create' "$retry_root/gh.log" >/dev/null && \
    fail_test "stable retry created the release again"
run_release_retry promote-release.sh 0 "" || \
    fail_test "first stable promotion failed: $(<"$retry_root/output")"
[[ "$(/usr/bin/grep -c "^release create v0.5.0 .*--target $retry_commit" "$retry_root/gh.log")" == 1 ]] || \
    fail_test "first stable promotion did not create one release at the recorded commit"
print -rn -- 'other bytes' > "$retry_root/published/Snip-Snap-0.5.0.zip"
run_release_retry promote-release.sh 1 "$retry_commit" && \
    fail_test "stable retry accepted a release with a different ZIP"
require_release_retry_stopped "stable retry with a different ZIP"
/bin/cp "$retry_root/beta/Snip-Snap-0.5.0.zip" "$retry_root/published/"
for retry_script in publish-beta.sh promote-release.sh; do
    run_release_retry "$retry_script" 1 2222222222222222222222222222222222222222 && \
        fail_test "$retry_script accepted a release tag at another commit"
    require_release_retry_stopped "$retry_script with a moved tag"
    run_release_retry "$retry_script" 0 "$retry_commit" && \
        fail_test "$retry_script accepted a tag without a release"
    require_release_retry_stopped "$retry_script with an orphan tag"
done
run_release_retry publish-beta.sh 0 "" || \
    fail_test "first beta guard failed: $(<"$retry_root/output")"
/usr/bin/grep -Fx 'release_exists=0' "$retry_root/output" >/dev/null || \
    fail_test "first beta guard reported an existing release"

/usr/bin/grep -F 'Casks/snip-snap@beta.rb' "$script_dir/publish-beta.sh" >/dev/null || \
    fail_test "beta publish does not use the beta cask"
/usr/bin/grep -F 'Casks/snip-snap.rb' "$script_dir/promote-release.sh" >/dev/null || \
    fail_test "stable promotion does not use the stable cask"

/usr/bin/ruby -c "$script_dir/snip-snap-beta.rb.template" >/dev/null || \
    fail_test "invalid beta cask template"
for cask_template in snip-snap.rb.template snip-snap-beta.rb.template; do
    /usr/bin/grep -F 'binary "#{appdir}/Snip Snap.app/Contents/MacOS/snipsnap"' \
        "$script_dir/$cask_template" >/dev/null || \
        fail_test "$cask_template does not install the snipsnap CLI"
done

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

/usr/bin/ruby "$script_dir/ci-changes-tests.rb"
/usr/bin/ruby "$script_dir/release-notes-tests.rb"
/usr/bin/ruby "$script_dir/changelog-tests.rb"
/usr/bin/ruby "$script_dir/testflight-notes-tests.rb"

print "Release automation checks passed."
