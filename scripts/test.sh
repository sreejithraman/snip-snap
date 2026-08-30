#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
derived_data="${SNIP_SNAP_DERIVED_DATA:-/tmp/snip-snap-derived-data}"

"$script_dir/release-policy-tests.sh"
"$script_dir/signing-policy-tests.sh"
"$script_dir/tracked-input-policy-tests.sh"
"$script_dir/tracked-input-policy.sh"
"$script_dir/showroom-delivery-tests.sh"
"$script_dir/dev-slot-tests.sh"
"$script_dir/build-tests.sh"
"$script_dir/build-matrix-tests.sh"
"$script_dir/release-matrix-tests-tests.sh"
"$script_dir/ios-target-policy-tests.sh"

swift test --package-path "$repo_dir/Packages/SnipSnapLibrary"

xcodebuild \
    -project "$repo_dir/SnipSnap.xcodeproj" \
    -scheme SnipSnap \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    test
