#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
source "$script_dir/signing-policy.sh"
source "$script_dir/share-fixture.sh"
simulator_id=""
build_log=""
ui_test=""
unit_test=""
performance=NO
test_diagnostics=on-failure
while (( $# )); do
    case "$1" in
        --performance)
            performance=YES
            shift
            ;;
        --no-test-diagnostics)
            test_diagnostics=never
            shift
            ;;
        --simulator-id|--build-log)
            (( $# >= 2 )) || { print -u2 "Missing value for $1"; exit 2; }
            if [[ "$1" == --simulator-id ]]; then simulator_id="$2"; else build_log="$2"; fi
            shift 2
            ;;
        --ui-test|--unit-test)
            (( $# >= 2 )) || { print -u2 "Missing value for $1"; exit 2; }
            [[ -n "$2" ]] || { print -u2 "Missing value for $1"; exit 2; }
            if [[ "$1" == --ui-test ]]; then ui_test="$2"; else unit_test="$2"; fi
            shift 2
            ;;
        *)
            print -u2 "Usage: scripts/run.sh --ios-simulator [--simulator-id UUID] [--build-log PATH] [--ui-test TEST_NAME | --unit-test TEST_CLASS] [--performance] [--no-test-diagnostics]"
            exit 2
            ;;
    esac
done

if [[ -n "$ui_test" && -n "$unit_test" ]]; then
    print -u2 "Choose either --ui-test or --unit-test."
    exit 2
fi
if [[ "$performance" == YES && -z "$ui_test" && -z "$unit_test" ]]; then
    print -u2 -- "--performance requires --ui-test or --unit-test."
    exit 2
fi
if [[ "$test_diagnostics" == never && -z "$ui_test" && -z "$unit_test" ]]; then
    print -u2 -- "--no-test-diagnostics requires --ui-test or --unit-test."
    exit 2
fi

setup_timeout="${SNIP_SNAP_SIMULATOR_SETUP_TIMEOUT_SECONDS:-60}"
/usr/bin/ruby -e '
    seconds = Float(ARGV.fetch(0)) rescue nil
    abort "Simulator setup timeout must be a positive number of seconds." unless seconds && seconds.finite? && seconds.positive?
' "$setup_timeout"

# Require a booted iOS device; never boot or alter a user's other simulators.
simulator_id="$(xcrun simctl list devices available --json | /usr/bin/ruby -rjson -e '
devices = JSON.parse(STDIN.read).fetch("devices").select { |runtime, _| runtime.include?("iOS") }.values.flatten
booted = devices.select { |device| device["state"] == "Booted" }
requested = ARGV.fetch(0)
selected = requested.empty? ? (booted.one? ? booted.first : nil) : booted.find { |device| device["udid"] == requested }
abort "Select one booted iOS simulator with --simulator-id UUID (or boot one in Simulator)." unless selected
puts selected.fetch("udid")
' "$simulator_id")"

slot="$("$script_dir/dev-slot.sh" claim)"
dev_state_dir="${SNIP_SNAP_DEV_STATE_DIR:-$HOME/Library/Application Support/Snip Snap/Development}"
derived_data="${SNIP_SNAP_IOS_DERIVED_DATA:-$dev_state_dir/build/ios-slot-$slot}"
lock_dir="$dev_state_dir/locks/ios-slot-$slot"
/bin/mkdir -p "${lock_dir:h}" "$derived_data"
if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
    print -u2 "Snip Snap iOS Dev $slot is already building or starting. Check $lock_dir."
    exit 1
fi
owned_command_pid=""
run_owned_command() {
    local timeout_seconds="$1"
    shift
    local command_status=0
    /usr/bin/ruby "$script_dir/owned-command.rb" "$timeout_seconds" "$lock_dir/active-command" "$@" &
    owned_command_pid=$!
    wait "$owned_command_pid" || command_status=$?
    owned_command_pid=""
    return "$command_status"
}
cleanup() {
    if [[ -n "$owned_command_pid" ]]; then
        /bin/kill -TERM "$owned_command_pid" 2>/dev/null || true
        wait "$owned_command_pid" 2>/dev/null || true
    fi
    share_fixture_cleanup
    /bin/rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

settings_file="$derived_data/resolved-build-settings.txt"
destination="platform=iOS Simulator,id=$simulator_id"
run_owned_command 0 /bin/zsh -c '
    source "$1"
    shift
    signing_policy_capture_build_settings "$@"
' snip-snap-settings "$script_dir/signing-policy.sh" "$repo_dir" Debug "$destination" "$settings_file" "$derived_data" SnipSnapiOS || exit $?
base_identifier="$(signing_policy_resolve_setting "$settings_file" SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER SnipSnapiOS)"
product_name="$(signing_policy_resolve_setting "$settings_file" PRODUCT_NAME SnipSnapiOS)"
[[ -n "$base_identifier" && -n "$product_name" ]] || { print -u2 "Could not resolve iOS app identity."; exit 1; }
bundle_identifier="$base_identifier.dev$slot"
app_path="$derived_data/Build/Products/Debug-iphonesimulator/$product_name.app"
build_log="${build_log:-$derived_data/build.log}"
/bin/mkdir -p "${build_log:h}"
print "Building Snip Snap iOS Dev $slot. Log: $build_log"
build_arguments=(
    -project "$repo_dir/SnipSnap.xcodeproj" -scheme SnipSnapiOS
    -configuration Debug -destination "$destination" -derivedDataPath "$derived_data"
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= "PROVISIONING_PROFILE_SPECIFIER="
    "SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS=$repo_dir/SnipSnapiOS/SnipSnapiOS.entitlements"
    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER=
    ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev
    "SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER=$bundle_identifier"
    "SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER=$bundle_identifier.share"
    "SNIP_SNAP_APP_GROUP_IDENTIFIER=group.$bundle_identifier"
    "SNIP_SNAP_DISPLAY_NAME=Snip Snap Dev $slot"
    "SNIP_SNAP_SHARE_DISPLAY_NAME=Save to Snip Snap Dev $slot"
)
build_actions=(build)
test_action=test
if [[ "$performance" == YES ]]; then
    # Rebuild so verification observes this run's compiler flags, even on a warm cache.
    print "Performance mode: Debug, coverage disabled, clean build-for-testing; diagnostics: $test_diagnostics"
    build_arguments+=(-enableCodeCoverage NO)
    build_actions=(clean build-for-testing)
    test_action=test-without-building
    evidence_file="${build_log:r}-performance.json"
    /bin/rm -f "$evidence_file"
fi
run_owned_command 0 xcodebuild "${build_arguments[@]}" "${build_actions[@]}" > "$build_log" 2>&1 || {
    /usr/bin/tail -n 60 "$build_log"
    exit 1
}
if [[ "$performance" == YES ]]; then
    print "Performance evidence: $evidence_file"
    /usr/bin/ruby -rjson -rshellwords -rtime - "$build_log" "$evidence_file" "$destination" "${ui_test:-$unit_test}" "$test_diagnostics" <<'RUBY'
log, output, destination, selector, diagnostics = ARGV
commands = []
app_driver = false
File.foreach(log) do |line|
  if line.include?("(in target '")
    app_driver = line.start_with?('SwiftDriver ') && line.include?("(in target 'SnipSnapiOS' ")
  elsif app_driver && line.match?(/\bswiftc\s/)
    commands << line.strip
  end
end
evidence = {
  'recorded_at' => Time.now.utc.iso8601, 'configuration' => 'Debug',
  'scheme' => 'SnipSnapiOS', 'target' => 'SnipSnapiOS', 'destination' => destination,
  'test_selector' => selector, 'build_action' => 'clean build-for-testing',
  'test_action' => 'test-without-building', 'enableCodeCoverage' => 'NO',
  'test_diagnostics' => diagnostics,
  'build_log' => File.expand_path(log), 'compiler_commands' => commands, 'verified' => false
}
begin
  raise 'No app Swift compiler command found in the clean build log' if commands.empty?
  expand = lambda do |arguments, depth|
    raise 'Compiler response files are nested too deeply' if depth > 8
    arguments.flat_map do |argument|
      argument.start_with?('@') ? expand.call(Shellwords.split(File.read(argument[1..-1])), depth + 1) : [argument]
    end
  end
  arguments = commands.map { |command| expand.call(Shellwords.split(command), 0) }
  coverage = arguments.flatten.grep(/\A-(?:profile-(?:generate|coverage-mapping)|(?:f|cs-|ir-)profile-generate|fprofile-instr-generate|fcoverage-mapping)/)
  evidence['compiler_arguments'] = arguments
  evidence['coverage_flags'] = coverage
  evidence['optimization_flags'] = arguments.flatten.grep(/\A-O/).uniq
  raise "App compiler still enables coverage: #{coverage.join(' ')}" unless coverage.empty?
  evidence['coverage'] = 'disabled'
  evidence['verified'] = true
rescue StandardError => error
  evidence['error'] = error.message
ensure
  File.write(output, JSON.pretty_generate(evidence) + "\n")
end
abort "Performance verification failed: #{evidence['error']} (#{output})" unless evidence['verified']
RUBY
fi

actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
[[ "$actual_identifier" == "$bundle_identifier" ]] || { print -u2 "Dev bundle identity did not match."; exit 1; }
run_simulator_stage() {
    local stage="$1"
    shift
    local stage_log="${build_log:r}-$stage.log"
    local stage_status=0
    print "Simulator $stage (timeout ${setup_timeout}s). Log: $stage_log"
    run_owned_command "$setup_timeout" xcrun simctl "$stage" "$simulator_id" "$@" > "$stage_log" 2>&1 || stage_status=$?
    if (( stage_status != 0 )); then
        print -u2 "Simulator $stage ended with status $stage_status. Log: $stage_log"
        /usr/bin/tail -n 40 "$stage_log" >&2
    fi
    return "$stage_status"
}
if run_simulator_stage terminate "$bundle_identifier"; then
    :
else
    terminate_status=$?
    # An app that is not running needs no termination; timeouts still stop setup.
    if (( terminate_status == 124 || terminate_status == 130 || terminate_status == 143 )); then
        exit "$terminate_status"
    fi
fi
run_simulator_stage install "$app_path" || exit $?
if [[ -n "$ui_test" || -n "$unit_test" ]]; then
    print "Prepared Snip Snap iOS Dev $slot for testing"
else
    run_simulator_stage launch "$bundle_identifier" || exit $?
    print "Opened Snip Snap iOS Dev $slot"
fi
print "Simulator: $simulator_id"
print "Bundle: $bundle_identifier"
print "App: $app_path"
print "App group: group.$bundle_identifier"
if [[ -n "$ui_test" || -n "$unit_test" ]]; then
    test_arguments=(-collect-test-diagnostics "$test_diagnostics")
    if [[ -n "$ui_test" ]]; then
        test_scope="SnipSnapiOSUITests"
        if [[ "$ui_test" != all ]]; then
            test_scope+="/SnipSnapiOSUITests/$ui_test"
        fi
        test_kind="ui"
        case "$ui_test" in
            all|testShareExtension*|testSharePageShowsEveryListThenSaves)
                share_fixture_start "$derived_data" "$script_dir/local-share-fixture.py" "Snip Snap iOS Dev $slot" || exit $?
                ;;
        esac
    else
        test_scope="SnipSnapiOSTests"
        if [[ "$unit_test" != all ]]; then
            test_scope+="/$unit_test"
        fi
        test_kind="unit"
    fi
    TEST_RUNNER_SNIP_SNAP_SHARE_FIXTURE_URL="$share_fixture_url" \
    run_owned_command 0 xcodebuild "${build_arguments[@]}" \
        "${test_arguments[@]}" \
        -parallel-testing-enabled NO \
        "-only-testing:$test_scope" \
        "$test_action" > "${build_log:r}-$test_kind-test.log" 2>&1 || {
            /usr/bin/tail -n 80 "${build_log:r}-$test_kind-test.log"
            exit 1
        }
    print "Test passed: $test_scope"
fi
