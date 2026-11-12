#!/bin/zsh
# Fault-injection checks for ci-boot-ios-simulator.sh, run through `| tee` like CI so a leaked boot shows up as a hang.
set -euo pipefail

script_dir="${0:A:h}"
boot="$script_dir/ci-boot-ios-simulator.sh"
owned_command_grace=2
slack=4
work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/snip-snap-ci-boot-tests.XXXXXX")"

fake="$work/xcrun"
print -r -- '#!/bin/zsh
case "$2" in
  list)
    print -r -- '"'"'{"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [{"name": "iPhone 18 Pro", "udid": "OLDER"}],
      "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [{"name": "iPhone 18 Pro", "udid": "NEWEST"}],
      "com.apple.CoreSimulator.SimRuntime.watchOS-27-2": [{"name": "iPhone 18 Pro", "udid": "WATCH"}]
    }}'"'"' ;;
  bootstatus)
    print -r -- "$3" > "$FAKE_XCRUN_STATE/booted"
    print -r -- $$ > "$FAKE_XCRUN_STATE/boot-group"
    case "$FAKE_BOOT" in
      ready) ;;
      fail) exit 7 ;;
      stubborn)
        trap "" TERM INT
        /bin/sleep 60
        : ;;
    esac ;;
esac' > "$fake"
/bin/chmod +x "$fake"
export SNIP_SNAP_XCRUN="$fake" FAKE_XCRUN_STATE="$work"

script_pid=
pipeline_pid=
boot_status=

boot_processes() {
    local boot_pid="$(<"$work/boot-group")"
    /usr/bin/pgrep -g "$boot_pid"
    /usr/bin/pgrep -P "$boot_pid"
    kill -0 "$boot_pid" 2>/dev/null && print -r -- "$boot_pid"
    return 0
}

kill_leftovers() {
    if [[ -f "$work/boot-group" ]]; then
        kill -KILL $(boot_processes) 2>/dev/null || true
    fi
    kill -KILL $script_pid $pipeline_pid 2>/dev/null || true
}
trap 'kill_leftovers; /bin/rm -rf "$work"' EXIT

fail() {
    print -u2 "ci-boot-ios-simulator-tests: $*"
    [[ -f "$work/log" ]] && /usr/bin/sed 's/^/  | /' "$work/log" >&2
    exit 1
}

start_boot() {
    /bin/rm -f "$work/boot-group" "$work/booted" "$work/udid" "$work/script-pid"
    (
        set -o pipefail
        {
            "$boot" "$1" > "$work/udid" &
            print -r -- $! > "$work/script-pid"
            wait $!
        } 2>&1 | /usr/bin/tee "$work/log" >/dev/null
    ) &
    pipeline_pid=$!
    while [[ ! -s "$work/script-pid" ]]; do /bin/sleep 0.05; done
    script_pid="$(<"$work/script-pid")"
}

# Fails when the CI pipeline is still open after the budget, which is what a surviving boot causes.
finish_boot() {
    local budget=$1 deadline=$(( SECONDS + $1 ))
    while kill -0 "$pipeline_pid" 2>/dev/null; do
        (( SECONDS < deadline )) || { kill_leftovers; fail "the | tee pipeline was still open after ${budget}s"; }
        /bin/sleep 0.1
    done
    boot_status=0
    wait "$pipeline_pid" || boot_status=$?
    pipeline_pid=
    script_pid=
}

assert_no_leftover_boot() {
    local leftovers=($(boot_processes))
    (( ${#leftovers} == 0 )) || fail "boot processes outlived the script: $(/bin/ps -o pid=,command= -p ${(j:,:)leftovers})"
}

FAKE_BOOT=ready start_boot "iPhone 18 Pro"
finish_boot 10
(( boot_status == 0 )) || fail "a ready boot exited $boot_status"
[[ "$(<"$work/udid")" == NEWEST && "$(<"$work/booted")" == NEWEST ]] || fail "the newest iOS runtime was not booted"

FAKE_BOOT=fail start_boot "iPhone 18 Pro"
finish_boot 10
(( boot_status != 0 )) || fail "a failed boot exited 0"
/usr/bin/grep -q 'failed to boot' "$work/log" || fail "a failed boot was not reported"

FAKE_BOOT=ready start_boot "iPhone Missing"
finish_boot 10
(( boot_status != 0 )) || fail "a missing device exited 0"
[[ ! -e "$work/booted" ]] || fail "a missing device still booted something"
/usr/bin/grep -q 'No available iOS Simulator named iPhone Missing' "$work/log" || fail "a missing device was not reported"

boot_limit=1
SNIP_SNAP_SIMULATOR_BOOT_SECONDS=$boot_limit FAKE_BOOT=stubborn start_boot "iPhone 18 Pro"
finish_boot $(( boot_limit + 1 + owned_command_grace + slack ))
(( boot_status != 0 )) || fail "a hung boot exited 0"
/usr/bin/grep -q "did not finish booting within ${boot_limit}s" "$work/log" || fail "a hung boot was not reported"
assert_no_leftover_boot

FAKE_BOOT=stubborn start_boot "iPhone 18 Pro"
while [[ ! -s "$work/boot-group" ]]; do /bin/sleep 0.05; done
kill -TERM "$script_pid"
finish_boot $(( 1 + owned_command_grace + slack ))
(( boot_status == 143 )) || fail "a cancelled boot exited $boot_status, not 143"
assert_no_leftover_boot

print "CI Simulator boot checks passed."
