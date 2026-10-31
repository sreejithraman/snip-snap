#!/bin/zsh -f
set -euo pipefail

if (( $# == 0 )) || [[ "$1" != /* ]]; then
    print -u2 "Usage: $0 /absolute/path/to/tool [arguments...]"
    exit 2
fi

# XCTest can print its entire environment on an invalid invocation.
clean_environment=(PATH=/usr/bin:/bin:/usr/sbin:/sbin)
for key in DEVELOPER_DIR SDKROOT TMPDIR; do
    if (( ${+parameters[$key]} )); then
        clean_environment+=("$key=${(P)key}")
    fi
done
exec /usr/bin/env -i "${clean_environment[@]}" "$@"
