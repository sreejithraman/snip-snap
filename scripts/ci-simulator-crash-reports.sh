#!/bin/zsh
# Lists SimLaunchHost crash reports on a CI runner, for the iOS job's summary, and keeps copies for upload.
# Hosted runners have crashed SimLaunchHost with SIGBUS mid-run, taking the Simulator down; this only records
# when and where, so a later change can tell whether an early crash predicts the fatal one.
# Logging only: it always exits 0.
set -uo pipefail

stage="${1:?Usage: $0 STAGE}"
repo_dir="${0:A:h:h}"
copy_dir="$repo_dir/artifacts/simulator-crash-reports"
report_dirs=(${(s.:.)${SNIP_SNAP_CRASH_REPORT_DIRS:-$HOME/Library/Logs/DiagnosticReports:/Library/Logs/DiagnosticReports}})

reports=()
for dir in "${report_dirs[@]}"; do
    reports+=("$dir"/**/SimLaunchHost*.ips(N))
done

{
    print -r -- "### SimLaunchHost crash reports ($stage)"
    if (( ${#reports} == 0 )); then
        print -r -- 'none'
    else
        /usr/bin/ruby -rjson -e '
          ARGV.each do |path|
            header, body = File.read(path).split("\n", 2)
            meta = JSON.parse(header) rescue {}
            report = JSON.parse(body.to_s) rescue {}
            report = {} unless report.is_a?(Hash)
            meta = {} unless meta.is_a?(Hash)
            exception = report["exception"].is_a?(Hash) ? report["exception"] : {}
            images = Array(report["usedImages"])
            thread = Array(report["threads"]).find { |t| t.is_a?(Hash) && t["triggered"] } || {}
            frame = Array(thread["frames"]).first || {}
            index = frame["imageIndex"]
            image = index.is_a?(Integer) && index >= 0 ? (images[index] || {}) : {}
            symbol = [File.basename(image["path"].to_s), frame["symbol"]].reject { |part| part.to_s.empty? }.join(" ")
            kind = [exception["type"], exception["signal"], exception["subtype"]].compact.join(" ")
            puts "- `#{File.basename(path)}`: #{meta["timestamp"] || "unknown time"}, " \
                 "#{kind.empty? ? "unknown exception" : kind}; " \
                 "faulting frame: #{symbol.empty? ? "unknown" : symbol}"
          rescue StandardError => error
            puts "- `#{File.basename(path)}`: unreadable (#{error.class})"
          end
        ' "${reports[@]}" || print -r -- "- ${#reports} report(s); could not summarize them"
    fi
} | /usr/bin/tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" || true

if (( ${#reports} > 0 )); then
    /bin/mkdir -p "$copy_dir" && /bin/cp -p "${reports[@]}" "$copy_dir/" || true
fi
exit 0
