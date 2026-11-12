#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
usage() {
    print -u2 "Usage: scripts/run.sh ios-simulator SIMULATOR_ID [--simulator-set PATH]"
    exit 2
}
(( $# == 1 )) || [[ $# == 3 && "$2" == --simulator-set ]] || usage
[[ -n "$1" ]] || usage
simulator_id="$1"
shift
exec "$script_dir/dev-ios-simulator.sh" --simulator-id "$simulator_id" "$@"
