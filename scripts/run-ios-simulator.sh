#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
simulator_id="${1:-}"
[[ -n "$simulator_id" && $# == 1 ]] || {
    print -u2 "Usage: scripts/run.sh ios-simulator SIMULATOR_ID"
    exit 2
}
exec "$script_dir/dev-ios-simulator.sh" --simulator-id "$simulator_id"
