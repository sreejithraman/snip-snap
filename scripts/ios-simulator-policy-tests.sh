#!/bin/zsh
set -euo pipefail
source_script_dir="${0:A:h}"
test_dir="$(mktemp -d)"
script_dir="$test_dir/repo/scripts"
fixture_lock="$test_dir/snip-snap-share-fixture-58493.lock"
test_fixture_lock_owned=0
cleanup() {
 [[ "$test_fixture_lock_owned" == 0 ]] || /bin/rmdir "$fixture_lock" 2>/dev/null || true
 /bin/rm -rf "$test_dir"
}
trap cleanup EXIT
mkdir -p "$test_dir/bin" "$script_dir" "$test_dir/repo/SnipSnapiOSUITests" "$test_dir/repo/SnipSnapiOSTests"
# Exercise the runner with fake tools and a private lock, never the live fixture.
for script in run.sh dev-ios-simulator.sh signing-policy.sh share-fixture.sh \
 dev-slot.sh run-ios-simulator.sh ios-test-selection.rb local-share-fixture.py; do
 cp "$source_script_dir/$script" "$script_dir/"
done
cp "$source_script_dir/../SnipSnapiOSUITests/SnipSnapiOSUITests.swift" \
 "$test_dir/repo/SnipSnapiOSUITests/"
cp "$source_script_dir/../SnipSnapiOSTests/"*.swift "$test_dir/repo/SnipSnapiOSTests/"
/usr/bin/ruby - "$source_script_dir/share-fixture.sh" "$script_dir/share-fixture.sh" "$test_dir" <<'RUBY'
source, output, root = ARGV
text = File.read(source)
lock_prefix = '/private/tmp/snip-snap-share-fixture-'
abort 'Update private fixture-lock isolation before running this policy test' unless text.scan(lock_prefix).length == 1
File.write(output, text.sub(lock_prefix, "#{root}/snip-snap-share-fixture-"))
RUBY
export SNIP_SNAP_DEV_STATE_DIR="$test_dir/state"
export SNIP_SNAP_DEV_WORKTREE="${script_dir:h}"
export FAKE_SIM_LOG="$test_dir/sim.log"
export FAKE_BUILD_LOG="$test_dir/build.log"
export FAKE_FIXTURE_PID_FILE="$test_dir/fixture.pid"
export FAKE_FIXTURE_LOG="$test_dir/fixture.log"
export SNIP_SNAP_PYTHON="$test_dir/bin/python3"
unset SNIP_SNAP_DEV_SLOT SNIP_SNAP_IOS_DERIVED_DATA SNIP_SNAP_XCODEBUILD
cat > "$test_dir/bin/xcrun" <<'STUB'
#!/bin/zsh
if [[ "$*" == 'simctl list devices available --json' ]]; then
 print -r -- '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"state":"Booted","udid":"TEST-SIM"}]}}'
elif [[ "$1" == simctl ]]; then
 [[ ! -e "$FAKE_FIXTURE_PID_FILE" ]] || { print -u2 'The fixture started before app opening'; exit 1; }
 print -r -- "$*" >> "$FAKE_SIM_LOG"
fi
STUB
cat > "$test_dir/bin/xcodebuild" <<'STUB'
#!/bin/zsh
if [[ "$*" == *'-showBuildSettings'* ]]; then
 print -r -- 'Build settings for action build and target SnipSnapiOS:'
 print -r -- '    SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap.ios'
 print -r -- '    PRODUCT_NAME = Snip Snap iOS'
 print -r -- '    CLANG_ENABLE_CODE_COVERAGE = NO'
 exit 0
fi
print -r -- "$*" >> "$FAKE_BUILD_LOG"
if [[ "${argv[-1]}" == build-for-testing ]]; then
 if [[ "${FAKE_COMPILER_EVIDENCE:-}" != missing ]]; then
  print -r -- "SwiftDriver SnipSnap_iOS normal arm64 com.apple.xcode.tools.swift.compiler (in target 'SnipSnapiOS' from project 'SnipSnap')"
  compiler_arguments='-module-name SnipSnap_iOS -Onone -g -enable-testing -c /source/App.swift'
  case "${FAKE_COMPILER_EVIDENCE:-}" in
   covered) compiler_arguments+=' -profile-generate -profile-coverage-mapping';;
   response)
    print -r -- '-profile-generate -profile-coverage-mapping' > "$FAKE_COMPILER_RESPONSE"
    compiler_arguments+=" @${(q)FAKE_COMPILER_RESPONSE}";;
  esac
  print -r -- "    builtin-SwiftDriver -- /toolchain/usr/bin/swiftc $compiler_arguments"
 fi
 # A dependency's flags cannot prove whether the app is instrumented.
 print -r -- "SwiftDriver SnipSnapCore normal arm64 com.apple.xcode.tools.swift.compiler (in target 'SnipSnapCore' from project 'SnipSnapLibrary')"
 print -r -- '    builtin-SwiftDriver -- /toolchain/usr/bin/swiftc -module-name SnipSnapCore -profile-generate -profile-coverage-mapping -c /source/Core.swift'
