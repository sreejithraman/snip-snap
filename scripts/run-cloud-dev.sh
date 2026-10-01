#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source "$script_dir/signing-policy.sh"
mode="${1:-}"
if (( $# > 0 )); then shift; fi
device_id=""
case "$mode" in
    cloud-mac) [[ $# == 0 ]] || exit 2; platform=macos ;;
    cloud-ios-device)
        [[ $# == 1 && -n "$1" ]] || {
            print -u2 "Usage: scripts/run.sh cloud-ios-device DEVICE_UDID"
            exit 2
        }
        platform=ios
        device_id="$1"
        ;;
    *) print -u2 "Usage: scripts/run.sh cloud-mac | cloud-ios-device DEVICE_UDID"; exit 2 ;;
esac

slot="$("$script_dir/dev-slot.sh" claim)"
dev_state_dir="${SNIP_SNAP_DEV_STATE_DIR:-$HOME/Library/Application Support/Snip Snap/Development}"
derived_data="$dev_state_dir/build/cloud-$platform-slot-$slot"
runtime_dir="$dev_state_dir/runtime/cloud-$platform-slot-$slot"
installed_root="$dev_state_dir/apps/cloud-slot-$slot"
lock_dir="$dev_state_dir/locks/cloud-$platform-slot-$slot"
/bin/mkdir -p "${lock_dir:h}" "$runtime_dir" "$installed_root"
if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
    print -u2 "Cloud Dev $slot is already building or starting on $platform. Lock: $lock_dir"
    exit 1
fi
print -r -- "$$" > "$lock_dir/owner"
staging_dir=""
backup_app=""
installed_app=""
cleanup() {
    local run_status=$?
    if [[ -n "$backup_app" && -d "$backup_app" ]]; then
        if [[ ! -e "$installed_app" ]]; then
            if ! /bin/mv "$backup_app" "$installed_app"; then
                print -u2 "Restore the previous Cloud Dev app from $backup_app."
                staging_dir=""
            fi
        elif (( run_status != 0 )); then
            print -u2 "The run failed. The previous Cloud Dev app is preserved at $backup_app."
            staging_dir=""
        fi
    fi
    [[ -z "$staging_dir" ]] || /bin/rm -rf "$staging_dir"
    /bin/rm -f "$lock_dir/owner"
    /bin/rmdir "$lock_dir"
    return "$run_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

matching_mac_process_ids() {
    local candidate_pid command_path
    for candidate_pid in $(/usr/bin/pgrep -f "SnipSnapCloudDev$slot" 2>/dev/null || true); do
        command_path="$(/bin/ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
        if [[ "$command_path" == "$executable" || "$command_path" == "$executable "* ]]; then
            print -r -- "$candidate_pid"
        fi
    done
}

receipt="$runtime_dir/build.json"
build_arguments=(build --platform "$platform" --slot "$slot"
    --derived-data-path "$derived_data" --result-json "$receipt")
store_path=""
if [[ "$platform" == macos ]]; then
    store_path="$dev_state_dir/data/cloud-slot-$slot/items.json"
    build_arguments+=(--store-path "$store_path")
fi
[[ "$platform" != ios ]] || build_arguments+=(--destination "platform=iOS,id=$device_id")
"$script_dir/cloud-dev.sh" "${build_arguments[@]}"
app_path="$(/usr/bin/plutil -extract app_path raw -o - "$receipt")"
bundle_id="$(/usr/bin/plutil -extract bundle_id raw -o - "$receipt")"
app_group="$(/usr/bin/plutil -extract app_group raw -o - "$receipt")"
container="$(/usr/bin/plutil -extract container raw -o - "$receipt")"
team="$(/usr/bin/plutil -extract team raw -o - "$receipt")"

installed_app="$installed_root/${app_path:t}"
staging_dir="$(/usr/bin/mktemp -d "$installed_root/.cloud-install.XXXXXX")"
staged_app="$staging_dir/${app_path:t}"
ditto_tool="${SNIP_SNAP_DITTO:-/usr/bin/ditto}"
"$ditto_tool" "$app_path" "$staged_app"
if ! signing_policy_verify_cloud_dev_app "$staged_app" "$platform" "$bundle_id" "$app_group" "$container" "$runtime_dir" "$store_path" "$team"; then
    exit 1
fi
if [[ "$platform" == macos ]]; then
    executable="$installed_app/Contents/MacOS/SnipSnapCloudDev$slot"
    for candidate_pid in $(matching_mac_process_ids); do
        /bin/kill "$candidate_pid"
        for _ in {1..30}; do
            /bin/kill -0 "$candidate_pid" 2>/dev/null || break
            /bin/sleep 0.1
        done
        if /bin/kill -0 "$candidate_pid" 2>/dev/null; then
            print -u2 "Close Snip Snap Cloud Dev $slot before rebuilding it."
            exit 1
        fi
    done
fi
# Keep build output unopened. Only this verified installed copy is launched.
backup_app="$staging_dir/previous.app"
[[ ! -e "$installed_app" ]] || /bin/mv "$installed_app" "$backup_app"
/bin/mv "$staged_app" "$installed_app"
if [[ "$platform" == macos ]]; then
    open_tool="${SNIP_SNAP_OPEN:-/usr/bin/open}"
    "$open_tool" -n --env "SNIP_SNAP_STORE_PATH=$store_path" \
        --env SNIP_SNAP_SHOW_PANEL_ON_LAUNCH=1 "$installed_app"
    for _ in {1..30}; do
        [[ -z "$(matching_mac_process_ids)" ]] || break
        /bin/sleep 0.1
    done
    if [[ -z "$(matching_mac_process_ids)" ]]; then
        print -u2 "Snip Snap Cloud Dev $slot did not stay open."
        exit 1
    fi
else
    xcrun_tool="${SNIP_SNAP_XCRUN:-xcrun}"
    "$xcrun_tool" devicectl device install app --device "$device_id" "$installed_app"
    "$xcrun_tool" devicectl device process launch --device "$device_id" --terminate-existing "$bundle_id"
fi
print "Opened Snip Snap Cloud Dev $slot on $platform (Development iCloud)."
print "Runtime: $runtime_dir"
