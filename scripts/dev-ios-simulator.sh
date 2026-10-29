#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
source "$script_dir/signing-policy.sh"
source "$script_dir/share-fixture.sh"
simulator_id=""
build_log=""
ui_test=""
ui_group=""
list_ui_groups=NO
unit_test=""
selection_count=0
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
        --list-ui-groups)
            list_ui_groups=YES
            shift
            ;;
        --ui-test|--ui-group|--unit-test)
            (( $# >= 2 )) || { print -u2 "Missing value for $1"; exit 2; }
            [[ -n "$2" ]] || { print -u2 "Missing value for $1"; exit 2; }
            (( ++selection_count ))
            case "$1" in
                --ui-test) ui_test="$2" ;;
                --ui-group) ui_group="$2" ;;
                --unit-test) unit_test="$2" ;;
            esac
            shift 2
            ;;
        *)
            print -u2 "Usage: scripts/run.sh --ios-simulator [--simulator-id UUID] [--build-log PATH] [--ui-test METHOD|all | --ui-group GROUP | --unit-test CLASS|all] [--list-ui-groups] [--performance] [--no-test-diagnostics]"
            exit 2
            ;;
    esac
done

if (( selection_count > 1 )); then
    print -u2 "Choose either --ui-test, --ui-group, or --unit-test."
    exit 2
fi
if [[ "$list_ui_groups" == YES ]]; then
    if (( selection_count > 0 )) || [[ "$performance" == YES || "$test_diagnostics" == never ]]; then
        print -u2 -- "--list-ui-groups cannot be combined with test options."
        exit 2
    fi
    exec /usr/bin/ruby "$script_dir/ios-test-selection.rb" --list-ui-groups
fi
if [[ -n "$unit_test" ]]; then
    /usr/bin/ruby "$script_dir/ios-test-selection.rb" --unit-test "$unit_test" > /dev/null
fi
ui_methods=()
if [[ -n "$ui_test" || -n "$ui_group" ]]; then
    selection_option=--ui-test
    [[ -z "$ui_group" ]] || selection_option=--ui-group
    selected_methods="$(/usr/bin/ruby "$script_dir/ios-test-selection.rb" "$selection_option" "${ui_group:-$ui_test}")"
    ui_methods=("${(@f)selected_methods}")
fi
if [[ "$performance" == YES && -z "$ui_test" && -z "$ui_group" && -z "$unit_test" ]]; then
    print -u2 -- "--performance requires a UI or unit test selection."
    exit 2
fi
if [[ "$test_diagnostics" == never && -z "$ui_test" && -z "$ui_group" && -z "$unit_test" ]]; then
    print -u2 -- "--no-test-diagnostics requires a UI or unit test selection."
    exit 2
fi

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
cleanup() {
    share_fixture_cleanup
    /bin/rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

settings_file="$derived_data/resolved-build-settings.txt"
destination="platform=iOS Simulator,id=$simulator_id"
signing_policy_capture_build_settings "$repo_dir" Debug "$destination" "$settings_file" "$derived_data" SnipSnapiOS
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
xcodebuild "${build_arguments[@]}" "${build_actions[@]}" > "$build_log" 2>&1 || {
    /usr/bin/tail -n 60 "$build_log"
    exit 1
}
if [[ "$performance" == YES ]]; then
    print "Performance evidence: $evidence_file"
    /usr/bin/ruby -rjson -rshellwords -rtime - "$build_log" "$evidence_file" "$destination" "${ui_group:-${ui_test:-$unit_test}}" "$test_diagnostics" <<'RUBY'
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
if (( selection_count == 0 )); then
    xcrun simctl terminate "$simulator_id" "$bundle_identifier" 2>/dev/null || true
    xcrun simctl install "$simulator_id" "$app_path"
    xcrun simctl launch "$simulator_id" "$bundle_identifier"
    print "Opened Snip Snap iOS Dev $slot"
else
    print "Testing Snip Snap iOS Dev $slot"
fi
print "Simulator: $simulator_id"
print "Bundle: $bundle_identifier"
print "App: $app_path"
print "App group: group.$bundle_identifier"
if [[ -n "$ui_test" || -n "$ui_group" || -n "$unit_test" ]]; then
    test_arguments=(-collect-test-diagnostics "$test_diagnostics")
    test_scopes=()
    if (( ${#ui_methods} )); then
        needs_share_fixture=NO
        for method in "${ui_methods[@]}"; do
            test_scope="SnipSnapiOSUITests"
            [[ "$method" == all ]] || test_scope+="/SnipSnapiOSUITests/$method"
            test_scopes+=("-only-testing:$test_scope")
            case "$method" in
                all|testShareExtension*|testSharePageShowsEveryListThenSaves)
                    needs_share_fixture=YES ;;
            esac
        done
        test_kind="ui"
        if [[ "$needs_share_fixture" == YES ]]; then
            share_fixture_start "$derived_data" "$script_dir/local-share-fixture.py" "Snip Snap iOS Dev $slot" || exit $?
        fi
    else
        test_scope="SnipSnapiOSTests"
        [[ "$unit_test" == all ]] || test_scope+="/$unit_test"
        test_scopes+=("-only-testing:$test_scope")
        test_kind="unit"
    fi
    xcodebuild "${build_arguments[@]}" \
        "${test_arguments[@]}" \
        -parallel-testing-enabled NO \
        "${test_scopes[@]}" \
        "$test_action" > "${build_log:r}-$test_kind-test.log" 2>&1 || {
            /usr/bin/tail -n 80 "${build_log:r}-$test_kind-test.log"
            exit 1
        }
    print "Tests passed: ${test_scopes[*]}"
fi
