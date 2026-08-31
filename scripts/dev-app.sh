#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
source "$script_dir/signing-policy.sh"
program="$0"
dev_state_dir="${SNIP_SNAP_DEV_STATE_DIR:-$HOME/Library/Application Support/Snip Snap/Development}"
current_worktree_dir="${SNIP_SNAP_DEV_WORKTREE:-$(git -C "$repo_dir" rev-parse --show-toplevel)}"
recorded_worktree_dir=""
runtime_dir=""
result_json=""
build_log=""
slot=""
derived_data=""
process_name=""
app_path=""
executable_path=""
store_path=""
lock_dir=""

usage() {
    print -u2 "Usage: $program build | start [--runtime-dir PATH] [--build-log PATH] [--result-json PATH] | status --runtime-dir PATH [--result-json PATH]"
}

parse_options() {
    local argument
    while (( $# > 0 )); do
        argument="$1"
        shift
        case "$argument" in
            --runtime-dir)
                (( $# > 0 )) || { usage; return 2; }
                runtime_dir="$1"
                shift
                ;;
            --build-log)
                (( $# > 0 )) || { usage; return 2; }
                build_log="$1"
                shift
                ;;
            --result-json)
                (( $# > 0 )) || { usage; return 2; }
                result_json="$1"
                shift
                ;;
            *)
                usage
                return 2
                ;;
        esac
    done
}

configure_claimed_slot() {
    slot="$("$script_dir/dev-slot.sh" claim)"
    derived_data="${SNIP_SNAP_DERIVED_DATA:-$dev_state_dir/build/slot-$slot}"
    process_name="SnipSnapDev$slot"
    app_path="$derived_data/Build/Products/Debug/$process_name.app"
    executable_path="$app_path/Contents/MacOS/$process_name"
    store_path="$dev_state_dir/data/slot-$slot/items.json"
    runtime_dir="${runtime_dir:-$dev_state_dir/runtime/slot-$slot}"
    lock_dir="$dev_state_dir/locks/slot-$slot"
}

release_lock() {
    local owner=""
    [[ -n "$lock_dir" && -d "$lock_dir" ]] || return
    [[ -f "$lock_dir/owner" ]] && owner="$(/bin/cat "$lock_dir/owner" 2>/dev/null || true)"
    [[ "$owner" == "$$" ]] || return
    /bin/rm -f "$lock_dir/owner"
    /bin/rmdir "$lock_dir" 2>/dev/null || true
}

acquire_lock() {
    local attempt owner
    /bin/mkdir -p "${lock_dir:h}"
    for attempt in {1..300}; do
        if /bin/mkdir "$lock_dir" 2>/dev/null; then
            print -r -- "$$" > "$lock_dir/owner"
            trap release_lock EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM
            return
        fi

        owner=""
        [[ -f "$lock_dir/owner" ]] && owner="$(/bin/cat "$lock_dir/owner" 2>/dev/null || true)"
        if [[ -z "$owner" ]] && (( attempt > 20 )); then
            /bin/rmdir "$lock_dir" 2>/dev/null || true
            continue
        fi
        if [[ "$owner" =~ '^[1-9][0-9]*$' ]] && ! /bin/kill -0 "$owner" 2>/dev/null; then
            if [[ "$(/bin/cat "$lock_dir/owner" 2>/dev/null || true)" == "$owner" ]]; then
                /bin/rm -f "$lock_dir/owner"
                /bin/rmdir "$lock_dir" 2>/dev/null || true
            fi
            continue
        fi
        /bin/sleep 0.1
    done
    print -u2 "Snip Snap Dev $slot is already building or starting."
    return 1
}

matching_process_ids() {
    local candidate_pid
    for candidate_pid in $(/usr/bin/pgrep -x "$process_name" 2>/dev/null || true); do
        if process_matches_executable "$candidate_pid"; then
            print -r -- "$candidate_pid"
        fi
    done
}

process_matches_executable() {
    local candidate_pid="$1"
    local command_path
    command_path="$(/bin/ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
    [[ "$command_path" == "$executable_path" ||
       "${command_path#"$executable_path "}" != "$command_path" ]]
}

first_matching_process_id() {
    local candidate_pid
    for candidate_pid in $(matching_process_ids); do
        print -r -- "$candidate_pid"
        return
    done
}

stop_running_app() {
    local candidate_pid
    for candidate_pid in $(matching_process_ids); do
        /bin/kill "$candidate_pid" 2>/dev/null || true
    done
    for _ in {1..20}; do
        [[ -z "$(matching_process_ids)" ]] && return
        /bin/sleep 0.1
    done
    print -u2 "Snip Snap Dev $slot did not quit. Close it and try again."
    return 1
}

run_signed_build() {
    local settings_file="$derived_data/resolved-build-settings.txt"
    local development_team=""
    local product_bundle_identifier=""
    local -a signing_arguments
    /bin/mkdir -p "$derived_data"
    signing_policy_capture_build_settings \
        "$repo_dir" Debug 'platform=macOS' "$settings_file" "$derived_data" || \
        return 1
    development_team="$(signing_policy_resolve_setting \
        "$settings_file" DEVELOPMENT_TEAM)"
    product_bundle_identifier="$(signing_policy_resolve_setting \
        "$settings_file" SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER)"
    /bin/rm -f "$settings_file"

    if [[ -z "$product_bundle_identifier" ]]; then
        print -u2 "Dev build could not resolve SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER."
        return 1
    fi

    if [[ -z "$development_team" ]]; then
        print "Signed lane: local Dev (ad hoc; CloudKit disabled)."
        signing_arguments=(
            CODE_SIGN_STYLE=Manual
            CODE_SIGN_IDENTITY=-
            DEVELOPMENT_TEAM=
        )
    else
        print "Signed lane: local Dev (developer team; CloudKit disabled)."
        signing_arguments=(
            CODE_SIGN_STYLE=Automatic
            "DEVELOPMENT_TEAM=$development_team"
        )
    fi

    local command=(
        xcodebuild
        -project "$repo_dir/SnipSnap.xcodeproj"
        -scheme SnipSnap
        -configuration Debug
        -destination 'platform=macOS'
        -derivedDataPath "$derived_data"
        CODE_SIGNING_ALLOWED=YES
        CODE_SIGNING_REQUIRED=YES
        CODE_SIGN_ENTITLEMENTS=
        SNIP_SNAP_APP_GROUP_IDENTIFIER=
        SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER=
        "${signing_arguments[@]}"
        "SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=$product_bundle_identifier"
        "SNIP_SNAP_EFFECTIVE_PRODUCT_BUNDLE_IDENTIFIER=$product_bundle_identifier.dev$slot"
        "SNIP_SNAP_PRODUCT_NAME=$process_name"
        "SNIP_SNAP_DISPLAY_NAME=Snip Snap Dev $slot"
        build
    )
    if [[ -n "$build_log" ]]; then
        /bin/mkdir -p "${build_log:h}"
        "${command[@]}" > "$build_log" 2>&1
    else
        "${command[@]}"
    fi
}

clear_runtime_state() {
    /bin/mkdir -p "$runtime_dir"
    /bin/rm -f \
        "$runtime_dir/slot" \
        "$runtime_dir/worktree" \
        "$runtime_dir/process-name" \
        "$runtime_dir/app-path" \
        "$runtime_dir/executable-path" \
        "$runtime_dir/process.pid"
}

write_runtime_state() {
    local launched_pid="$1"
    /bin/mkdir -p "$runtime_dir"
    print -r -- "$slot" > "$runtime_dir/slot"
    print -r -- "$current_worktree_dir" > "$runtime_dir/worktree"
    print -r -- "$process_name" > "$runtime_dir/process-name"
    print -r -- "$app_path" > "$runtime_dir/app-path"
    print -r -- "$executable_path" > "$runtime_dir/executable-path"
    print -r -- "$launched_pid" > "$runtime_dir/process.pid"
}

write_result() {
    local operation="$1"
    local verification_status="$2"
    local detail="$3"
    local app_check="$4"
    local process_check="$5"
    local launched_pid="${6:-}"
    [[ -n "$result_json" ]] || return 0
    /bin/mkdir -p "${result_json:h}"
    /usr/bin/ruby -rjson -e '
slot = ARGV.fetch(0).empty? ? nil : Integer(ARGV.fetch(0))
pid = ARGV.fetch(6).empty? ? nil : Integer(ARGV.fetch(6))
result = {
  "operation" => ARGV.fetch(1),
  "slot" => slot,
  "status" => ARGV.fetch(2),
  "detail" => ARGV.fetch(3),
  "checks" => {
    "app" => ARGV.fetch(4),
    "process" => ARGV.fetch(5)
  },
  "pid" => pid
}
File.write(ARGV.fetch(7), JSON.pretty_generate(result) + "\n")
' "$slot" "$operation" "$verification_status" "$detail" "$app_check" "$process_check" "$launched_pid" "$result_json"
}

build_app() {
    configure_claimed_slot
    acquire_lock
    print "Building Snip Snap Dev $slot for this worktree."
    run_signed_build
    print "Built Snip Snap Dev $slot."
}

start_app() {
    local launched_pid=""
    configure_claimed_slot
    acquire_lock
    clear_runtime_state
    if ! stop_running_app; then
        write_result start blocked "Snip Snap Dev $slot did not quit before the build." passed blocked
        return 1
    fi
    print "Building Snip Snap Dev $slot for this worktree."
    if ! run_signed_build; then
        write_result start failed "Snip Snap Dev $slot did not build." failed blocked
        return 1
    fi
    if ! /usr/bin/open -n \
        --env "SNIP_SNAP_STORE_PATH=$store_path" \
        --env "SNIP_SNAP_SHOW_PANEL_ON_LAUNCH=1" \
        "$app_path"; then
        write_result start failed "Snip Snap Dev $slot did not open." passed failed
        return 1
    fi
    for _ in {1..30}; do
        launched_pid="$(first_matching_process_id)"
        if [[ "$launched_pid" =~ '^[1-9][0-9]*$' ]]; then
            write_runtime_state "$launched_pid"
            write_result start passed "Snip Snap Dev $slot built and opened." passed passed "$launched_pid"
            print "Opened Snip Snap Dev $slot. Its Accessibility grant and data stay with this slot."
            return
        fi
        /bin/sleep 0.1
    done
    write_result start failed "Snip Snap Dev $slot built but did not stay open." passed failed
    return 1
}

load_runtime_state() {
    [[ -n "$runtime_dir" ]] || { print -u2 "status requires --runtime-dir."; return 2; }
    local state_file
    for state_file in slot worktree process-name app-path executable-path process.pid; do
        [[ -f "$runtime_dir/$state_file" ]] || return 1
    done
    slot="$(<"$runtime_dir/slot")"
    recorded_worktree_dir="$(<"$runtime_dir/worktree")"
    process_name="$(<"$runtime_dir/process-name")"
    app_path="$(<"$runtime_dir/app-path")"
    executable_path="$(<"$runtime_dir/executable-path")"
    [[ "$slot" =~ '^[1-4]$' ]] || return 1
    [[ -n "$recorded_worktree_dir" ]] || return 1
    [[ "$recorded_worktree_dir" == "$current_worktree_dir" ]] || return 1
    [[ "$process_name" == "SnipSnapDev$slot" ]] || return 1
    [[ "$executable_path" == "$app_path/Contents/MacOS/$process_name" ]] || return 1
    local current_owner=""
    [[ -f "$dev_state_dir/claims/slot-$slot/owner" ]] && \
        current_owner="$(/bin/cat "$dev_state_dir/claims/slot-$slot/owner" 2>/dev/null || true)"
    [[ "$current_owner" == "$current_worktree_dir" ]]
}

status_app() {
    local app_check=failed process_check=failed verification_status=failed
    local detail="No Snip Snap development launch is recorded."
    local launched_pid=""
    if ! load_runtime_state; then
        slot=""
        write_result status failed "$detail" "$app_check" "$process_check"
        return 1
    fi
    [[ -d "$app_path" ]] && app_check=passed
    launched_pid="$(<"$runtime_dir/process.pid")"
    if [[ ! "$launched_pid" =~ '^[1-9][0-9]*$' ]] ||
       ! /bin/kill -0 "$launched_pid" 2>/dev/null ||
       ! process_matches_executable "$launched_pid"; then
        launched_pid="$(first_matching_process_id)"
    fi
    [[ "$launched_pid" =~ '^[1-9][0-9]*$' ]] && process_check=passed
    detail="Snip Snap Dev $slot is not running."
    if [[ "$app_check" == passed && "$process_check" == passed ]]; then
        verification_status=passed
        detail="Snip Snap Dev $slot is present and running."
    fi
    write_result status "$verification_status" "$detail" "$app_check" "$process_check" "$launched_pid"
    [[ "$verification_status" == passed ]]
}

command="${1:-}"
if (( $# > 0 )); then
    shift
fi
parse_options "$@"

case "$command" in
    build)
        [[ -z "$runtime_dir" && -z "$result_json" && -z "$build_log" ]] || { usage; exit 2; }
        build_app
        ;;
    start)
        start_app
        ;;
    status)
        status_app
        ;;
    *)
        usage
        exit 2
        ;;
esac
