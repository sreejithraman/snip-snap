#!/bin/zsh
# Boots the newest-runtime Simulator with the given name, waits for it to settle, and prints its UDID.
# Hosted runners start Simulators cold, which made iOS 27 tests run several times slower.
set -euo pipefail

name="${1:?Usage: $0 DEVICE_NAME}"
xcrun="${SNIP_SNAP_XCRUN:-/usr/bin/xcrun}"
boot_limit="${SNIP_SNAP_SIMULATOR_BOOT_SECONDS:-300}"

udid="$("$xcrun" simctl list devices available -j | /usr/bin/ruby -rjson -e '
  name = ARGV.fetch(0)
  candidates = JSON.parse(STDIN.read).fetch("devices").flat_map do |runtime, devices|
    version = runtime[/SimRuntime\.iOS-([0-9-]+)\z/, 1] or next []
    devices.select { |device| device["name"] == name }.map { |device| [version.split("-").map(&:to_i), device] }
  end
  _, device = candidates.max_by(&:first)
  abort "No available iOS Simulator named #{name}" unless device
  puts device.fetch("udid")
' "$name")"

marker="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/snip-snap-ci-boot.XXXXXX")"
boot_pid=
# A boot left running would hold CI's `| tee` pipe open, so owned-command.rb stops its whole process group.
stop_boot() {
    if [[ -n "$boot_pid" ]]; then
        kill -TERM "$boot_pid" 2>/dev/null || true
        wait "$boot_pid" 2>/dev/null || true
        boot_pid=
    fi
    /bin/rm -f "$marker"
}
trap stop_boot EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SECONDS=0
/usr/bin/ruby "${0:A:h}/owned-command.rb" "$boot_limit" "$marker" "$xcrun" simctl bootstatus "$udid" -b >&2 &
boot_pid=$!
boot_status=0
wait "$boot_pid" || boot_status=$?
boot_pid=
case "$boot_status" in
    0) ;;
    124) print -u2 "Simulator $name ($udid) did not finish booting within ${boot_limit}s."; exit 1 ;;
    *) print -u2 "Simulator $name ($udid) failed to boot."; exit 1 ;;
esac
print -u2 "Booted $name ($udid) in ${SECONDS}s."
print -r -- "$udid"
