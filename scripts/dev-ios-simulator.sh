#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
source "$script_dir/signing-policy.sh"
simulator_id=""
build_log=""
while (( $# )); do
    case "$1" in
        --simulator-id|--build-log)
            (( $# >= 2 )) || { print -u2 "Missing value for $1"; exit 2; }
            if [[ "$1" == --simulator-id ]]; then simulator_id="$2"; else build_log="$2"; fi
            shift 2
            ;;
        *)
            print -u2 "Usage: scripts/run.sh --ios-simulator [--simulator-id UUID] [--build-log PATH]"
            exit 2
            ;;
    esac
done

# Require a booted iOS device; never boot or alter a user's other simulators.
simulator_id="$(xcrun simctl list devices available --json | /usr/bin/ruby -rjson -e '
devices = JSON.parse(STDIN.read).fetch("devices").select { |runtime, _| runtime.include?("iOS") }.values.flatten
booted = devices.select { |device| device["state"] == "Booted" }
requested = ARGV.fetch(0)
selected = requested.empty? ? (booted.one? ? booted.first : nil) : booted.find { |device| device["udid"] == requested }
abort "Select one booted iOS simulator with --simulator-id UUID (or boot one in Simulator)." unless selected
puts selected.fetch("udid")
' "$simulator_id")"

slot="$("$script_dir/dev-slot.sh" claim)"
dev_state_dir="${SNIP_SNAP_DEV_STATE_DIR:-$HOME/Library/Application Support/Snip Snap/Development}"
derived_data="${SNIP_SNAP_IOS_DERIVED_DATA:-$dev_state_dir/build/ios-slot-$slot}"
lock_dir="$dev_state_dir/locks/ios-slot-$slot"
/bin/mkdir -p "${lock_dir:h}" "$derived_data"
if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
    print -u2 "Snip Snap iOS Dev $slot is already building or starting. Check $lock_dir."
    exit 1
fi
trap '/bin/rmdir "$lock_dir" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

settings_file="$derived_data/resolved-build-settings.txt"
destination="platform=iOS Simulator,id=$simulator_id"
signing_policy_capture_build_settings "$repo_dir" Debug "$destination" "$settings_file" "$derived_data" SnipSnapiOS
base_identifier="$(signing_policy_resolve_setting "$settings_file" SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER SnipSnapiOS)"
product_name="$(signing_policy_resolve_setting "$settings_file" PRODUCT_NAME SnipSnapiOS)"
[[ -n "$base_identifier" && -n "$product_name" ]] || { print -u2 "Could not resolve iOS app identity."; exit 1; }
bundle_identifier="$base_identifier.dev$slot"
app_path="$derived_data/Build/Products/Debug-iphonesimulator/$product_name.app"
build_log="${build_log:-$derived_data/build.log}"
/bin/mkdir -p "${build_log:h}"
print "Building Snip Snap iOS Dev $slot. Log: $build_log"
xcodebuild -project "$repo_dir/SnipSnap.xcodeproj" -scheme SnipSnapiOS \
    -configuration Debug -destination "$destination" -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    "SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS=$repo_dir/SnipSnapiOS/SnipSnapiOS.entitlements" \
    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER= \
    ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev \
    "SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER=$bundle_identifier" \
    "SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER=$bundle_identifier.share" \
    "SNIP_SNAP_APP_GROUP_IDENTIFIER=group.$bundle_identifier" \
    "SNIP_SNAP_DISPLAY_NAME=Snip Snap Dev $slot" \
    "SNIP_SNAP_SHARE_DISPLAY_NAME=Save to Snip Snap Dev $slot" \
    build > "$build_log" 2>&1 || { /usr/bin/tail -n 60 "$build_log"; exit 1; }

# Verify the build before any install can touch a simulator application.
actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
[[ "$actual_identifier" == "$bundle_identifier" ]] || { print -u2 "Dev bundle identity did not match."; exit 1; }
xcrun simctl terminate "$simulator_id" "$bundle_identifier" 2>/dev/null || true
xcrun simctl install "$simulator_id" "$app_path"
xcrun simctl launch "$simulator_id" "$bundle_identifier"
print "Opened Snip Snap iOS Dev $slot"
print "Simulator: $simulator_id"
print "Bundle: $bundle_identifier"
print "App: $app_path"
print "App group: group.$bundle_identifier"
