#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source "$script_dir/release-automation.sh"

release_automation_build_number "${1:-}" "${SNIP_SNAP_BUILD_OFFSET:-6}"
