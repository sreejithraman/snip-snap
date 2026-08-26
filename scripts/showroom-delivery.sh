#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"

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

write_fallback_dev_result() {
    local dev_result="$1"
    local operation="$2"
    local detail="$3"
    /usr/bin/ruby -rjson -e '
result = {
  "operation" => ARGV.fetch(0),
  "slot" => nil,
  "status" => "failed",
  "detail" => ARGV.fetch(1),
  "checks" => {"app" => "failed", "process" => "failed"},
  "pid" => nil
}
File.write(ARGV.fetch(2), JSON.pretty_generate(result) + "\n")
' "$operation" "$detail" "$dev_result"
}

write_showroom_result() {
    local dev_result="$1"
    local output_path="$2"
    local operation="$3"
    local build_log="$4"
    /bin/mkdir -p "${output_path:h}"
    /usr/bin/ruby -rjson -e '
dev = JSON.parse(File.read(ARGV.fetch(0)))
slot = dev["slot"]
device = slot ? "Snip Snap Dev #{slot} on this Mac" : "Snip Snap development app on this Mac"
limit = if slot
  "Available only while this Mac stays logged in; it shares this worktree\u0027s Snip Snap Dev #{slot} app and data."
else
  "Available only while this Mac stays logged in."
end
build_log = ARGV.fetch(3)
result = {
  "protocol_version" => 1,
  "surface" => "device",
  "operation" => ARGV.fetch(2),
  "verification" => {
    "status" => dev.fetch("status"),
    "detail" => dev.fetch("detail"),
    "checks" => dev.fetch("checks")
  },
  "location" => {"device" => device},
  "evidence_paths" => [],
  "log_paths" => File.file?(build_log) ? [build_log] : [],
  "availability_limitations" => [limit]
}
File.write(ARGV.fetch(1), JSON.pretty_generate(result) + "\n")
' "$dev_result" "$output_path" "$operation" "$build_log"
}

start_device() {
    local output_path runtime_dir dev_result build_log
    output_path="$(result_path "$@")"
    runtime_dir="${SNIP_SNAP_SHOWROOM_STATE_DIR:-${output_path:h}/runtime}"
    dev_result="${output_path:h}/dev-app-start.json"
    build_log="${output_path:h}/build.log"
    /bin/mkdir -p "${output_path:h}"
    /bin/rm -f "$dev_result"
    "$script_dir/dev-app.sh" start \
        --runtime-dir "$runtime_dir" \
        --build-log "$build_log" \
        --result-json "$dev_result" || true
    if [[ ! -f "$dev_result" ]]; then
        write_fallback_dev_result "$dev_result" start "The development app did not start."
    fi
    write_showroom_result "$dev_result" "$output_path" start "$build_log"
}

verify_device() {
    local output_path runtime_dir dev_result build_log
    output_path="$(result_path "$@")"
    runtime_dir="${SNIP_SNAP_SHOWROOM_STATE_DIR:-${output_path:h}/runtime}"
    dev_result="${output_path:h}/dev-app-status.json"
    build_log="${output_path:h}/build.log"
    /bin/mkdir -p "${output_path:h}"
    /bin/rm -f "$dev_result"
    "$script_dir/dev-app.sh" status \
        --runtime-dir "$runtime_dir" \
        --result-json "$dev_result" || true
    if [[ ! -f "$dev_result" ]]; then
        write_fallback_dev_result "$dev_result" status "The development app status could not be read."
    fi
    write_showroom_result "$dev_result" "$output_path" verify "$build_log"
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
