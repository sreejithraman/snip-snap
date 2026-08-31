#!/bin/zsh
set -euo pipefail
setopt NO_BG_NICE

script_dir="${0:A:h}"
test_dir="$(mktemp -d)"
test_pid=""
trap '[[ -n "$test_pid" ]] && kill "$test_pid" 2>/dev/null || true; rm -rf "$test_dir"' EXIT

export SNIP_SNAP_DEV_SLOT=2
export SNIP_SNAP_DEV_STATE_DIR="$test_dir/dev-state"
export SNIP_SNAP_DEV_WORKTREE="$test_dir/worktree"
export SNIP_SNAP_SHOWROOM_STATE_DIR="$test_dir/showroom-state"
unset SNIP_SNAP_DERIVED_DATA
/bin/mkdir -p "$SNIP_SNAP_DEV_WORKTREE"
/bin/mkdir -p "$SNIP_SNAP_SHOWROOM_STATE_DIR"

description="$($script_dir/run.sh describe --json)"
print -r -- "$description" | /usr/bin/ruby -rjson -e '
data = JSON.parse(STDIN.read)
abort unless data.fetch("protocol_version") == 1
device = data.fetch("surfaces").fetch("device")
abort unless device.fetch("start") == ["device-start"]
abort unless device.fetch("verify") == ["device-verify"]
'
[[ ! -d "$SNIP_SNAP_DEV_STATE_DIR/claims" ]]

legacy_name="SnipSnap""Review"
legacy_bundle_id="world.sree.snipsnap.""review"
if /usr/bin/grep -F \
    -e "$legacy_name" \
    -e "$legacy_bundle_id" \
    -- \
    "$script_dir/dev-app.sh" \
    "$script_dir/run.sh" \
    "$script_dir/showroom-delivery.sh" >/dev/null; then
    print -u2 "An old Showroom identity returned."
    exit 1
fi
/usr/bin/grep -F -- \
    'delivery = ["scripts/run.sh"]' \
    "$script_dir/../.showroom.toml" >/dev/null

"$script_dir/run.sh" \
    device-verify \
    --result-json "$test_dir/result.json"
/usr/bin/ruby -rjson -e '
data = JSON.parse(File.read(ARGV.fetch(0)))
abort unless data.fetch("protocol_version") == 1
abort unless data.fetch("surface") == "device"
abort unless data.fetch("operation") == "verify"
abort unless data.fetch("verification").fetch("status") == "failed"
abort unless data.fetch("location").fetch("device") == "Snip Snap development app on this Mac"
' "$test_dir/result.json"
[[ ! -d "$SNIP_SNAP_DEV_STATE_DIR/claims" ]]

[[ "$("$script_dir/dev-slot.sh" claim)" == 2 ]]

fixture_executable="$SNIP_SNAP_DEV_STATE_DIR/build/slot-2/Build/Products/Debug/SnipSnapDev2.app/Contents/MacOS/SnipSnapDev2"
/bin/mkdir -p "${fixture_executable:h}"
print -r -- '#include <unistd.h>
int main(void) {
    sleep(30);
    return 0;
}' > "$test_dir/SnipSnapDev2.c"
/usr/bin/xcrun clang "$test_dir/SnipSnapDev2.c" -o "$fixture_executable"
/usr/bin/codesign --force --sign - --identifier SnipSnapDev2 "$fixture_executable" >/dev/null 2>&1
/usr/bin/codesign -dvv "$fixture_executable" 2>&1 | /usr/bin/grep -F 'Identifier=SnipSnapDev2' >/dev/null
"$fixture_executable" &
test_pid="$!"
print -r -- 2 > "$SNIP_SNAP_SHOWROOM_STATE_DIR/slot"
print -r -- "$SNIP_SNAP_DEV_WORKTREE" > "$SNIP_SNAP_SHOWROOM_STATE_DIR/worktree"
print -r -- SnipSnapDev2 > "$SNIP_SNAP_SHOWROOM_STATE_DIR/process-name"
print -r -- "${fixture_executable:h:h:h}" > "$SNIP_SNAP_SHOWROOM_STATE_DIR/app-path"
print -r -- "$fixture_executable" > "$SNIP_SNAP_SHOWROOM_STATE_DIR/executable-path"
print -r -- "$test_pid" > "$SNIP_SNAP_SHOWROOM_STATE_DIR/process.pid"
"$script_dir/run.sh" \
    device-verify \
    --result-json "$test_dir/running-process-result.json"
