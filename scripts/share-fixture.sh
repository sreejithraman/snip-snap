#!/bin/zsh

# Callers own the EXIT/signal traps and provide their already-owned work directory.
share_fixture_pid=""
share_fixture_port="58493"
share_fixture_lock="/private/tmp/snip-snap-share-fixture-${share_fixture_port}.lock"
share_fixture_lock_owned="0"
share_fixture_work_dir=""

share_fixture_cleanup() {
    if [[ -n "$share_fixture_pid" ]]; then
        /bin/kill "$share_fixture_pid" >/dev/null 2>&1 || true
        wait "$share_fixture_pid" 2>/dev/null || true
        share_fixture_pid=""
        print "Share fixture stopped."
    fi
    if [[ "$share_fixture_lock_owned" == "1" ]]; then
        /bin/rmdir "$share_fixture_lock" >/dev/null 2>&1 || true
        share_fixture_lock_owned="0"
    fi
    if [[ -n "$share_fixture_work_dir" ]]; then
        /bin/rm -rf "$share_fixture_work_dir"
        share_fixture_work_dir=""
    fi
}

share_fixture_start() {
    local work_dir="$1"
    local fixture_script="$2"
    local context="$3"
    /bin/mkdir "$share_fixture_lock" 2>/dev/null || {
        print -u2 "$context: another Share fixture owns loopback port $share_fixture_port."
        return 1
    }
    share_fixture_lock_owned="1"
    share_fixture_work_dir="$(/usr/bin/mktemp -d "$work_dir/share-fixture.XXXXXX")" || return 1
    local root="$share_fixture_work_dir/pages"
    local port_file="$share_fixture_work_dir/port"
    local log_file="$share_fixture_work_dir/server.log"
    /bin/mkdir -p "$root" || return 1
    print -r -- '<!doctype html><html><head><title>Snip Snap Share Fixture</title></head><body><h1>Snip Snap Share Fixture</h1></body></html>' > "$root/index.html" || return 1
    "${SNIP_SNAP_PYTHON:-python3}" "$fixture_script" "$root" "$port_file" "$share_fixture_port" \
        >"$log_file" 2>&1 &
    share_fixture_pid="$!"
    for _ in {1..100}; do
        [[ -s "$port_file" ]] && break
        /bin/kill -0 "$share_fixture_pid" >/dev/null 2>&1 || break
        /bin/sleep 0.05
    done
    [[ -s "$port_file" ]] && /bin/kill -0 "$share_fixture_pid" >/dev/null 2>&1 || {
        print -u2 "$context: the local Share fixture did not start."
        [[ ! -s "$log_file" ]] || /bin/cat "$log_file" >&2
        return 1
    }
    local port="$(/bin/cat "$port_file")"
    [[ "$port" == "$share_fixture_port" ]] || {
        print -u2 "$context: the local Share fixture returned an invalid port."
        return 1
    }
    print "Share fixture started: http://127.0.0.1:$port/"
}
