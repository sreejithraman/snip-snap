#!/bin/zsh

snip_snap_claim_derived_data() {
    if [[ -n "${SNIP_SNAP_DERIVED_DATA:-}" ]]; then
        derived_data="$SNIP_SNAP_DERIVED_DATA"
        derived_data_owner_marker=""
        return
    fi

    derived_data="$(/usr/bin/mktemp -d /private/tmp/snip-snap-derived-data.XXXXXX)"
    derived_data_owner_marker="$derived_data/.snip-snap-owned"
    /usr/bin/touch "$derived_data_owner_marker"
}

snip_snap_cleanup_derived_data() {
    guard_prefix="/private/tmp/snip-snap-derived-data."
    if [[ -n "${derived_data_owner_marker:-}"
        && "$derived_data" == ${guard_prefix}*
        && -f "$derived_data_owner_marker" ]]
    then
        /bin/rm -rf "$derived_data"
    fi
}