fi
if [[ "${argv[-1]}" == test* && "${FAKE_EXPECT_FIXTURE:-0}" == 1 ]]; then
 [[ -s "$FAKE_FIXTURE_PID_FILE" ]] && /bin/kill -0 "$(cat "$FAKE_FIXTURE_PID_FILE")" || {
  print -u2 'The Share fixture was not ready before xcodebuild test'; exit 1
 }
elif [[ -e "$FAKE_FIXTURE_PID_FILE" ]]; then
 print -u2 'A build or unrelated UI test started the Share fixture'; exit 1
fi
if [[ "${argv[-1]}" == test* ]]; then
 case "${FAKE_UI_TEST_OUTCOME:-}" in
  failure) exit 23;;
  INT|TERM) /bin/kill -s "$FAKE_UI_TEST_OUTCOME" "$PPID"; exit 0;;
 esac
fi
while (( $# )); do
 case "$1" in
 -derivedDataPath) build_root="$2"; shift 2;;
 SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER=*) bundle_id="${1#*=}"; shift;;
 *) shift;;
 esac
done
[[ "${FAKE_WRONG_ID:-}" != 1 ]] || bundle_id=org.example.production
mkdir -p "$build_root/Build/Products/Debug-iphonesimulator/Snip Snap iOS.app"
plist="$build_root/Build/Products/Debug-iphonesimulator/Snip Snap iOS.app/Info.plist"
rm -f "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$plist" >/dev/null
STUB
cat > "$test_dir/bin/python3" <<'STUB'
#!/bin/zsh
set -euo pipefail
[[ -f "$2/index.html" ]] || exit 1
[[ "$4" == 58493 ]] || exit 1
[[ "${FAKE_FIXTURE_START_FAILURE:-0}" != 1 ]] || { print -u2 'Fixture startup failed'; exit 29; }
print -r -- "$$" > "$FAKE_FIXTURE_PID_FILE"
print -r -- "$$" >> "$FAKE_FIXTURE_LOG"
trap 'rm -f "$FAKE_FIXTURE_PID_FILE"; exit 0' TERM INT
print -r -- "${FAKE_FIXTURE_RETURNED_PORT:-$4}" > "$3"
while true; do /bin/sleep 0.05; done
STUB
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
"$script_dir/run.sh" --ios-simulator --simulator-id TEST-SIM > "$test_dir/output"
grep -F 'simctl install TEST-SIM' "$FAKE_SIM_LOG" >/dev/null
grep -F 'simctl launch TEST-SIM org.example.snipsnap.ios.dev1' "$FAKE_SIM_LOG" >/dev/null
for required in \
 'SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER=org.example.snipsnap.ios.dev1.share' \
 'SNIP_SNAP_APP_GROUP_IDENTIFIER=group.org.example.snipsnap.ios.dev1' \
 'SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER=' \
 'SNIP_SNAP_DISPLAY_NAME=Snip Snap Dev 1' \
 'ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev'; do
 grep -F "$required" "$FAKE_BUILD_LOG" >/dev/null
done
if grep -E '(^| )CODE_SIGN_ENTITLEMENTS=' "$FAKE_BUILD_LOG" >/dev/null; then
 print -u2 'Global app entitlements would affect package targets'; exit 1
fi
grep -F 'SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS=' "$FAKE_BUILD_LOG" >/dev/null
cp "$FAKE_SIM_LOG" "$test_dir/before-test-selection"
"$script_dir/run.sh" --ios-simulator --simulator-id TEST-SIM --unit-test IOSAppModelTests > "$test_dir/output"
grep -F -- '-only-testing:SnipSnapiOSTests/IOSAppModelTests' "$FAKE_BUILD_LOG" >/dev/null
if ! cmp -s "$test_dir/before-test-selection" "$FAKE_SIM_LOG"; then
 print -u2 'Selected tests must let XCTest manage Dev app installation and launch'; exit 1
