#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source "$script_dir/derived-data.sh"

unset SNIP_SNAP_DERIVED_DATA
snip_snap_claim_derived_data
default_path="$derived_data"
[[ "$default_path" == /private/tmp/snip-snap-derived-data.* ]]
[[ -f "$derived_data_owner_marker" ]]
snip_snap_cleanup_derived_data
[[ ! -e "$default_path" ]]

explicit_path="$(/usr/bin/mktemp -d /private/tmp/snip-snap-explicit-derived-data.XXXXXX)"
SNIP_SNAP_DERIVED_DATA="$explicit_path"
snip_snap_claim_derived_data
[[ "$derived_data" == "$explicit_path" ]]
[[ -z "$derived_data_owner_marker" ]]
snip_snap_cleanup_derived_data
[[ -d "$explicit_path" ]]
/bin/rm -rf "$explicit_path"

print "DerivedData isolation checks passed."
