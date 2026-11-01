#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
test_dir="$(mktemp -d /private/tmp/snip-snap-owned-command.XXXXXX)"
unrelated_pid=""
supervisor_pid=""
signal_owned_process() {
    /usr/bin/ruby - "$1" "$2" <<'RUBY'
begin
  pid = Integer(ARGV.fetch(0))
  identity = ARGV.fetch(1)
  command = IO.popen(['/bin/ps', '-o', 'command=', '-p', pid.to_s], &:read)
  exit 1 unless pid > 1 && command.split.include?(identity)
  Process.kill('TERM', pid)
rescue Errno::ESRCH
  exit 1
end
RUBY
}
cleanup() {
    if [[ -n "$supervisor_pid" ]]; then
        signal_owned_process "$supervisor_pid" "$test_dir/active-command" || true
    fi
    if [[ -f "$test_dir/owned-group" ]]; then
        /usr/bin/ruby - "$test_dir/owned-group" "$test_dir/stall.rb" <<'RUBY' || true
begin
  group = Integer(File.read(ARGV.fetch(0)))
  fixture = ARGV.fetch(1)
  owned = IO.popen(['/bin/ps', '-axo', 'pgid=,command='], &:read).lines.any? do |line|
    pgid, command = line.strip.split(/\s+/, 2)
    pgid.to_i == group && command.to_s.split.include?(fixture)
  end
  Process.kill('KILL', -group) if group > 1 && owned
rescue Errno::ESRCH
end
RUBY
    fi
    if [[ -n "$supervisor_pid" ]]; then
        wait "$supervisor_pid" 2>/dev/null || true
        supervisor_pid=""
    fi
    if [[ -n "$unrelated_pid" ]]; then
        signal_owned_process "$unrelated_pid" "$test_dir/unrelated-control" || true
        wait "$unrelated_pid" 2>/dev/null || true
        unrelated_pid=""
    fi
    /bin/rm -rf "$test_dir"
}
trap cleanup EXIT
fail() { print -u2 "Owned command test failed: $1"; exit 1; }
runner="$script_dir/owned-command.rb"
marker="$test_dir/active-command"
if /usr/bin/ruby "$runner" 0 "$marker" /bin/zsh -c 'print visible-output; exit 23' > "$test_dir/output" 2>&1; then
    fail 'a command failure was accepted'
else
    result=$?
fi
[[ "$result" == 23 ]] || fail 'command exit status was lost'
[[ "$(cat "$test_dir/output")" == visible-output ]] || fail 'command output was lost'
[[ ! -e "$marker" ]] || fail 'a stopped command kept its marker'
if ! /usr/bin/ruby "$runner" 5 "$marker" /bin/zsh -c 'print completed-within-budget' > "$test_dir/output" 2>&1; then
    fail 'a real CLI command within a positive timeout failed'
fi
[[ "$(cat "$test_dir/output")" == completed-within-budget && ! -e "$marker" ]] || fail 'positive-timeout output or cleanup was lost'
/usr/bin/ruby -e 'sleep 60' "$test_dir/unrelated-control" &
unrelated_pid=$!
cat > "$test_dir/stall.rb" <<'RUBY'
trap('TERM') {}
owned_group = ARGV.fetch(1)
File.write("#{owned_group}.tmp", Process.pid.to_s)
File.rename("#{owned_group}.tmp", owned_group)
ready_read, ready_write = IO.pipe
child = fork do
  ready_read.close
  trap('TERM') {}
  ready_write.write('ready')
  ready_write.close
  sleep 60
