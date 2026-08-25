#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
state_dir="${SNIP_SNAP_SHOWROOM_STATE_DIR:-}"
derived_data=""
app_path=""
executable_path=""
pid_path=""
build_log=""
process_name="SnipSnapReview"

configure_state() {
    local output_path="$1"
    if [[ -z "$state_dir" ]]; then
        state_dir="${output_path:h}/runtime"
    fi
    derived_data="$state_dir/derived-data"
    app_path="$derived_data/Build/Products/Debug/SnipSnapReview.app"
    executable_path="$app_path/Contents/MacOS/$process_name"
    pid_path="$state_dir/process.pid"
    build_log="${output_path:h}/build.log"
}

matching_process_ids() {
    local candidate_pid command_path
    for candidate_pid in $(/usr/bin/pgrep -x "$process_name" 2>/dev/null || true); do
        command_path="$(/bin/ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
        if [[ "$command_path" == "$executable_path" ||
              "$command_path" == "$executable_path "* ]]; then
            print -r -- "$candidate_pid"
        fi
    done
}

describe() {
    print -r -- '{
  "protocol_version": 1,
  "surfaces": {
    "device": {
      "start": ["device-start"],
      "verify": ["device-verify"],
      "lifecycle_owner": "manual",
      "required_arguments": []
    }
  }
}'
}

result_path() {
    local argument
    while (( $# > 0 )); do
        argument="$1"
        shift
        if [[ "$argument" == "--result-json" && $# > 0 ]]; then
            print -r -- "$1"
            return
        fi
    done
    print -u2 "Missing --result-json."
    return 2
}

write_result() {
    local output_path="$1"
    local operation="$2"
    local verification_status="$3"
    local detail="$4"
    local app_check="$5"
    local process_check="$6"
    local log_paths='[]'
    if [[ -f "$build_log" ]]; then
        log_paths="[\"$build_log\"]"
    fi
    /bin/mkdir -p "${output_path:h}"
    print -r -- "{
  \"protocol_version\": 1,
  \"surface\": \"device\",
  \"operation\": \"$operation\",
  \"verification\": {
    \"status\": \"$verification_status\",
    \"detail\": \"$detail\",
    \"checks\": {
      \"app\": \"$app_check\",
      \"process\": \"$process_check\"
    }
  },
  \"location\": {
    \"device\": \"Snip Snap Review on this Mac\"
  },
  \"evidence_paths\": [],
  \"log_paths\": $log_paths,
  \"availability_limitations\": [
    \"Available only while this Mac stays logged in; Showroom owns the private review build.\"
  ]
}" > "$output_path"
}

start_device() {
    local output_path prior_pids_path current_pids_path
    output_path="$(result_path "$@")"
    configure_state "$output_path"
    /bin/mkdir -p "$state_dir"
    /bin/rm -f "$pid_path"
    prior_pids_path="$state_dir/prior-processes"
    current_pids_path="$state_dir/current-processes"
    matching_process_ids > "$prior_pids_path"
    if ! /usr/bin/xcodebuild \
        -project "$repo_dir/SnipSnap.xcodeproj" \
        -scheme SnipSnap \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$derived_data" \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        PRODUCT_BUNDLE_IDENTIFIER=world.sree.snipsnap.review \
        PRODUCT_NAME="$process_name" \
        INFOPLIST_KEY_CFBundleDisplayName='Snip Snap Review' \
        build > "$build_log" 2>&1; then
        write_result "$output_path" start failed "The review app did not build." failed blocked
        return
    fi

    /usr/bin/open -n \
        --env "SNIP_SNAP_STORE_PATH=$state_dir/items.json" \
        --env "SNIP_SNAP_SHOW_PANEL_ON_LAUNCH=1" \
        "$app_path"
    for _ in {1..30}; do
        local launched_pid
        matching_process_ids > "$current_pids_path"
        launched_pid="$(
            /usr/bin/comm -13 \
                <(/usr/bin/sort -n "$prior_pids_path") \
                <(/usr/bin/sort -n "$current_pids_path") \
                | /usr/bin/head -n 1
        )"
        if [[ "$launched_pid" =~ '^[1-9][0-9]*$' ]]; then
            print -r -- "$launched_pid" > "$pid_path"
            write_result "$output_path" start passed "The signed review app built and opened." passed passed
            return
        fi
        /bin/sleep 0.1
    done
    write_result "$output_path" start failed "The review app built but did not stay open." passed failed
}

verify_device() {
    local output_path app_check=failed process_check=failed verification_status=failed
    local detail="The review app is not running."
    output_path="$(result_path "$@")"
    configure_state "$output_path"
    [[ -d "$app_path" ]] && app_check=passed
    if [[ -f "$pid_path" ]]; then
        local review_pid command_path
        review_pid="$(<"$pid_path")"
        if [[ "$review_pid" =~ '^[1-9][0-9]*$' ]] && /bin/kill -0 "$review_pid" 2>/dev/null; then
            command_path="$(/bin/ps -p "$review_pid" -o command= 2>/dev/null || true)"
            if [[ "$command_path" == "$executable_path" ||
                  "$command_path" == "$executable_path "* ]]; then
                process_check=passed
            fi
        fi
    fi
    if [[ "$app_check" == passed && "$process_check" == passed ]]; then
        verification_status=passed
        detail="The signed review app is present and running."
    fi
    write_result "$output_path" verify "$verification_status" "$detail" "$app_check" "$process_check"
}

case "${1:-}" in
    describe)
        describe
        ;;
    device-start)
        shift
        start_device "$@"
        ;;
    device-verify)
        shift
        verify_device "$@"
        ;;
    *)
        print -u2 "Usage: $0 describe --json | device-start --result-json PATH | device-verify --result-json PATH"
        exit 2
        ;;
esac