fi
"$script_dir/run.sh" --ios-simulator --unit-test all > "$test_dir/output"
[[ "$(tail -n 1 "$FAKE_BUILD_LOG")" == *'-only-testing:SnipSnapiOSTests test' ]] || {
 print -u2 'The full unit selection did not select the unit target'; exit 1
}
"$script_dir/run.sh" --ios-simulator --ui-group smoke > "$test_dir/output"
if ! cmp -s "$test_dir/before-test-selection" "$FAKE_SIM_LOG"; then
 print -u2 'A UI group manually opened the app before XCTest'; exit 1
fi
/usr/bin/ruby - "$FAKE_BUILD_LOG" <<'RUBY'
line = File.readlines(ARGV.fetch(0)).last
expected = %w[
 testCreatesAndEditsTextSnip testCopiesTextOnlySnip
 testTappingCompletionCircleTogglesWithoutEditingOrSelecting
 testListSwipeSwitchesListsFromAVisibleRow testSelectionPersistsAcrossLists
].map { |method| "-only-testing:SnipSnapiOSUITests/SnipSnapiOSUITests/#{method}" }
abort 'A group did not select exactly its workflows in one test action' unless
 line.scan(/-only-testing:\S+/) == expected && line.end_with?(" test\n")
RUBY
if [[ "$(tail -n 1 "$FAKE_BUILD_LOG")" == *'-enableCodeCoverage NO'* ]]; then
 print -u2 'An ordinary test run disabled coverage'; exit 1
fi
"$script_dir/run.sh" --ios-simulator --unit-test IOSAppModelTests --performance > "$test_dir/output" 2>&1 || {
 cat "$test_dir/output" >&2; exit 1
}
grep -F -- '-enableCodeCoverage NO clean build-for-testing' "$FAKE_BUILD_LOG" >/dev/null
grep -F -- '-enableCodeCoverage NO -collect-test-diagnostics on-failure -parallel-testing-enabled NO -only-testing:SnipSnapiOSTests/IOSAppModelTests test-without-building' "$FAKE_BUILD_LOG" >/dev/null
evidence="$SNIP_SNAP_DEV_STATE_DIR/build/ios-slot-1/build-performance.json"
/usr/bin/ruby -rjson -e '
 evidence = JSON.parse(File.read(ARGV.fetch(0)))
 abort "Missing verified app compiler evidence" unless evidence.fetch("verified") &&
   evidence.fetch("configuration") == "Debug" && evidence.fetch("coverage") == "disabled" &&
   evidence.fetch("compiler_commands").one? && evidence.fetch("compiler_commands").first.include?("-Onone")
' "$evidence"
cp "$FAKE_SIM_LOG" "$test_dir/before-performance-rejection"
export FAKE_COMPILER_RESPONSE="$test_dir/coverage flags.resp"
for compiler_evidence in covered response missing; do
 if FAKE_COMPILER_EVIDENCE="$compiler_evidence" \
  "$script_dir/run.sh" --ios-simulator --unit-test IOSAppModelTests --performance > "$test_dir/output" 2>&1; then
  print -u2 "Performance mode accepted $compiler_evidence compiler evidence"; exit 1
 fi
 cmp "$test_dir/before-performance-rejection" "$FAKE_SIM_LOG"
 [[ "$(tail -n 1 "$FAKE_BUILD_LOG")" == *' build-for-testing' ]] || {
  print -u2 'Tests ran after performance compiler verification failed'; exit 1
 }
 /usr/bin/ruby -rjson -e '
  evidence = JSON.parse(File.read(ARGV.fetch(0)))
  abort "Missing failed verification evidence" unless evidence.fetch("verified") == false && evidence.fetch("error").length > 0
 ' "$evidence"
done
"$script_dir/run.sh" --ios-simulator --ui-test testCopiesTextOnlySnip --no-test-diagnostics > "$test_dir/output" 2>&1 || {
 cat "$test_dir/output" >&2; exit 1
}
[[ "$(tail -n 1 "$FAKE_BUILD_LOG")" == *'-collect-test-diagnostics never'*' test' ]] || {
 print -u2 'The opt-in UI run did not disable test diagnostics'; exit 1
}
"$script_dir/run.sh" --ios-simulator --ui-test testCopiesTextOnlySnip > "$test_dir/output" 2>&1
[[ "$(tail -n 1 "$FAKE_BUILD_LOG")" == *'-collect-test-diagnostics on-failure'* ]] || {
 print -u2 'An ordinary UI run did not retain failure diagnostics'; exit 1
}
"$script_dir/run.sh" --ios-simulator --unit-test IOSAppModelTests --no-test-diagnostics > "$test_dir/output" 2>&1 || {
 cat "$test_dir/output" >&2; exit 1
}
[[ "$(tail -n 1 "$FAKE_BUILD_LOG")" == *'-collect-test-diagnostics never'*'-only-testing:SnipSnapiOSTests/IOSAppModelTests test' ]] || {
 print -u2 'The opt-in unit run did not disable test diagnostics'; exit 1
}
for arguments in '--performance' '--no-test-diagnostics'; do
 cp "$FAKE_BUILD_LOG" "$test_dir/before-invalid-options"
 if "$script_dir/run.sh" --ios-simulator ${=arguments} > "$test_dir/output" 2>&1; then
  print -u2 "Accepted invalid simulator test options: $arguments"; exit 1
 fi
 cmp "$test_dir/before-invalid-options" "$FAKE_BUILD_LOG"