end
ready_write.close
raise 'Descendant did not become ready' unless ready_read.read == 'ready'
ready_read.close
puts 'setup started'
STDOUT.flush
ready = ARGV.fetch(0)
File.write("#{ready}.tmp", "#{Process.pid}\n#{child}\n")
File.rename("#{ready}.tmp", ready)
Process.wait(child)
RUBY
cat > "$test_dir/assert-stopped.rb" <<'RUBY'
pids = File.read(ARGV.fetch(0)).lines.map { |line| Integer(line, 10) }
abort 'Expected exactly two distinct owned PIDs' unless pids.length == 2 && pids.uniq.length == 2 && pids.all? { |pid| pid > 1 }
pids.each do |pid|
  state = IO.popen(['/bin/ps', '-o', 'stat=', '-p', pid.to_s], &:read).strip
  abort "owned process #{pid} remained running" unless state.empty? || state.start_with?('Z')
end
RUBY
if /usr/bin/ruby "$runner" 0.2 "$marker" /bin/sleep 60 > "$test_dir/output" 2>&1; then
    fail 'a stalled command succeeded'
else
    result=$?
fi
[[ "$result" == 124 ]] || fail "timeout status was $result"
[[ ! -e "$marker" ]] || fail 'a timed-out command left its lock marker'
/bin/kill -0 "$unrelated_pid" || fail 'an unrelated process was stopped'
grep -F 'timed out after 0.2s' "$test_dir/output" >/dev/null || fail 'timeout reason was missing'
cat > "$test_dir/ready-timeout.rb" <<'RUBY'
require ARGV.shift
ready = ARGV.shift
clock = -> {
  Process.clock_gettime(Process::CLOCK_MONOTONIC) + (File.exist?(ready) ? 10 : 0)
}
exit OwnedCommand.new(timeout: 5.0, marker: ARGV.shift, command: ARGV, clock: clock).run
RUBY
if /usr/bin/ruby "$test_dir/ready-timeout.rb" "$runner" "$test_dir/pids" "$marker" \
    /usr/bin/ruby "$test_dir/stall.rb" "$test_dir/pids" "$test_dir/owned-group" > "$test_dir/output" 2>&1; then
    fail 'a ready process tree did not time out'
else
    result=$?
fi
[[ "$result" == 124 && ! -e "$marker" ]] || fail 'ready timeout status or marker cleanup was lost'
grep -Fx 'setup started' "$test_dir/output" >/dev/null || fail 'timeout discarded command output'
grep -F 'timed out after 5.0s' "$test_dir/output" >/dev/null || fail 'ready timeout reason was missing'
/bin/kill -0 "$unrelated_pid" || fail 'a timeout stopped an unrelated process'
/usr/bin/ruby "$test_dir/assert-stopped.rb" "$test_dir/pids"
/bin/rm "$test_dir/pids" "$test_dir/owned-group"
/usr/bin/ruby "$runner" 0 "$marker" /usr/bin/ruby "$test_dir/stall.rb" "$test_dir/pids" "$test_dir/owned-group" > "$test_dir/output" 2>&1 &
supervisor_pid=$!
for attempt in {1..500}; do
    [[ ! -s "$test_dir/pids" ]] || break
    /bin/sleep 0.01
done
[[ -s "$test_dir/pids" ]] || fail 'owned descendants did not start'
signal_owned_process "$supervisor_pid" "$test_dir/active-command" || fail 'owned supervisor exited before cancellation'
if wait "$supervisor_pid"; then result=0; else result=$?; fi
supervisor_pid=""
[[ "$result" == 143 && ! -e "$marker" ]] || fail 'cancellation did not finish owned cleanup'
/bin/kill -0 "$unrelated_pid" || fail 'cancellation stopped an unrelated process'
/usr/bin/ruby "$test_dir/assert-stopped.rb" "$test_dir/pids"
/bin/rm "$test_dir/pids" "$test_dir/owned-group"
if /usr/bin/ruby "$runner" 0 "$marker" /bin/zsh -c 'kill -INT "$PPID"; exit 0' > "$test_dir/output" 2>&1; then
    fail 'a command exit hid simultaneous cancellation'
else
    result=$?
fi
[[ "$result" == 130 && ! -e "$marker" ]] || fail 'INT cancellation status or cleanup was lost'
print 'Owned command tests passed (status, output, timeout, descendant cleanup, cancellation, and isolation).'
