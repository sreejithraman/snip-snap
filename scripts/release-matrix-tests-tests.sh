#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-release-matrix-tests.XXXXXX)"
cleanup() {
    [[ "$test_root" == /private/tmp/snip-snap-release-matrix-tests.* ]] && \
        /bin/rm -rf "$test_root"
}
trap cleanup EXIT

fail_test() {
    print -u2 "release matrix test failed: $1"
    exit 1
}

/bin/mkdir -p "$test_root/bin"
print -r -- '#!/bin/zsh
set -euo pipefail
[[ -s "$SNIP_SNAP_RELEASE_FIXTURE_PID_FILE" ]] && /bin/kill -0 "$(cat "$SNIP_SNAP_RELEASE_FIXTURE_PID_FILE")" || exit 1
if [[ "$*" == *testShareExtension* ]]; then
    [[ "${TEST_RUNNER_SNIP_SNAP_SHARE_FIXTURE_URL:-}" == http://127.0.0.1:43101/ ]] || exit 1
elif [[ -n "${TEST_RUNNER_SNIP_SNAP_SHARE_FIXTURE_URL:-}" ]]; then
    print -u2 'An ordinary matrix leg inherited a stale Share fixture URL.'
    exit 1
fi
print -r -- "$PWD :: $@" >> "$SNIP_SNAP_RELEASE_TEST_ARGS_FILE"' > \
    "$test_root/bin/xcodebuild"
/bin/chmod +x "$test_root/bin/xcodebuild"
cat > "$test_root/bin/python3" <<'STUB'
#!/bin/zsh
set -euo pipefail
[[ -f "$2/index.html" && "$4" == 0 ]] || exit 1
print -r -- "$$" > "$SNIP_SNAP_RELEASE_FIXTURE_PID_FILE"
print -r -- "$$" >> "$SNIP_SNAP_RELEASE_FIXTURE_LOG"
trap '/bin/rm -f "$SNIP_SNAP_RELEASE_FIXTURE_PID_FILE"; exit 0' INT TERM
print -r -- 43101 > "$3"
while true; do /bin/sleep 0.05; done
STUB
/bin/chmod +x "$test_root/bin/python3"
export SNIP_SNAP_PYTHON="$test_root/bin/python3"
export SNIP_SNAP_RELEASE_FIXTURE_PID_FILE="$test_root/fixture.pid"
export SNIP_SNAP_RELEASE_FIXTURE_LOG="$test_root/fixture.log"

assert_fixture_cleaned_up() {
    [[ ! -e "$SNIP_SNAP_RELEASE_FIXTURE_PID_FILE" ]] || \
        fail_test "the runner left its fixture child behind"
    local fixture_pid
    for fixture_pid in ${(f)"$(cat "$SNIP_SNAP_RELEASE_FIXTURE_LOG")"}; do
        if /bin/kill -0 "$fixture_pid" 2>/dev/null; then
            fail_test "the runner left its fixture child alive"
        fi
    done
    local -a derived_directories=("$test_root"/*derived*(N/))
    (( ${#derived_directories} == 0 )) || fail_test "the runner left owned test files behind"
}

args_file="$test_root/test-args"
output="$(
    TEST_RUNNER_SNIP_SNAP_SHARE_FIXTURE_URL='http://127.0.0.1:1/' \
    SNIP_SNAP_XCODEBUILD="$test_root/bin/xcodebuild" \
    SNIP_SNAP_RELEASE_TEST_ARGS_FILE="$args_file" \
    SNIP_SNAP_DERIVED_DATA="$test_root/derived-data" \
        "$script_dir/release-matrix-tests.sh" \
        --iphone-destination 'platform=iOS Simulator,name=Example iPhone' \
        --ipad-destination 'platform=iOS Simulator,name=Example iPad'
)"

[[ "$(/usr/bin/wc -l < "$args_file" | /usr/bin/tr -d ' ')" == 6 ]] || \
    fail_test "the release matrix did not run exactly six Simulator test commands"

iphone_destination='platform=iOS Simulator,name=Example iPhone'
ipad_destination='platform=iOS Simulator,name=Example iPad'
for line in 1 2 3; do
    iphone_command="$(/usr/bin/sed -n "${line}p" "$args_file")"
    ipad_command="$(/usr/bin/sed -n "$(( line + 3 ))p" "$args_file")"
    [[ "$iphone_command" == *"-destination $iphone_destination "* && \
       "$ipad_command" == *"-destination $ipad_destination "* ]] || \
        fail_test "matrix command $line did not run on iPhone and then iPad"
    [[ "${${ipad_command//$ipad_destination/$iphone_destination}//\/ipad-//iphone-}" == "$iphone_command" ]] || \
        fail_test "the iPad leg of matrix command $line differs from the iPhone leg"
    [[ "$iphone_command" == *" -only-testing:"* ]] || \
        fail_test "matrix command $line selects no tests"
done

for line in 1 4; do
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        'Packages/SnipSnapLibrary :: -scheme SnipSnapLibrary-Package -configuration Debug ' >/dev/null || \
        fail_test "matrix command $line is not the package transfer test"
done

for line in 3 6; do
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '-scheme SnipSnapiOS -configuration Debug ' >/dev/null || \
        fail_test "matrix command $line is not the Share extension process test"
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        'CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=' >/dev/null || \
        fail_test "the Share extension process command was not ad-hoc signed"
    /usr/bin/sed -n "${line}p" "$args_file" | /usr/bin/grep -F -- \
        '/testShareExtension' >/dev/null || \
        fail_test "the Share extension process command runs no Share extension test"
done

[[ "$(/usr/bin/grep -Fc -- 'CODE_SIGNING_ALLOWED=NO' "$args_file")" == 4 ]] || \
    fail_test "one or more package or app-action tests allowed signing"

# A renamed or deleted test must fail here, not only during a manual release-matrix run.
repo_root="${script_dir:h}"
for selector in ${(u)${(f)"$(/usr/bin/grep -o -- '-only-testing:[^ ]*' "$args_file")"}}; do
    selector="${selector#-only-testing:}"
    test_target="${selector%%/*}"
    test_class="${${selector#*/}%%/*}"
    test_method="${selector##*/}"
    [[ "$selector" == "$test_target/$test_class/$test_method" ]] || \
        fail_test "matrix selector $selector does not name one test method"
    test_sources="$repo_root/Packages/SnipSnapLibrary/Tests/$test_target"
    [[ "$test_target" != SnipSnapiOSUITests ]] || test_sources="$repo_root/SnipSnapiOSUITests"
    class_files=(${(f)"$(/usr/bin/grep -rlE --include='*.swift' -- "class $test_class([^[:alnum:]_]|$)" "$test_sources" 2>/dev/null || true)"})
    (( ${#class_files} )) || fail_test "matrix test class $test_target/$test_class does not exist"
    /usr/bin/grep -F -- "func $test_method(" "${class_files[@]}" >/dev/null || \
        fail_test "matrix test $selector does not exist"
done

[[ "$output" == *"Share fixture started:"* ]] || \
    fail_test "the release matrix did not report the local fixture start"
[[ "$output" == *"Share fixture stopped."* ]] || \
    fail_test "the release matrix did not stop the local fixture"

assert_fixture_cleaned_up

print -r -- '#!/bin/zsh
exit 23' > "$test_root/bin/failing-xcodebuild"
/bin/chmod +x "$test_root/bin/failing-xcodebuild"
if SNIP_SNAP_XCODEBUILD="$test_root/bin/failing-xcodebuild" \
    SNIP_SNAP_DERIVED_DATA="$test_root/failure-derived" \
        "$script_dir/release-matrix-tests.sh" >/dev/null 2>&1
then
    fail_test "the release matrix hid an xcodebuild failure"
fi
assert_fixture_cleaned_up

print -r -- '#!/bin/zsh
/bin/kill -s "$SNIP_SNAP_RELEASE_TEST_SIGNAL" "$PPID"
exit 0' > "$test_root/bin/interrupted-xcodebuild"
/bin/chmod +x "$test_root/bin/interrupted-xcodebuild"
for test_signal in INT TERM; do
    if SNIP_SNAP_XCODEBUILD="$test_root/bin/interrupted-xcodebuild" \
        SNIP_SNAP_RELEASE_TEST_SIGNAL="$test_signal" \
        SNIP_SNAP_DERIVED_DATA="$test_root/interrupted-derived" \
            "$script_dir/release-matrix-tests.sh" >/dev/null 2>&1
    then
        fail_test "the release matrix hid $test_signal interruption"
    fi
    assert_fixture_cleaned_up
done

print "Release matrix test checks passed."
