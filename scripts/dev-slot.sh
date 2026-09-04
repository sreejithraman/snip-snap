#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
state_dir="${SNIP_SNAP_DEV_STATE_DIR:-$HOME/Library/Application Support/Snip Snap/Development}"
claims_dir="$state_dir/claims"
preferred_slot_count=4
max_slot=1000
worktree_dir="${SNIP_SNAP_DEV_WORKTREE:-$(git -C "$repo_dir" rev-parse --show-toplevel)}"

usage() {
    print -u2 "Usage: $0 [claim|list|release]"
}

is_slot_number() {
    [[ "$1" =~ '^[1-9][0-9]*$' ]]
}

validate_slot() {
    local slot="$1"
    if ! is_slot_number "$slot" || (( slot > max_slot )); then
        print -u2 "SNIP_SNAP_DEV_SLOT must be a number from 1 through $max_slot."
        return 1
    fi
}

owner_for_slot() {
    local owner_file="$claims_dir/slot-$1/owner"
    [[ -f "$owner_file" ]] && <"$owner_file"
}

each_slot_number() {
    local dir n
    for dir in "$claims_dir"/slot-*(N); do
        [[ -d "$dir" ]] || continue
        n="${dir##*-}"
        is_slot_number "$n" || continue
        print -r -- "$n"
    done
}

owned_slot_for_worktree() {
    local n owner
    for n in ${(f)"$(each_slot_number)"}; do
        is_slot_number "$n" || continue
        owner="$(owner_for_slot "$n" || true)"
        if [[ "$owner" == "$worktree_dir" ]]; then
            print "$n"
            return
        fi
    done
    return 1
}

prune_stale_claims() {
    local n claim_dir owner_file owner current_owner
    for n in ${(f)"$(each_slot_number)"}; do
        is_slot_number "$n" || continue
        claim_dir="$claims_dir/slot-$n"
        owner_file="$claim_dir/owner"
        [[ -f "$owner_file" ]] || continue

        owner="$(<"$owner_file" 2>/dev/null || true)"
        [[ -n "$owner" && ! -d "$owner" ]] || continue

        current_owner="$(<"$owner_file" 2>/dev/null || true)"
        [[ "$current_owner" == "$owner" && ! -d "$current_owner" ]] || continue

        rm -f "$owner_file"
        rmdir "$claim_dir" 2>/dev/null || true
    done
}

claim_slot() {
    mkdir -p "$claims_dir"
    prune_stale_claims

    local slot owner claim_dir owned_slot
    if [[ -n "${SNIP_SNAP_DEV_SLOT:-}" ]]; then
        validate_slot "$SNIP_SNAP_DEV_SLOT" || return 1
    fi

    owned_slot="$(owned_slot_for_worktree || true)"
    if [[ -n "$owned_slot" ]]; then
        if [[ -n "${SNIP_SNAP_DEV_SLOT:-}" && "$SNIP_SNAP_DEV_SLOT" != "$owned_slot" ]]; then
            print -u2 "This worktree already owns Snip Snap Dev $owned_slot."
            print -u2 "Release it before asking for Snip Snap Dev $SNIP_SNAP_DEV_SLOT."
            return 1
        fi
        print "$owned_slot"
        return
    fi

    if [[ -n "${SNIP_SNAP_DEV_SLOT:-}" ]]; then
        slot="$SNIP_SNAP_DEV_SLOT"
        owner="$(owner_for_slot "$slot" || true)"
        if [[ -n "$owner" ]]; then
            print -u2 "Snip Snap Dev $slot belongs to $owner."
            print -u2 "Release it there, or choose another SNIP_SNAP_DEV_SLOT."
            return 1
        fi
        claim_dir="$claims_dir/slot-$slot"
        if mkdir "$claim_dir" 2>/dev/null; then
            print -r -- "$worktree_dir" > "$claim_dir/owner"
            print "$slot"
            return
        fi
        print -u2 "Another worktree claimed Snip Snap Dev $slot. Try again."
        return 1
    fi

    for (( slot = 1; slot <= max_slot; slot++ )); do
        claim_dir="$claims_dir/slot-$slot"
        if mkdir "$claim_dir" 2>/dev/null; then
            print -r -- "$worktree_dir" > "$claim_dir/owner"
            print "$slot"
            return
        fi
    done

    print -u2 "Could not allocate a Snip Snap development slot."
    print -u2 "Run $0 list to see their owners."
    return 1
}

list_slots() {
    mkdir -p "$claims_dir"
    prune_stale_claims

    integer last=$preferred_slot_count
    local slot owner claim_dir
    for slot in ${(f)"$(each_slot_number)"}; do
        is_slot_number "$slot" || continue
        (( slot > last )) && last=$slot
    done

    for (( slot = 1; slot <= last; slot++ )); do
        claim_dir="$claims_dir/slot-$slot"
        owner="$(owner_for_slot "$slot" || true)"
        if [[ -n "$owner" ]]; then
            print "Snip Snap Dev $slot: $owner"
        elif [[ -d "$claim_dir" ]]; then
            print "Snip Snap Dev $slot: claim in progress"
        else
            print "Snip Snap Dev $slot: available"
        fi
    done
}

release_slot() {
    mkdir -p "$claims_dir"

    local slot owner claim_dir released=false
    for slot in ${(f)"$(each_slot_number)"}; do
        is_slot_number "$slot" || continue
        claim_dir="$claims_dir/slot-$slot"
        owner="$(owner_for_slot "$slot" || true)"
        if [[ "$owner" == "$worktree_dir" ]]; then
            rm -f "$claim_dir/owner"
            rmdir "$claim_dir"
            print "Released Snip Snap Dev $slot."
            released=true
        fi
    done

    if [[ "$released" == false ]]; then
        print -u2 "This worktree does not own a Snip Snap development slot."
        return 1
    fi
}

case "${1:-claim}" in
    claim)
        claim_slot
        ;;
    list)
        list_slots
        ;;
    release)
        release_slot
        ;;
    *)
        usage
        exit 2
        ;;
esac
