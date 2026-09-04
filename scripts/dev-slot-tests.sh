#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
unset SNIP_SNAP_DEV_SLOT
unset SNIP_SNAP_DERIVED_DATA
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/worktree-a" "$test_dir/worktree-b" "$test_dir/worktree-c"
mkdir -p "$test_dir/worktree-d" "$test_dir/worktree-e" "$test_dir/worktree-f"

claim() {
    SNIP_SNAP_DEV_STATE_DIR="$test_dir/state" \
        SNIP_SNAP_DEV_WORKTREE="$1" \
        "$script_dir/dev-slot.sh" claim
}

[[ "$(claim "$test_dir/worktree-a")" == 1 ]]
[[ "$(claim "$test_dir/worktree-a")" == 1 ]]
for invalid_slot in 0 01 1001; do
    if SNIP_SNAP_DEV_STATE_DIR="$test_dir/state" \
        SNIP_SNAP_DEV_WORKTREE="$test_dir/worktree-e" \
        SNIP_SNAP_DEV_SLOT="$invalid_slot" \
        "$script_dir/dev-slot.sh" claim >/dev/null 2>&1; then
        print -u2 "Invalid slot $invalid_slot was accepted."
        exit 1
    fi
done
if SNIP_SNAP_DEV_STATE_DIR="$test_dir/state" \
    SNIP_SNAP_DEV_WORKTREE="$test_dir/worktree-a" \
    SNIP_SNAP_DEV_SLOT=4 \
    "$script_dir/dev-slot.sh" claim >/dev/null 2>&1; then
    print -u2 "A worktree changed slots without releasing its first slot."
    exit 1
