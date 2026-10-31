#!/bin/zsh

# Callers own the EXIT/signal traps and provide their already-owned work directory.
share_fixture_pid=""
share_fixture_url=""
share_fixture_work_dir=""

share_fixture_cleanup() {
    if [[ -n "$share_fixture_pid" ]]; then
        /bin/kill "$share_fixture_pid" >/dev/null 2>&1 || true
        wait "$share_fixture_pid" 2>/dev/null || true
        share_fixture_pid=""
        print "Share fixture stopped."
    fi
    share_fixture_url=""
    if [[ -n "$share_fixture_work_dir" ]]; then
        /bin/rm -rf "$share_fixture_work_dir"
        share_fixture_work_dir=""
    fi
}

share_fixture_start() {
    local work_dir="$1"
    local fixture_script="$2"
    local context="$3"
    [[ -z "$share_fixture_pid" && -z "$share_fixture_work_dir" ]] || {
        print -u2 "$context: this runner already owns a Share fixture."
        return 1
    }
    share_fixture_work_dir="$(/usr/bin/mktemp -d "$work_dir/share-fixture.XXXXXX")" || return 1
    local root="$share_fixture_work_dir/pages"
    local port_file="$share_fixture_work_dir/port"
    local log_file="$share_fixture_work_dir/server.log"
    /bin/mkdir -p "$root" || return 1
    print -r -- '<!doctype html><html><head><title>Snip Snap Share Fixture</title></head><body><h1>Snip Snap Share Fixture</h1></body></html>' > "$root/index.html" || return 1
    "${SNIP_SNAP_PYTHON:-python3}" "$fixture_script" "$root" "$port_file" 0 \
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
    [[ "$port" == <1-65535> ]] || {
        print -u2 "$context: the local Share fixture returned an invalid port."
        return 1
    }
    share_fixture_url="http://127.0.0.1:$port/"
    print "Share fixture started: $share_fixture_url"
}
