#!/bin/zsh
# Boots the newest-runtime Simulator with the given name, waits for it to settle, and prints its UDID.
# Hosted runners start Simulators cold, which made iOS 27 tests run several times slower.
set -euo pipefail

name="${1:?Usage: $0 DEVICE_NAME}"
udid="$(/usr/bin/xcrun simctl list devices available -j | /usr/bin/ruby -rjson -e '
  name = ARGV.fetch(0)
  candidates = JSON.parse(STDIN.read).fetch("devices").flat_map do |runtime, devices|
    version = runtime[/SimRuntime\.iOS-([0-9-]+)\z/, 1] or next []
    devices.select { |device| device["name"] == name }.map { |device| [version.split("-").map(&:to_i), device] }
  end
  _, device = candidates.max_by(&:first)
  abort "No available iOS Simulator named #{name}" unless device
  puts device.fetch("udid")
' "$name")"

boot_limit=300
SECONDS=0
/usr/bin/xcrun simctl bootstatus "$udid" -b >&2 &
boot_pid=$!
while kill -0 "$boot_pid" 2>/dev/null; do
    if (( SECONDS >= boot_limit )); then
        kill "$boot_pid" 2>/dev/null || true
        print -u2 "Simulator $name ($udid) did not finish booting within ${boot_limit}s."
        exit 1
    fi
    sleep 1
done
wait "$boot_pid" || { print -u2 "Simulator $name ($udid) failed to boot."; exit 1; }
print -u2 "Booted $name ($udid) in ${SECONDS}s."
print -r -- "$udid"