fi
[[ "$(claim "$test_dir/worktree-b")" == 2 ]]
[[ "$(claim "$test_dir/worktree-c")" == 3 ]]
[[ "$(claim "$test_dir/worktree-d")" == 4 ]]
[[ "$(claim "$test_dir/worktree-f")" == 5 ]]
[[ "$(
    SNIP_SNAP_DEV_STATE_DIR="$test_dir/state" \
        SNIP_SNAP_DEV_WORKTREE="$test_dir/worktree-f" \
        "$script_dir/dev-slot.sh" list
)" == *"Snip Snap Dev 5: $test_dir/worktree-f"* ]]

if SNIP_SNAP_DEV_STATE_DIR="$test_dir/state" \
    SNIP_SNAP_DEV_WORKTREE="$test_dir/worktree-e" \
    SNIP_SNAP_DEV_SLOT=2 \
    "$script_dir/dev-slot.sh" claim >/dev/null 2>&1; then
    print -u2 "A worktree took another worktree's explicit slot."
    exit 1
fi

SNIP_SNAP_DEV_STATE_DIR="$test_dir/state" \
    SNIP_SNAP_DEV_WORKTREE="$test_dir/worktree-b" \
    "$script_dir/dev-slot.sh" release >/dev/null
[[ "$(claim "$test_dir/worktree-e")" == 2 ]]

stale_worktree="$test_dir/stale-worktree"
replacement_worktree="$test_dir/replacement-worktree"
stale_state="$test_dir/stale-state"
mkdir -p "$stale_worktree" "$replacement_worktree"

[[ "$(
    SNIP_SNAP_DEV_STATE_DIR="$stale_state" \
        SNIP_SNAP_DEV_WORKTREE="$stale_worktree" \
        "$script_dir/dev-slot.sh" claim
)" == 1 ]]
rmdir "$stale_worktree"

stale_list="$(
    SNIP_SNAP_DEV_STATE_DIR="$stale_state" \
        SNIP_SNAP_DEV_WORKTREE="$replacement_worktree" \
        "$script_dir/dev-slot.sh" list
)"
[[ "$stale_list" == *"Snip Snap Dev 1: available"* ]]
[[ "$(
    SNIP_SNAP_DEV_STATE_DIR="$stale_state" \
        SNIP_SNAP_DEV_WORKTREE="$replacement_worktree" \
        "$script_dir/dev-slot.sh" claim
)" == 1 ]]

pending_state="$test_dir/pending-state"
mkdir -p "$pending_state/claims/slot-1" "$test_dir/pending-worktree"
pending_list="$(
    SNIP_SNAP_DEV_STATE_DIR="$pending_state" \
        SNIP_SNAP_DEV_WORKTREE="$test_dir/pending-worktree" \
        "$script_dir/dev-slot.sh" list
)"
[[ "$pending_list" == *"Snip Snap Dev 1: claim in progress"* ]]
[[ "$(
    SNIP_SNAP_DEV_STATE_DIR="$pending_state" \
        SNIP_SNAP_DEV_WORKTREE="$test_dir/pending-worktree" \
        "$script_dir/dev-slot.sh" claim
)" == 2 ]]

mkdir -p "$test_dir/bin"
print -r -- '#!/bin/zsh
if [[ "$*" == *-showBuildSettings* ]]; then
    print "    DEVELOPMENT_TEAM ="
    print "    SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER = world.sree.snipsnap"
else
    print -r -- "$@" > "$SNIP_SNAP_BUILD_ARGS_FILE"
fi' > "$test_dir/bin/xcodebuild"
chmod +x "$test_dir/bin/xcodebuild"

if PATH="$test_dir/bin:$PATH" \
    SNIP_SNAP_BUILD_ARGS_FILE="$test_dir/build-args" \
    SNIP_SNAP_DEV_STATE_DIR="$test_dir/state" \
    SNIP_SNAP_DEV_WORKTREE="$test_dir/worktree-a" \
    SNIP_SNAP_DEV_SLOT=2 \
    "$script_dir/build.sh" >/dev/null 2>&1; then
    print -u2 "A signed build used a slot owned by another worktree."
    exit 1
fi

PATH="$test_dir/bin:$PATH" \
    SNIP_SNAP_BUILD_ARGS_FILE="$test_dir/build-args" \
    SNIP_SNAP_DEV_STATE_DIR="$test_dir/state" \
    SNIP_SNAP_DEV_WORKTREE="$test_dir/worktree-e" \
    SNIP_SNAP_DEV_SLOT=2 \
    "$script_dir/build.sh" >/dev/null
grep -F -- "$test_dir/state/build/slot-2" "$test_dir/build-args" >/dev/null
grep -F -- "PRODUCT_BUNDLE_IDENTIFIER=world.sree.snipsnap.dev2" \
    "$test_dir/build-args" >/dev/null
grep -F -- "PRODUCT_NAME=SnipSnapDev2" "$test_dir/build-args" >/dev/null
grep -F -- "INFOPLIST_KEY_CFBundleDisplayName=Snip Snap Dev 2" \
    "$test_dir/build-args" >/dev/null
grep -F -- "CODE_SIGN_IDENTITY=-" "$test_dir/build-args" >/dev/null
grep -F -- "DEVELOPMENT_TEAM=" "$test_dir/build-args" >/dev/null
grep -F -- "CODE_SIGN_ENTITLEMENTS=" "$test_dir/build-args" >/dev/null
grep -F -- "SNIP_SNAP_APP_GROUP_IDENTIFIER=" "$test_dir/build-args" >/dev/null
grep -F -- "SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER=" "$test_dir/build-args" >/dev/null

print -r -- '#!/bin/zsh
if [[ "$*" == *-showBuildSettings* ]]; then
    print "    DEVELOPMENT_TEAM = FAKE123456"
    print "    SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap"
else
    print -r -- "$@" > "$SNIP_SNAP_BUILD_ARGS_FILE"
fi' > "$test_dir/bin/xcodebuild"
chmod +x "$test_dir/bin/xcodebuild"
PATH="$test_dir/bin:$PATH" \
    SNIP_SNAP_BUILD_ARGS_FILE="$test_dir/team-build-args" \
    SNIP_SNAP_DEV_STATE_DIR="$test_dir/state" \
    SNIP_SNAP_DEV_WORKTREE="$test_dir/worktree-e" \
    SNIP_SNAP_DEV_SLOT=2 \
    "$script_dir/build.sh" >/dev/null
grep -F -- "CODE_SIGN_STYLE=Automatic" "$test_dir/team-build-args" >/dev/null
grep -F -- "DEVELOPMENT_TEAM=FAKE123456" "$test_dir/team-build-args" >/dev/null
grep -F -- "SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=org.example.snipsnap" \
    "$test_dir/team-build-args" >/dev/null
grep -F -- "PRODUCT_BUNDLE_IDENTIFIER=org.example.snipsnap.dev2" \
    "$test_dir/team-build-args" >/dev/null
if grep -F -- "CODE_SIGN_IDENTITY=-" "$test_dir/team-build-args" >/dev/null; then
    print -u2 "A team-signed Dev build used ad hoc signing."
    exit 1
fi

print -r -- '#!/bin/zsh
if [[ "$*" == *-showBuildSettings* ]]; then
    print "    DEVELOPMENT_TEAM ="
    print "    SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER = org.example.environment"
else
    print -r -- "$@" > "$SNIP_SNAP_BUILD_ARGS_FILE"
fi' > "$test_dir/bin/xcodebuild"
chmod +x "$test_dir/bin/xcodebuild"
SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=org.example.environment \
    PATH="$test_dir/bin:$PATH" \
    SNIP_SNAP_BUILD_ARGS_FILE="$test_dir/environment-build-args" \
    SNIP_SNAP_DEV_STATE_DIR="$test_dir/state" \
    SNIP_SNAP_DEV_WORKTREE="$test_dir/worktree-e" \
    SNIP_SNAP_DEV_SLOT=2 \
    "$script_dir/build.sh" >/dev/null
grep -F -- "SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=org.example.environment" \
    "$test_dir/environment-build-args" >/dev/null
grep -F -- "PRODUCT_BUNDLE_IDENTIFIER=org.example.environment.dev2" \
    "$test_dir/environment-build-args" >/dev/null

display_name_source="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleDisplayName' \
        "$script_dir/../SnipSnap/Info.plist"
)"
[[ "$display_name_source" == '$(INFOPLIST_KEY_CFBundleDisplayName)' ]]

slot5_state="$test_dir/slot5-status"
slot5_worktree="$test_dir/slot5-worktree"
slot5_app="$slot5_state/build/slot-5/Build/Products/Debug/SnipSnapDev5.app"
slot5_runtime="$slot5_state/runtime/slot-5"
mkdir -p "$slot5_worktree" \
    "$slot5_state/claims/slot-5" \
    "$slot5_app/Contents/MacOS" \
    "$slot5_runtime"
print -r -- "$slot5_worktree" > "$slot5_state/claims/slot-5/owner"
print -r -- 5 > "$slot5_runtime/slot"
print -r -- "$slot5_worktree" > "$slot5_runtime/worktree"
print -r -- SnipSnapDev5 > "$slot5_runtime/process-name"
print -r -- "$slot5_app" > "$slot5_runtime/app-path"
print -r -- "$slot5_app/Contents/MacOS/SnipSnapDev5" > "$slot5_runtime/executable-path"
print -r -- 1 > "$slot5_runtime/process.pid"
SNIP_SNAP_DEV_STATE_DIR="$slot5_state" \
    SNIP_SNAP_DEV_WORKTREE="$slot5_worktree" \
    "$script_dir/dev-app.sh" status \
        --runtime-dir "$slot5_runtime" \
        --result-json "$test_dir/slot5-status.json" >/dev/null || true
/usr/bin/ruby -rjson -e '
data = JSON.parse(File.read(ARGV.fetch(0)))
abort unless data.fetch("slot") == 5
abort unless data.fetch("detail").include?("Snip Snap Dev 5")
' "$test_dir/slot5-status.json"

print "Development slot checks passed."
