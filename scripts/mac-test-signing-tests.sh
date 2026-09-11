#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
source "$script_dir/signing-policy.sh"

assert_setting() {
    local actual="$(signing_policy_resolve_setting "$settings" "$1" SnipSnapTests)"
    [[ "$actual" == "$2" ]] || {
        print -u2 "Mac test signing: $1 did not resolve as expected"
        exit 1
    }
}
test_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-test-signing.XXXXXX)"
trap '/bin/rm -rf "$test_root"' EXIT

# Resolve the real project with fake local settings, without signing or building.
/bin/mkdir -p "$test_root/SnipSnap.xcodeproj" "$test_root/Config"
/bin/cp "$repo_dir/SnipSnap.xcodeproj/project.pbxproj" "$test_root/SnipSnap.xcodeproj/"
for config in Shared Debug Release iOSShared iOSDebug iOSRelease MacTests; do
    /bin/cp "$repo_dir/Config/$config.xcconfig" "$test_root/Config/"
done
/bin/ln -s "$repo_dir/Packages" "$test_root/Packages"

for mode in local unsigned; do
    expected_team=""
    if [[ "$mode" == local ]]; then
        expected_team=FAKE123456
        print 'DEVELOPMENT_TEAM = FAKE123456
CODE_SIGN_ENTITLEMENTS = Config/LocalMac.entitlements' > "$test_root/Config/Local.xcconfig"
    else
        /bin/rm "$test_root/Config/Local.xcconfig"
    fi
    for configuration in Debug Release; do
        settings="$test_root/$mode-$configuration.txt"
        /usr/bin/xcodebuild \
            -project "$test_root/SnipSnap.xcodeproj" \
            -target SnipSnapTests \
            -configuration "$configuration" \
            -showBuildSettings > "$settings" 2>&1 || {
            /bin/cat "$settings"
            exit 1
        }
        assert_setting DEVELOPMENT_TEAM "$expected_team"
        assert_setting CODE_SIGN_ENTITLEMENTS ""
        assert_setting INFOPLIST_FILE ""
        assert_setting PRODUCT_MODULE_NAME SnipSnapTests
        assert_setting GENERATE_INFOPLIST_FILE YES
        assert_setting INFOPLIST_KEY_CFBundleDisplayName ""
        assert_setting INFOPLIST_KEY_LSApplicationCategoryType ""
        assert_setting ASSETCATALOG_COMPILER_APPICON_NAME ""
    done
done
print "Mac test signing settings checks passed."