done
"$script_dir/run.sh" --ios-simulator --ui-test testCopiesTextOnlySnip --performance --no-test-diagnostics \
 --build-log "$test_dir/custom logs/performance.log" > "$test_dir/output" 2>&1 || {
 cat "$test_dir/output" >&2; exit 1
}
[[ "$(tail -n 1 "$FAKE_BUILD_LOG")" == *'-enableCodeCoverage NO'*'-collect-test-diagnostics never'*' test-without-building' ]] || {
 print -u2 'Performance UI tests did not combine coverage and diagnostics options'; exit 1
}
/usr/bin/ruby -rjson -e '
 evidence = JSON.parse(File.read(ARGV.fetch(0)))
 abort "Missing combined performance configuration" unless evidence.fetch("verified") &&
   evidence.fetch("test_diagnostics") == "never" && evidence.fetch("optimization_flags") == ["-Onone"] &&
   evidence.fetch("coverage_flags") == [] && File.file?(evidence.fetch("build_log"))
' "$test_dir/custom logs/performance-performance.json"
"$script_dir/run.sh" --ios-simulator --unit-test IOSAppModelTests > "$test_dir/output" 2>&1
[[ "$(tail -n 1 "$FAKE_BUILD_LOG")" != *'-enableCodeCoverage NO'* ]] || {
 print -u2 'A later ordinary test inherited performance coverage settings'; exit 1
}
[[ "$(tail -n 1 "$FAKE_BUILD_LOG")" == *'-collect-test-diagnostics on-failure'* ]] || {
 print -u2 'A later ordinary unit run did not restore failure diagnostics'; exit 1
}
if "$script_dir/run.sh" --ios-simulator --simulator-id TEST-SIM --unit-test IOSAppModelTests --ui-test testCopiesTextOnlySnip > "$test_dir/output" 2>&1; then
 print -u2 'Accepted simultaneous UI and unit test selectors'; exit 1
fi
cp "$FAKE_SIM_LOG" "$test_dir/before"
if "$script_dir/run.sh" --ios-simulator --simulator-id NOT-BOOTED > "$test_dir/output" 2>&1; then
 print -u2 'Accepted a simulator that was not booted'; exit 1
fi
cmp "$test_dir/before" "$FAKE_SIM_LOG"
if FAKE_WRONG_ID=1 "$script_dir/run.sh" --ios-simulator > "$test_dir/output" 2>&1; then
 print -u2 'Accepted a build with the wrong bundle ID'; exit 1
fi
cmp "$test_dir/before" "$FAKE_SIM_LOG"
"$script_dir/run.sh" ios-simulator TEST-SIM > "$test_dir/output"
if ! FAKE_EXPECT_FIXTURE=1 "$script_dir/run.sh" --ios-simulator --simulator-id TEST-SIM --ui-test all > "$test_dir/output" 2>&1; then
 cat "$test_dir/output" >&2
 exit 1
fi
if ! grep -F -- '-only-testing:SnipSnapiOSUITests test' "$FAKE_BUILD_LOG" >/dev/null; then
 print -u2 'The full UI suite must run against the isolated Dev app'; exit 1
