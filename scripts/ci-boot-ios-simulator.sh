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

SECONDS=0
/usr/bin/xcrun simctl bootstatus "$udid" -b >&2
print -u2 "Booted $name ($udid) in ${SECONDS}s."
print -r -- "$udid"
