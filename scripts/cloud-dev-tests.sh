#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-cloud-dev-tests.XXXXXX)"
cleanup() {
    [[ "$test_root" == /private/tmp/snip-snap-cloud-dev-tests.* ]] && /bin/rm -rf "$test_root"
}
trap cleanup EXIT

fail_test() {
    print -u2 "Cloud Dev build test failed: $1"
    exit 1
}

entitlements="$test_root/Development.entitlements"
/usr/bin/plutil -create xml1 "$entitlements"
/usr/bin/plutil -insert aps-environment -string development "$entitlements"
/usr/bin/plutil -insert 'com\.apple\.security\.application-groups' \
    -json '["$(SNIP_SNAP_APP_GROUP_IDENTIFIER)"]' "$entitlements"
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-container-identifiers' \
    -json '["$(SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER)"]' "$entitlements"
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-services' \
    -json '["CloudKit"]' "$entitlements"
/usr/bin/plutil -insert 'com\.apple\.developer\.icloud-container-environment' \
    -string Development "$entitlements"

fake_xcodebuild="$test_root/xcodebuild"
args_file="$test_root/args"
print -r -- '#!/bin/zsh
set -euo pipefail
print -r -- "$@" >> "$SNIP_SNAP_FAKE_XCODEBUILD_ARGS"
target=SnipSnapiOS
for (( index = 1; index <= $#; index++ )); do
    if [[ "${@[$index]}" == -target ]]; then
        target="${@[$(( index + 1 ))]}"
    fi
done
root="${SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER:-org.example.snipsnap}"
ios_product="${SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER:-$root.ios}"
share_product="${SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER:-$ios_product.share}"
group="${SNIP_SNAP_APP_GROUP_IDENTIFIER:-group.org.example.snipsnap}"
if [[ "$target" == SnipSnapShareExtension ]]; then
    product="$share_product"
    entitlements=SnipSnapShareExtension/SnipSnapShareExtension.entitlements
else
    product="$ios_product"
    entitlements="$SNIP_SNAP_FAKE_ENTITLEMENTS"
fi
if [[ "$*" == *-showBuildSettings* ]]; then
    print -r -- "Build settings for action build and target $target:"
    print -r -- "    DEVELOPMENT_TEAM = FAKE123456"
    print -r -- "    PRODUCT_BUNDLE_IDENTIFIER = $product"
    print -r -- "    SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER = $root"
    print -r -- "    SNIP_SNAP_APP_GROUP_IDENTIFIER = $group"
    print -r -- "    SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER = iCloud.org.example.snipsnap"
    print -r -- "    CODE_SIGN_ENTITLEMENTS = $entitlements"
fi' > "$fake_xcodebuild"
/bin/chmod +x "$fake_xcodebuild"

SNIP_SNAP_XCODEBUILD="$fake_xcodebuild" \
SNIP_SNAP_FAKE_XCODEBUILD_ARGS="$args_file" \
SNIP_SNAP_FAKE_ENTITLEMENTS="$entitlements" \
SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS="$entitlements" \
SNIP_SNAP_CLOUD_DEV_DERIVED_DATA="$test_root/DerivedData" \
    "$script_dir/cloud-dev.sh" build >/dev/null

/usr/bin/grep -F -- \
    'SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER=org.example.snipsnap.ios.dev' \
    "$args_file" >/dev/null || fail_test "the Dev app identifier was not isolated"
/usr/bin/grep -F -- \
    'SNIP_SNAP_IOS_SHARE_PRODUCT_BUNDLE_IDENTIFIER=org.example.snipsnap.ios.dev.share' \
    "$args_file" >/dev/null || fail_test "the Dev Share identifier was not isolated"
/usr/bin/grep -F -- \
    'SNIP_SNAP_APP_GROUP_IDENTIFIER=group.org.example.snipsnap.dev' \
    "$args_file" >/dev/null || fail_test "the App Group was not isolated"
/usr/bin/grep -F -- 'SNIP_SNAP_BUILD_LANE=cloud-dev' "$args_file" >/dev/null || \
    fail_test "the build lane was not marked"
/usr/bin/grep -F -- 'DEVELOPMENT_TEAM=FAKE123456' "$args_file" >/dev/null || \
    fail_test "the development team did not reach the signed build"
/usr/bin/grep -F -- \
    'SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER=iCloud.org.example.snipsnap' \
    "$args_file" >/dev/null || fail_test "the CloudKit container did not reach the signed build"
/usr/bin/grep -F -- 'ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev' \
    "$args_file" >/dev/null || fail_test "the Dev icon was not selected"
/usr/bin/grep -F -- 'SNIP_SNAP_DISPLAY_NAME=Snip Snap Dev' \
    "$args_file" >/dev/null || fail_test "the Dev display name was not selected"
/usr/bin/grep -F -- 'SNIP_SNAP_SHARE_DISPLAY_NAME=Save to Snip Snap Dev' \
    "$args_file" >/dev/null || fail_test "the Dev Share name was not selected"

explicit_args="$test_root/explicit-args"
SNIP_SNAP_XCODEBUILD="$fake_xcodebuild" \
SNIP_SNAP_FAKE_XCODEBUILD_ARGS="$explicit_args" \
SNIP_SNAP_FAKE_ENTITLEMENTS="$entitlements" \
SNIP_SNAP_IOS_APP_CODE_SIGN_ENTITLEMENTS="$entitlements" \
SNIP_SNAP_DEV_IOS_PRODUCT_BUNDLE_IDENTIFIER=org.example.snipsnap.ios.teamdev \
SNIP_SNAP_DEV_APP_GROUP_IDENTIFIER=group.org.example.snipsnap.teamdev \
SNIP_SNAP_CLOUD_DEV_DERIVED_DATA="$test_root/ExplicitDerivedData" \
    "$script_dir/cloud-dev.sh" build >/dev/null
/usr/bin/grep -F -- \
    'SNIP_SNAP_IOS_PRODUCT_BUNDLE_IDENTIFIER=org.example.snipsnap.ios.teamdev' \
    "$explicit_args" >/dev/null || fail_test "the explicit Dev app identifier was ignored"
/usr/bin/grep -F -- \
    'SNIP_SNAP_APP_GROUP_IDENTIFIER=group.org.example.snipsnap.teamdev' \
    "$explicit_args" >/dev/null || fail_test "the explicit App Group was ignored"

print "Cloud Dev build checks passed."
