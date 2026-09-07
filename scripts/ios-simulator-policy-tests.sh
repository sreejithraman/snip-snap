#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
test_dir="$(mktemp -d)"
trap '/bin/rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
export SNIP_SNAP_DEV_STATE_DIR="$test_dir/state"
export SNIP_SNAP_DEV_WORKTREE="${script_dir:h}"
export FAKE_SIM_LOG="$test_dir/sim.log"
export FAKE_BUILD_LOG="$test_dir/build.log"
unset SNIP_SNAP_DEV_SLOT SNIP_SNAP_IOS_DERIVED_DATA SNIP_SNAP_XCODEBUILD
cat > "$test_dir/bin/xcrun" <<'STUB'
#!/bin/zsh
if [[ "$*" == 'simctl list devices available --json' ]]; then
 print -r -- '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"state":"Booted","udid":"TEST-SIM"}]}}'
elif [[ "$1" == simctl ]]; then
 print -r -- "$*" >> "$FAKE_SIM_LOG"
fi
STUB
cat > "$test_dir/bin/xcodebuild" <<'STUB'
#!/bin/zsh
if [[ "$*" == *'-showBuildSettings'* ]]; then
 print -r -- 'Build settings for action build and target SnipSnapiOS:'
 print -r -- '    SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER = org.example.snipsnap.ios'
 print -r -- '    PRODUCT_NAME = Snip Snap iOS'
 exit 0
fi
print -r -- "$*" >> "$FAKE_BUILD_LOG"
while (( $# )); do
 case "$1" in
 -derivedDataPath) build_root="$2"; shift 2;;
 SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER=*) bundle_id="${1#*=}"; shift;;
 *) shift;;
 esac
done
[[ "${FAKE_WRONG_ID:-}" != 1 ]] || bundle_id=org.example.production
mkdir -p "$build_root/Build/Products/Debug-iphonesimulator/Snip Snap iOS.app"
plist="$build_root/Build/Products/Debug-iphonesimulator/Snip Snap iOS.app/Info.plist"
rm -f "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$plist" >/dev/null
STUB
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
"$script_dir/run.sh" --ios-simulator --simulator-id TEST-SIM > "$test_dir/output"
grep -F 'simctl install TEST-SIM' "$FAKE_SIM_LOG" >/dev/null
grep -F 'simctl launch TEST-SIM org.example.snipsnap.ios.dev1' "$FAKE_SIM_LOG" >/dev/null
for required in \
 'SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER=org.example.snipsnap.ios.dev1.share' \
 'SNIP_SNAP_APP_GROUP_IDENTIFIER=group.org.example.snipsnap.ios.dev1' \
 'SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER=' \
 'SNIP_SNAP_DISPLAY_NAME=Snip Snap Dev 1' \
 'ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev'; do
 grep -F "$required" "$FAKE_BUILD_LOG" >/dev/null
done
if grep -E '(^| )CODE_SIGN_ENTITLEMENTS=' "$FAKE_BUILD_LOG" >/dev/null; then
 print -u2 'Global app entitlements would affect package targets'; exit 1
fi
grep -F 'SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS=' "$FAKE_BUILD_LOG" >/dev/null
cp "$FAKE_SIM_LOG" "$test_dir/before"
if "$script_dir/run.sh" --ios-simulator --simulator-id NOT-BOOTED > "$test_dir/output" 2>&1; then
 print -u2 'Accepted a simulator that was not booted'; exit 1
fi
cmp "$test_dir/before" "$FAKE_SIM_LOG"
if FAKE_WRONG_ID=1 "$script_dir/run.sh" --ios-simulator > "$test_dir/output" 2>&1; then
 print -u2 'Accepted a build with the wrong bundle ID'; exit 1
fi
cmp "$test_dir/before" "$FAKE_SIM_LOG"
print 'iOS Simulator Dev policy tests passed.'