/usr/bin/ruby -rjson -e '
data = JSON.parse(File.read(ARGV.fetch(0)))
checks = data.fetch("verification").fetch("checks")
abort unless checks.fetch("app") == "passed"
abort unless checks.fetch("process") == "passed"
abort unless data.fetch("verification").fetch("status") == "passed"
abort unless data.fetch("verification").fetch("detail") == "Snip Snap Dev 2 is present and running."
abort unless data.fetch("location").fetch("device") == "Snip Snap Dev 2 on this Mac"
' "$test_dir/running-process-result.json"

/bin/mkdir -p "$test_dir/other-worktree"
SNIP_SNAP_DEV_WORKTREE="$test_dir/other-worktree" \
    "$script_dir/run.sh" \
    device-verify \
    --result-json "$test_dir/wrong-worktree-result.json"
/usr/bin/ruby -rjson -e '
data = JSON.parse(File.read(ARGV.fetch(0)))
abort unless data.fetch("verification").fetch("status") == "failed"
' "$test_dir/wrong-worktree-result.json"
[[ "$(<"$SNIP_SNAP_DEV_STATE_DIR/claims/slot-2/owner")" == "$SNIP_SNAP_DEV_WORKTREE" ]]

/bin/mkdir -p "$test_dir/bin"
print -r -- '#!/bin/zsh
if [[ "$*" == *-showBuildSettings* ]]; then
    print "    DEVELOPMENT_TEAM ="
    print "    SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER = world.sree.snipsnap"
else
    print -r -- "$@" > "$SNIP_SNAP_BUILD_ARGS_FILE"
fi' > "$test_dir/bin/xcodebuild"
/bin/chmod +x "$test_dir/bin/xcodebuild"
PATH="$test_dir/bin:$PATH" \
    SNIP_SNAP_BUILD_ARGS_FILE="$test_dir/build-args" \
    "$script_dir/build.sh" >/dev/null
/bin/kill -0 "$test_pid"
/usr/bin/grep -F -- "$SNIP_SNAP_DEV_STATE_DIR/build/slot-2" "$test_dir/build-args" >/dev/null
/usr/bin/grep -F -- "PRODUCT_BUNDLE_IDENTIFIER=world.sree.snipsnap.dev2" "$test_dir/build-args" >/dev/null
/usr/bin/grep -F -- "PRODUCT_NAME=SnipSnapDev2" "$test_dir/build-args" >/dev/null
/usr/bin/grep -F -- "INFOPLIST_KEY_CFBundleDisplayName=Snip Snap Dev 2" "$test_dir/build-args" >/dev/null

recorded_pid="$test_pid"
/bin/kill "$test_pid"
wait "$test_pid" 2>/dev/null || true
"$fixture_executable" &
test_pid="$!"
"$script_dir/run.sh" \
    device-verify \
    --result-json "$test_dir/restarted-process-result.json"
/usr/bin/ruby -rjson -e '
showroom = JSON.parse(File.read(ARGV.fetch(0)))
dev = JSON.parse(File.read(ARGV.fetch(1)))
abort unless showroom.fetch("verification").fetch("status") == "passed"
abort unless dev.fetch("pid") == Integer(ARGV.fetch(2))
abort if dev.fetch("pid") == Integer(ARGV.fetch(3))
' \
    "$test_dir/restarted-process-result.json" \
    "$test_dir/dev-app-status.json" \
    "$test_pid" \
    "$recorded_pid"

"$script_dir/dev-slot.sh" release >/dev/null
[[ "$(SNIP_SNAP_DEV_WORKTREE="$test_dir/other-worktree" "$script_dir/dev-slot.sh" claim)" == 2 ]]
"$script_dir/run.sh" \
    device-verify \
    --result-json "$test_dir/reassigned-slot-result.json"
/usr/bin/ruby -rjson -e '
data = JSON.parse(File.read(ARGV.fetch(0)))
abort unless data.fetch("verification").fetch("status") == "failed"
abort unless data.fetch("location").fetch("device") == "Snip Snap development app on this Mac"
' "$test_dir/reassigned-slot-result.json"
[[ "$(<"$SNIP_SNAP_DEV_STATE_DIR/claims/slot-2/owner")" == "$test_dir/other-worktree" ]]

print "Showroom delivery checks passed."