fi
assert_fixture_cleaned_up() {
 [[ ! -e "$fixture_lock" && ! -e "$FAKE_FIXTURE_PID_FILE" ]] || {
  print -u2 'The runner left its fixture child or port lock behind'; exit 1
 }
 local fixture_pid
 for fixture_pid in ${(f)"$(cat "$FAKE_FIXTURE_LOG")"}; do
  if /bin/kill -0 "$fixture_pid" 2>/dev/null; then
   print -u2 'The runner left its fixture child alive'; exit 1
  fi
 done
 local -a fixture_directories=("$SNIP_SNAP_DEV_STATE_DIR"/build/ios-slot-1/share-fixture.*(N))
 (( ${#fixture_directories} == 0 )) || { print -u2 'The runner left fixture files behind'; exit 1; }
 [[ ! -e "$SNIP_SNAP_DEV_STATE_DIR/locks/ios-slot-1" ]] || {
  print -u2 'The runner left its Dev slot locked'; exit 1
 }
}
assert_fixture_cleaned_up
FAKE_EXPECT_FIXTURE=1 "$script_dir/run.sh" --ios-simulator --ui-group share > "$test_dir/output" 2>&1 || {
 cat "$test_dir/output" >&2; exit 1
}
assert_fixture_cleaned_up
for test_name in \
 testShareExtensionImportsExactlyOnceWhileMainAppIsOpen \
 testShareExtensionImportsExactlyOnceWhileMainAppIsClosed \
 testShareExtensionDefersExactlyOnceWhileMainStoreIsUnavailable \
 testSharePageShowsEveryListThenSaves; do
 FAKE_EXPECT_FIXTURE=1 "$script_dir/run.sh" --ios-simulator --ui-test "$test_name" > "$test_dir/output" 2>&1 || {
  cat "$test_dir/output" >&2; exit 1
 }
 assert_fixture_cleaned_up
done
cp "$FAKE_FIXTURE_LOG" "$test_dir/fixture-before"
for test_name in testSharesSnipBackIntoSnipSnap testQuickComposerSendsWithoutOpeningTheEditor; do
 "$script_dir/run.sh" --ios-simulator --ui-test "$test_name" > "$test_dir/output" 2>&1
 cmp "$test_dir/fixture-before" "$FAKE_FIXTURE_LOG"
 assert_fixture_cleaned_up
done
for outcome in failure INT TERM; do
 if FAKE_EXPECT_FIXTURE=1 FAKE_UI_TEST_OUTCOME="$outcome" \
  "$script_dir/run.sh" --ios-simulator --ui-test all > "$test_dir/output" 2>&1; then
  print -u2 "The runner hid a UI test $outcome"; exit 1
 fi
 assert_fixture_cleaned_up
done
if FAKE_EXPECT_FIXTURE=1 FAKE_UI_TEST_OUTCOME=failure \
 "$script_dir/run.sh" --ios-simulator --ui-test all --performance --no-test-diagnostics > "$test_dir/output" 2>&1; then
 print -u2 'The runner hid a performance UI test failure with diagnostics disabled'; exit 1
fi
assert_fixture_cleaned_up
[[ "$(tail -n 1 "$FAKE_BUILD_LOG")" == *' test-without-building' ]] || {
 print -u2 'Performance UI testing failed before its test action'; exit 1
}
for fixture_failure in FAKE_FIXTURE_START_FAILURE=1 FAKE_FIXTURE_RETURNED_PORT=12345; do
 if env "$fixture_failure" FAKE_EXPECT_FIXTURE=1 \
  "$script_dir/run.sh" --ios-simulator --ui-test all > "$test_dir/output" 2>&1; then
  print -u2 'The runner accepted an unavailable Share fixture'; exit 1
 fi
 [[ "$(tail -n 1 "$FAKE_BUILD_LOG")" == *' build' ]] || {
  print -u2 'UI testing began without a ready fixture'; exit 1
 }
 assert_fixture_cleaned_up
done
/bin/mkdir "$fixture_lock"
test_fixture_lock_owned=1
cp "$FAKE_FIXTURE_LOG" "$test_dir/fixture-before"
if FAKE_EXPECT_FIXTURE=1 "$script_dir/run.sh" --ios-simulator --ui-test all > "$test_dir/output" 2>&1; then
 print -u2 'The runner accepted an already owned fixture port'; exit 1
fi
[[ -d "$fixture_lock" ]] || { print -u2 'The runner removed another fixture lock'; exit 1; }
cmp "$test_dir/fixture-before" "$FAKE_FIXTURE_LOG"
grep -F 'another Share fixture owns loopback port 58493' "$test_dir/output" >/dev/null
/bin/rmdir "$fixture_lock"
test_fixture_lock_owned=0
assert_fixture_cleaned_up
cp "$FAKE_SIM_LOG" "$test_dir/before"
mkdir -p "$SNIP_SNAP_DEV_STATE_DIR/locks/ios-slot-1"
for arguments in '--ios-simulator --simulator-id TEST-SIM' 'ios-simulator TEST-SIM'; do
 if "$script_dir/run.sh" ${=arguments} > "$test_dir/output" 2>&1; then
  print -u2 'Accepted a launch while its slot was locked'; exit 1
 fi
 cmp "$test_dir/before" "$FAKE_SIM_LOG"
done
print 'iOS Simulator Dev policy tests passed (performance compiler evidence, diagnostics options, fixture admission, 4 focused Share cases, cleanup, collisions, and isolation).'
