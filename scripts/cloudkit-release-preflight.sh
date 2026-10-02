#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"

fail() {
    print -u2 "CloudKit preflight: $1"
    exit 1
}

if_enabled=NO
mac_release_zip=""
while (( $# )); do
    case "$1" in
        --if-enabled) if_enabled=YES; shift ;;
        --mac-release-zip)
            (( $# >= 2 )) || fail 'pass the release ZIP after --mac-release-zip'
            mac_release_zip="$2"; shift 2 ;;
        *)
            print -u2 "Usage: $0 [--if-enabled] [--mac-release-zip PATH]"
            exit 2
            ;;
    esac
done
if [[ "$if_enabled" == YES ]]; then
    case "${SNIP_SNAP_CLOUDKIT_PREFLIGHT_ENABLED:-NO}" in
        YES) ;;
        NO|'')
            print 'CloudKit Production preflight disabled (maintainer opt-in).'
            exit 0
            ;;
        *) fail 'SNIP_SNAP_CLOUDKIT_PREFLIGHT_ENABLED must be YES or NO' ;;
    esac
fi

team_id="${SNIP_SNAP_CLOUDKIT_PREFLIGHT_TEAM_ID:-}"
container_id="${SNIP_SNAP_CLOUDKIT_PREFLIGHT_CONTAINER_ID:-}"

# cktool reads its management token from Keychain or ~/.config/cktool.
# Never accept a token in this script's arguments or copy it into a report.
umask 077
report_root="${SNIP_SNAP_CLOUDKIT_PREFLIGHT_REPORT_DIR:-$repo_dir/artifacts/cloudkit-preflight}"
/bin/mkdir -p "$report_root"
report_dir="$(/usr/bin/mktemp -d "$report_root/$(/bin/date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
report="$report_dir/report.txt"
finish() {
    local result=$?
    # Only this run’s extracted app copy is disposable; preserve schema/log evidence.
    /bin/rm -rf "$report_dir/mac-release"
    if (( result == 0 )); then
        print 'PASS: live fields match deployed Production names, types, and encryption.' >> "$report"
    else
        print "FAIL: preflight exited $result; beta publishing must stop." >> "$report"
    fi
    print "CloudKit preflight report: $report"
}
trap finish EXIT

# Bind Mac publication to the exact signed ZIP, without launching its app.
if [[ -n "$mac_release_zip" ]]; then
    [[ -f "$mac_release_zip" ]] || fail 'missing Mac release ZIP'
    /usr/bin/ditto -x -k "$mac_release_zip" "$report_dir/mac-release"
    mac_app="$report_dir/mac-release/Snip Snap.app"
    codesign_tool="${SNIP_SNAP_CODESIGN:-/usr/bin/codesign}"
    "$codesign_tool" --verify --deep --strict "$mac_app" \
        > "$report_dir/signature.log" 2>&1 || fail 'Mac release signature verification failed'
    "$codesign_tool" -d --entitlements :- "$mac_app" \
        > "$report_dir/mac-entitlements.plist" 2>> "$report_dir/signature.log" || \
        fail 'could not read signed Mac entitlements'
    /usr/bin/plutil -convert json -o "$report_dir/mac-entitlements.json" \
        "$report_dir/mac-entitlements.plist"
    target_text="$(/usr/bin/ruby -rjson - "$report_dir/mac-entitlements.json" <<'RUBY'
values = JSON.parse(File.read(ARGV.fetch(0)))
containers = values['com.apple.developer.icloud-container-identifiers']
team = values['com.apple.developer.team-identifier']
unless containers.is_a?(Array) && containers.length == 1 &&
    [team, containers[0]].all? { |value| value.is_a?(String) && !value.empty? && !value.include?("\n") } &&
    values['com.apple.developer.icloud-container-environment'] == 'Production'
  abort 'CloudKit preflight: signed Mac must have one CloudKit container, a team, and Production environment'
end
puts team, containers[0]
RUBY
    )" || fail 'could not resolve signed Mac CloudKit target'
    target_values=( "${(@f)target_text}" )
    [[ -z "$team_id" || "$team_id" == "${target_values[1]}" ]] || \
        fail 'configured preflight team differs from signed Mac release'
    [[ -z "$container_id" || "$container_id" == "${target_values[2]}" ]] || \
        fail 'configured preflight container differs from signed Mac release'
    team_id="${target_values[1]}"
    container_id="${target_values[2]}"
    runtime_container="$(/usr/bin/plutil -extract SnipSnapCloudKitContainerIdentifier raw -o - \
        "$mac_app/Contents/Info.plist" 2>/dev/null)" || \
        fail 'signed Mac release is missing its runtime CloudKit container'
    [[ "$runtime_container" == "$container_id" ]] || \
        fail 'signed Mac runtime CloudKit container differs from its entitlement'
    bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$mac_app/Contents/Info.plist")"
    source "$script_dir/signing-policy.sh"
    signing_policy_verify_production_cloudkit_app \
        "$mac_app" "$container_id" "$team_id" "$bundle_id" \
        > "$report_dir/production-signing.log" 2>&1 || \
        fail 'Mac Production signing/profile verification failed; see production-signing.log'
fi
[[ -n "$team_id" && -n "$container_id" ]] || \
    fail 'set SNIP_SNAP_CLOUDKIT_PREFLIGHT_TEAM_ID and SNIP_SNAP_CLOUDKIT_PREFLIGHT_CONTAINER_ID for the release target'

{
    print "Checked at: $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    print "Commit: $(git -C "$repo_dir" rev-parse HEAD)"
    print "Team: $team_id"
    print "Container: $container_id"
    print 'Environment: production'
    print 'Schema SHA-256:'
    /usr/bin/shasum -a 256 "$repo_dir/CloudKit/SnipSnap.ckdb"
} > "$report"

# This account-free check proves the checked-in baseline still matches live codecs.
if ! swift test --package-path "$repo_dir/Packages/SnipSnapLibrary" \
    --filter CloudKitSchemaContractTests > "$report_dir/codec-tests.log" 2>&1; then
    fail "live codec/schema contract failed; see $report_dir/codec-tests.log"
fi
# Swift exits zero when a filter matches no tests. Require the existing XCTest
# contract's successful test-case result, which is absent for a skip/empty run.
/usr/bin/grep -E 'Test Case .*CloudKitSchemaContractTests.*testCheckedSchemaMatchesEveryRuntimeRecordFieldAndStorageClass.*passed' \
    "$report_dir/codec-tests.log" >/dev/null || \
    fail "live codec/schema contract did not run and pass; see $report_dir/codec-tests.log"
print 'PASS: account-free live codec/schema contract.' >> "$report"

# The sole CloudKit operation is a fresh export from Production. Never import,
# reset, validate a candidate rollout, or deploy any Development changes here.
if ! xcrun cktool export-schema \
    --team-id "$team_id" --container-id "$container_id" \
    --environment production --output-file "$report_dir/Production.ckdb" \
    > "$report_dir/export.log" 2>&1; then
    fail "Production export failed; authenticate cktool with a management token and see $report_dir/export.log"
fi

if /usr/bin/ruby "$script_dir/cloudkit-schema.rb" \
    "$repo_dir/CloudKit/SnipSnap.ckdb" "$report_dir/Production.ckdb" \
    > "$report_dir/comparison.txt" 2>&1; then
    /usr/bin/tee -a "$report" < "$report_dir/comparison.txt"
else
    /usr/bin/tee -a "$report" < "$report_dir/comparison.txt" >&2
    exit 1
fi
