#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"

slot="$("$script_dir/dev-slot.sh" claim)"
state_dir="${SNIP_SNAP_DEV_STATE_DIR:-$HOME/Library/Application Support/Snip Snap/Development}"
derived_data="${SNIP_SNAP_DERIVED_DATA:-$state_dir/build/slot-$slot}"
product_name="SnipSnapDev$slot"
app_path="$derived_data/Build/Products/Debug/$product_name.app"
store_path="$state_dir/data/slot-$slot/items.json"

print "Building Snip Snap Dev $slot for this worktree."
SNIP_SNAP_DEV_SLOT="$slot" SNIP_SNAP_DERIVED_DATA="$derived_data" "$script_dir/build.sh"

pkill -x "$product_name" 2>/dev/null || true
for _ in {1..20}; do
    if ! pgrep -x "$product_name" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
if pgrep -x "$product_name" >/dev/null 2>&1; then
    print -u2 "Snip Snap Dev $slot did not quit. Close it and run this command again."
    exit 1
fi
open -n \
    --env "SNIP_SNAP_STORE_PATH=$store_path" \
    --env "SNIP_SNAP_SHOW_PANEL_ON_LAUNCH=1" \
    "$app_path"

print "Opened Snip Snap Dev $slot. Its Accessibility grant and data stay with this slot."
