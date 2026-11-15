#!/bin/zsh
# Checks ci-simulator-crash-reports.sh against fixture reports: it summarizes, copies, and never fails.
set -euo pipefail

script_dir="${0:A:h}"
work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/snip-snap-crash-report-tests.XXXXXX")"
trap '/bin/rm -rf "$work"' EXIT
/bin/mkdir -p "$work/repo/scripts" "$work/reports" "$work/empty"
/bin/cp "$script_dir/ci-simulator-crash-reports.sh" "$work/repo/scripts/"
lister="$work/repo/scripts/ci-simulator-crash-reports.sh"

fail() {
    print -u2 "ci-simulator-crash-reports-tests: $*"
    exit 1
}

SNIP_SNAP_CRASH_REPORT_DIRS="$work/empty:$work/missing" GITHUB_STEP_SUMMARY="$work/summary-none" \
    "$lister" after-boot > "$work/out-none" || fail "an empty runner must not fail"
/usr/bin/grep -Fx 'none' "$work/summary-none" >/dev/null || fail "an empty runner must report none"
[[ ! -e "$work/repo/artifacts" ]] || fail "an empty runner must copy nothing"

print -r -- '{"timestamp":"2026-11-15 20:58:53.00 +0000","bug_type":"309"}
{"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGBUS","subtype":"KERN_MEMORY_ERROR at 0x1031a0000"},
 "usedImages":[{"path":"/usr/lib/dyld"}],
 "threads":[{"frames":[{"imageIndex":0,"symbol":"other"}]},
            {"triggered":true,"frames":[{"imageIndex":0,"symbol":"forEachLoadCommand"}]}]}' \
    > "$work/reports/SimLaunchHost.arm64-2026-11-15-205853.ips"
print -r -- 'not json' > "$work/reports/SimLaunchHost.arm64-broken.ips"
print -r -- '{}' > "$work/reports/Other-2026-11-15.ips"

SNIP_SNAP_CRASH_REPORT_DIRS="$work/reports" GITHUB_STEP_SUMMARY="$work/summary" \
    "$lister" after-tests > "$work/out" || fail "reports must not fail the job"
summary="$(<"$work/summary")"
[[ "$summary" == *'### SimLaunchHost crash reports (after-tests)'* ]] || fail "missing the stage heading"
[[ "$summary" == *'2026-11-15 20:58:53.00 +0000, EXC_BAD_ACCESS SIGBUS KERN_MEMORY_ERROR at 0x1031a0000; faulting frame: dyld forEachLoadCommand'* ]] ||
    fail "missing the report's time, exception, or faulting frame: $summary"
[[ "$summary" == *'SimLaunchHost.arm64-broken.ips'* ]] || fail "an unreadable report must still be listed"
[[ "$summary" != *Other-* ]] || fail "only SimLaunchHost reports belong in the summary"
[[ "$(<"$work/out")" == "$summary" ]] || fail "the log and the summary must match"
[[ -f "$work/repo/artifacts/simulator-crash-reports/SimLaunchHost.arm64-2026-11-15-205853.ips" ]] ||
    fail "reports must be copied for upload"
[[ ! -e "$work/repo/artifacts/simulator-crash-reports/Other-2026-11-15.ips" ]] || fail "only SimLaunchHost reports are copied"

/bin/chmod 000 "$work/reports"
SNIP_SNAP_CRASH_REPORT_DIRS="$work/reports" GITHUB_STEP_SUMMARY="$work/unwritable/summary" \
    "$lister" after-tests > /dev/null 2>&1 || fail "unreadable reports and an unwritable summary must not fail the job"
/bin/chmod 755 "$work/reports"

print "Simulator crash report checks passed."
