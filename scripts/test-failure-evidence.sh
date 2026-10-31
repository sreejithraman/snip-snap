#!/bin/zsh

snip_snap_preserve_test_failure() {
    local test_derived_data="$1" group="$2"
    local evidence_root="$repo_dir/artifacts/test-failures"
    local evidence_dir result result_size copied_bytes=0 result_count=0
    local max_bundle_bytes=209715200
    /bin/mkdir -p "$evidence_root" || return 1
    evidence_dir="$(/usr/bin/mktemp -d "$evidence_root/$group.XXXXXX")" || return 1

    for result in "$test_derived_data/Logs/Test/"*.xcresult(N); do
        if (( result_count == 10 )); then
            print -r -- 'Additional result bundles omitted after the ten-result limit.' \
                >> "$evidence_dir/omitted-bundles.txt"
            break
        fi
        result_count=$(( result_count + 1 ))
        local result_name="${result:t}"
        local summary="$evidence_dir/$result_name-summary.json"
        # Keep readable details even when a result bundle exceeds the copy budget.
        xcrun xcresulttool get test-results summary --path "$result" \
            | /usr/bin/head -c 1048576 > "$summary" || true
        /bin/cat "$summary"
        xcrun xcresulttool get test-results tests --path "$result" \
            | /usr/bin/head -c 1048576 > "$evidence_dir/$result_name-tests.json" || true
        result_size="$(/usr/bin/ruby -rfind -e \
            'total = 0; Find.find(ARGV.fetch(0)) { |path| total += File.lstat(path).size }; puts total' \
            "$result")" || continue
        if (( result_size <= max_bundle_bytes - copied_bytes )); then
            if /bin/cp -R "$result" "$evidence_dir/$result_name"; then
                copied_bytes=$(( copied_bytes + result_size ))
            else
                /bin/rm -rf "$evidence_dir/$result_name"
                print -u2 "Could not copy test result bundle: $result_name"
            fi
        else
            print -r -- "$result_name exceeded the 200 MiB result-bundle budget; retained JSON details." \
                >> "$evidence_dir/omitted-bundles.txt"
        fi
    done
    print -r -- "Test failure evidence: $evidence_dir"
}
