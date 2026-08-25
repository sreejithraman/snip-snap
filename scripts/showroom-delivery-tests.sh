#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

description="$($script_dir/run.sh describe --json)"
print -r -- "$description" | /usr/bin/ruby -rjson -e '
data = JSON.parse(STDIN.read)
abort unless data.fetch("protocol_version") == 1
device = data.fetch("surfaces").fetch("device")
abort unless device.fetch("start") == ["device-start"]
abort unless device.fetch("verify") == ["device-verify"]
'

SNIP_SNAP_SHOWROOM_STATE_DIR="$test_dir/state" \
    "$script_dir/showroom-delivery.sh" \
    device-verify \
    --result-json "$test_dir/result.json"
/usr/bin/ruby -rjson -e '
data = JSON.parse(File.read(ARGV.fetch(0)))
abort unless data.fetch("protocol_version") == 1
abort unless data.fetch("surface") == "device"
abort unless data.fetch("operation") == "verify"
abort unless data.fetch("verification").fetch("status") == "failed"
' "$test_dir/result.json"

/bin/mkdir -p "$test_dir/state/derived-data/Build/Products/Debug/SnipSnapReview.app"
print -r -- "$$" > "$test_dir/state/process.pid"
SNIP_SNAP_SHOWROOM_STATE_DIR="$test_dir/state" \
    "$script_dir/showroom-delivery.sh" \
    device-verify \
    --result-json "$test_dir/stale-process-result.json"
/usr/bin/ruby -rjson -e '
data = JSON.parse(File.read(ARGV.fetch(0)))
checks = data.fetch("verification").fetch("checks")
abort unless checks.fetch("app") == "passed"
abort unless checks.fetch("process") == "failed"
' "$test_dir/stale-process-result.json"

print "Showroom delivery checks passed."
