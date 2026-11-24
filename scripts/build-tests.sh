#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
unset SNIP_SNAP_DEV_SLOT
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/bin"
print -r -- '#!/bin/zsh
print -r -- "$@" >> "$SNIP_SNAP_BUILD_ARGS_FILE"' > "$test_dir/bin/xcodebuild"
chmod +x "$test_dir/bin/xcodebuild"

output="$(
    PATH="$test_dir/bin:$PATH" \
        SNIP_SNAP_BUILD_ARGS_FILE="$test_dir/build-args" \
        SNIP_SNAP_DERIVED_DATA="$test_dir/derived-data" \
        "$script_dir/build.sh"
)"

ios_build="$(/usr/bin/grep -F -- "-scheme SnipSnapiOS " "$test_dir/build-args")"
[[ "$ios_build" == *" -configuration Release "* && \
   "$ios_build" == *" -destination generic/platform=iOS Simulator "* && \
   "$ios_build" == *" CODE_SIGNING_ALLOWED=NO "* ]] || {
    print -u2 "The iOS compile check was not an unsigned Release Simulator build."
    exit 1
}
mac_build="$({
    /usr/bin/awk '
        /-scheme SnipSnap / && /-destination platform=macOS/ { print; exit }
    ' "$test_dir/build-args"
})"
[[ "$mac_build" == *"-configuration Release"* && "$mac_build" == *" CODE_SIGNING_ALLOWED=NO "* ]] || {
    print -u2 "The Mac compile check was not an unsigned Release build."
    exit 1
}
grep -F -- 'PRODUCT_BUNDLE_IDENTIFIER=$(SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER).compilecheck' \
    "$test_dir/build-args" >/dev/null
grep -E -- '(^|[[:space:]])SNIP_SNAP_PRODUCT_NAME=SnipSnapCompileCheck([[:space:]]|$)' \
    "$test_dir/build-args" >/dev/null
if grep -E -- '(^|[[:space:]])PRODUCT_NAME=SnipSnapCompileCheck([[:space:]]|$)' \
    "$test_dir/build-args" >/dev/null; then
    print -u2 "A compile check overrode PRODUCT_NAME for every target."
    exit 1
fi
grep -F -- "INFOPLIST_KEY_CFBundleDisplayName=Snip Snap Compile Check" \
    "$test_dir/build-args" >/dev/null
[[ "$output" == *"Do not launch this build."* ]]
[[ "$output" == *"Use scripts/run.sh"* ]]

: > "$test_dir/build-args"
unset SNIP_SNAP_DERIVED_DATA
PATH="$test_dir/bin:$PATH" \
    SNIP_SNAP_BUILD_ARGS_FILE="$test_dir/build-args" \
    "$script_dir/build.sh" >/dev/null
default_derived_data="$(
    /usr/bin/awk '{
        for (i = 1; i <= NF; i += 1) {
            if ($i == "-derivedDataPath") { print $(i + 1); exit }
        }
    }' "$test_dir/build-args"
)"
[[ "$default_derived_data" == /private/tmp/snip-snap-derived-data.* ]]
[[ ! -e "$default_derived_data" ]]

SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=org.example.environment \
    PATH="$test_dir/bin:$PATH" \
    SNIP_SNAP_BUILD_ARGS_FILE="$test_dir/build-args" \
    SNIP_SNAP_DERIVED_DATA="$test_dir/derived-data" \
    "$script_dir/build.sh" >/dev/null
grep -F -- "SNIP_SNAP_PRODUCT_BUNDLE_IDENTIFIER=org.example.environment" \
    "$test_dir/build-args" >/dev/null

print -r -- '#!/bin/zsh
exit 1' > "$test_dir/bin/xcodebuild"
if failure_output="$(
    PATH="$test_dir/bin:$PATH" \
        SNIP_SNAP_DERIVED_DATA="$test_dir/failed-derived-data" \
        "$script_dir/build.sh" 2>&1
)"; then
    print -u2 "A failed compile check reported success."
    exit 1
fi
[[ "$failure_output" != *"Compile checks passed."* ]]

print "Build script checks passed."
