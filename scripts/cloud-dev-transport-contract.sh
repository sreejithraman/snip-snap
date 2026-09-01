#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
preflight_tool="${SNIP_SNAP_SIGNED_LANE_PREFLIGHT:-$script_dir/signed-lane-preflight.sh}"
xcodebuild_tool="${SNIP_SNAP_XCODEBUILD:-xcodebuild}"
xcresulttool_tool="${SNIP_SNAP_XCRESULTTOOL:-}"

if [[ "${SNIP_SNAP_RUN_CLOUD_DEV_TRANSPORT_CONTRACT:-}" != 1 ]]; then
    print -u2 "Cloud Dev transport contract is maintainer-only. Set SNIP_SNAP_RUN_CLOUD_DEV_TRANSPORT_CONTRACT=1 after configuring the signed Cloud Dev lane."
    exit 2
fi

source "$script_dir/derived-data.sh"
snip_snap_claim_derived_data
trap snip_snap_cleanup_derived_data EXIT

"$preflight_tool" cloud \
    --scheme SnipSnap \
    --configuration Debug \
    --destination 'platform=macOS'

result_bundle="$derived_data/CloudDevTransportContract.xcresult"
result_summary="$derived_data/CloudDevTransportContract.json"
"$xcodebuild_tool" \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme SnipSnap \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_bundle" \
    CODE_SIGNING_ALLOWED=YES \
    SNIP_SNAP_CLOUD_DEV_TRANSPORT_CONTRACT_ENABLED=YES \
    -only-testing:SnipSnapTests/CloudDevTransportContractTests \
    test

if [[ -n "$xcresulttool_tool" ]]; then
    "$xcresulttool_tool" "$result_bundle" > "$result_summary"
else
    xcrun xcresulttool get test-results summary \
        --path "$result_bundle" --format json > "$result_summary"
fi
[[ "$(/usr/bin/plutil -extract totalTestCount raw "$result_summary")" == 1 \
    && "$(/usr/bin/plutil -extract passedTests raw "$result_summary")" == 1 \
    && "$(/usr/bin/plutil -extract failedTests raw "$result_summary")" == 0 \
    && "$(/usr/bin/plutil -extract skippedTests raw "$result_summary")" == 0 ]] || {
    print -u2 "Cloud Dev transport contract did not run one passing, non-skipped test."
    exit 1
}

print "Signed Cloud Dev fake-versus-real transport contract passed."
