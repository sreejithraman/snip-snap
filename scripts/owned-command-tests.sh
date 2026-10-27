#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
test_dir="$(mktemp -d /private/tmp/snip-snap-owned-command.XXXXXX)"
unrelated_pid=""
cleanup() {
    [[ -z "$unrelated_pid" ]] || /bin/kill "$unrelated_pid" 2>/dev/null || true
    /bin/rm -rf "$test_dir"
}
trap cleanup EXIT
fail() { print -u2 "Owned command test failed: $1"; exit 1; }
runner="$script_dir/owned-command.rb"
marker="$test_dir/active-command"
if /usr/bin/ruby "$runner" 1 "$marker" /bin/zsh -c 'print visible-output; exit 23' > "$test_dir/output" 2>&1; then
    fail 'a command failure was accepted'
else
    result=$?
fi
[[ "$result" == 23 ]] || fail 'command exit status was lost'
[[ "$(cat "$test_dir/output")" == visible-output ]] || fail 'command output was lost'
[[ ! -e "$marker" ]] || fail 'a stopped command kept its marker'
/bin/sleep 60 &
unrelated_pid=$!
cat > "$test_dir/stall.rb" <<'RUBY'
trap('TERM') {}
child = fork do
  trap('TERM') {}
  sleep 60
end
File.write(ARGV.fetch(0), "#{Process.pid}\n#{child}\n")
puts 'setup started'
STDOUT.flush
Process.wait(child)
RUBY
if /usr/bin/ruby "$runner" 0.2 "$marker" /usr/bin/ruby "$test_dir/stall.rb" "$test_dir/pids" > "$test_dir/output" 2>&1; then
    fail 'a stalled command succeeded'
else
    result=$?
fi
[[ "$result" == 124 ]] || fail "timeout status was $result"
[[ ! -e "$marker" ]] || fail 'a timed-out command left its lock marker'
/bin/kill -0 "$unrelated_pid" || fail 'an unrelated process was stopped'
/usr/bin/ruby - "$test_dir/pids" <<'RUBY'
pids = File.read(ARGV.fetch(0)).split.map(&:to_i)
pids.each do |pid|
  state = IO.popen(['/bin/ps', '-o', 'stat=', '-p', pid.to_s], &:read).strip
  abort "owned process #{pid} remained running" unless state.empty? || state.start_with?('Z')
end
RUBY
grep -F 'timed out after 0.2s' "$test_dir/output" >/dev/null || fail 'timeout reason was missing'
[[ "$(head -n 1 "$test_dir/output")" == 'setup started' ]] || fail 'timeout discarded command output'
/usr/bin/ruby "$runner" 0 "$marker" /usr/bin/ruby -e 'sleep 60' > "$test_dir/output" 2>&1 &
supervisor_pid=$!
for attempt in {1..100}; do
    [[ ! -e "$marker" ]] || break
    /bin/sleep 0.01
done
[[ -e "$marker" ]] || fail 'supervisor did not start'
/bin/kill -TERM "$supervisor_pid"
if wait "$supervisor_pid"; then fail 'a cancelled command succeeded'; else result=$?; fi
[[ "$result" == 143 && ! -e "$marker" ]] || fail 'cancellation did not finish owned cleanup'
if /usr/bin/ruby "$runner" 0 "$marker" /bin/zsh -c 'kill -INT "$PPID"; exit 0' > "$test_dir/output" 2>&1; then
    fail 'a command exit hid simultaneous cancellation'
else
    result=$?
fi
[[ "$result" == 130 && ! -e "$marker" ]] || fail 'INT cancellation status or cleanup was lost'
print 'Owned command tests passed (status, output, timeout, descendant cleanup, cancellation, and isolation).'
