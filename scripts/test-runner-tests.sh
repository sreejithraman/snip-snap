#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_root="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$test_root"' EXIT
fixture="$test_root/repo"
/bin/mkdir -p "$fixture/scripts" "$test_root/bin"
/bin/cp "$script_dir/test.sh" "$script_dir/derived-data.sh" \
    "$script_dir/ios-bundle-check.sh" "$fixture/scripts/"

# Stub policy checks so this exercises the real runner without recursive tests.
for policy in "$script_dir"/*-tests.sh "$script_dir/tracked-input-policy.sh"; do
    print -r -- '#!/bin/zsh
print -r -- "policy:${0:t}" >> "$SNIP_SNAP_TEST_CALLS"' > "$fixture/scripts/${policy:t}"
    /bin/chmod +x "$fixture/scripts/${policy:t}"
done

cat > "$test_root/bin/swift" <<'SWIFT'
#!/bin/zsh
print -r -- "swift:$*" >> "$SNIP_SNAP_TEST_CALLS"
[[ "${SNIP_SNAP_TEST_FAILURE:-}" != package ]]
SWIFT

cat > "$test_root/bin/xcodebuild" <<'XCODEBUILD'
#!/bin/zsh
set -euo pipefail
print -r -- "xcodebuild:$*" >> "$SNIP_SNAP_TEST_CALLS"
derived_data=""
scheme=""
while (( $# )); do
    case "$1" in
        -derivedDataPath) derived_data="$2"; shift 2 ;;
        -scheme) scheme="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ "${SNIP_SNAP_TEST_FAILURE:-}" != "$scheme" ]] || exit 65
if [[ "$scheme" == SnipSnapiOS ]]; then
    app="$derived_data/Build/Products/Debug-iphonesimulator/Snip Snap iOS.app"
    extension="$app/PlugIns/SnipSnapShareExtension.appex"
    /bin/mkdir -p "$extension"
    /usr/bin/touch "$app/Snip Snap iOS" "$app/PrivacyInfo.xcprivacy" \
        "$extension/Info.plist" "$extension/SnipSnapShareExtension" \
        "$extension/PrivacyInfo.xcprivacy"
    if [[ -n "${SNIP_SNAP_TEST_MISSING_FILE:-}" ]]; then
        /bin/rm -rf "$app/$SNIP_SNAP_TEST_MISSING_FILE"
    fi
fi
XCODEBUILD
/bin/chmod +x "$test_root/bin/swift" "$test_root/bin/xcodebuild"

export SNIP_SNAP_TEST_CALLS="$test_root/calls"
export PATH="$test_root/bin:$PATH"
unset SNIP_SNAP_DERIVED_DATA
unset SNIP_SNAP_TEST_FAILURE SNIP_SNAP_TEST_MISSING_FILE

run_tests() {
    : > "$SNIP_SNAP_TEST_CALLS"
    "$fixture/scripts/test.sh" "$@" > "$test_root/output" 2>&1
}

assert_groups() {
    local common="$1" mac="$2" ios="$3"
    [[ "$(/usr/bin/grep -c '^swift:' "$SNIP_SNAP_TEST_CALLS" || true)" == "$common" ]]
    [[ "$(/usr/bin/grep -c '^policy:release-policy-tests.sh$' "$SNIP_SNAP_TEST_CALLS" || true)" == "$common" ]]
    [[ "$(/usr/bin/grep -c -- '-scheme SnipSnap ' "$SNIP_SNAP_TEST_CALLS" || true)" == "$mac" ]]
    [[ "$(/usr/bin/grep -c -- '-scheme SnipSnapiOS ' "$SNIP_SNAP_TEST_CALLS" || true)" == "$ios" ]]
    [[ "$(/usr/bin/grep -c '^xcodebuild:' "$SNIP_SNAP_TEST_CALLS" || true)" == "$(( mac + ios ))" ]]
}

run_tests
assert_groups 1 1 1
run_tests --mac-only
assert_groups 1 1 0
run_tests --ios-only
assert_groups 0 0 1
/usr/bin/grep -F -- '-only-testing:SnipSnapiOSTests test' "$SNIP_SNAP_TEST_CALLS" >/dev/null
/usr/bin/grep -F -- '-parallel-testing-enabled NO' "$SNIP_SNAP_TEST_CALLS" >/dev/null
/usr/bin/grep -F -- 'CODE_SIGNING_ALLOWED=NO' "$SNIP_SNAP_TEST_CALLS" >/dev/null
run_tests --without-mac-app-tests
assert_groups 1 0 1

for arguments in '--unknown' '--mac-only --ios-only'; do
    if run_tests ${=arguments}; then
        print -u2 "Test runner accepted invalid arguments: $arguments"
        exit 1
    fi
    [[ ! -s "$SNIP_SNAP_TEST_CALLS" ]]
done

for failure in package SnipSnap SnipSnapiOS; do
    if SNIP_SNAP_TEST_FAILURE="$failure" run_tests; then
        print -u2 "Test runner hid a failure in $failure."
        exit 1
    fi
done

for missing_file in \
    'Snip Snap iOS' \
    'PrivacyInfo.xcprivacy' \
    'PlugIns/SnipSnapShareExtension.appex' \
    'PlugIns/SnipSnapShareExtension.appex/Info.plist' \
    'PlugIns/SnipSnapShareExtension.appex/SnipSnapShareExtension' \
    'PlugIns/SnipSnapShareExtension.appex/PrivacyInfo.xcprivacy'
do
    if SNIP_SNAP_TEST_MISSING_FILE="$missing_file" run_tests --ios-only; then
        print -u2 "Test runner accepted a bundle missing $missing_file."
        exit 1
    fi
    /usr/bin/grep -F 'iOS bundle check:' "$test_root/output" >/dev/null
done

/usr/bin/ruby -ryaml - "$script_dir/../.github/workflows/ci.yml" <<'RUBY'
jobs = YAML.load_file(ARGV.fetch(0)).fetch('jobs')
%w[mac ios].each do |group|
  job = jobs.fetch(group)
  abort "#{group} tests must run independently" unless Array(job['needs']).empty?
  commands = job.fetch('steps').map { |step| step['run'] }.compact
  expected_commands = []
  expected_commands << 'xcodebuild -downloadComponent MetalToolchain' if group == 'ios'
  expected_commands << "./scripts/test.sh --#{group}-only"
  abort "#{group} must install its tools and run its test group without a second build" unless
    commands == expected_commands
end

gate = jobs.fetch('test')
abort 'The required check name changed' unless gate['name'] == 'Tests and iOS compile check'
abort 'The required check must wait for both jobs' unless gate.fetch('needs').sort == %w[ios mac]
abort 'The required check must run after failures' unless gate['if'] == 'always()'
step = gate.fetch('steps').find { |entry| entry['run'] }
abort 'The required check must read both job results' unless step.fetch('env') == {
  'MAC_RESULT' => '${{ needs.mac.result }}',
  'IOS_RESULT' => '${{ needs.ios.result }}'
}
%w[success failure cancelled skipped].repeated_permutation(2) do |mac, ios|
  passed = system(
    { 'MAC_RESULT' => mac, 'IOS_RESULT' => ios },
    '/bin/bash', '--noprofile', '--norc', '-e', '-c', step.fetch('run'),
    out: File::NULL, err: File::NULL
  )
  expected = mac == 'success' && ios == 'success'
  abort "Wrong required check result for Mac=#{mac}, iOS=#{ios}" unless passed == expected
end
RUBY

print "Test runner checks passed."
