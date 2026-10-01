#!/bin/zsh
set -euo pipefail

action="${1:-}"

if [[ "$action" == describe && "${2:-}" == --json ]]; then
    print -r -- '{
  "protocol_version": 1,
  "surfaces": {
    "device": {
      "start": ["device-start"],
      "verify": ["device-verify"],
      "lifecycle_owner": "manual",
      "required_arguments": []
    }
  }
}'
    exit 0
fi

[[ "$action" == device-start || "$action" == device-verify ]] || {
    print -u2 "Usage: $0 describe --json|device-start|device-verify --result-json PATH"
    exit 2
}

result_json=""
shift
while (( $# )); do
    case "$1" in
        --result-json)
            (( $# >= 2 )) || exit 2
            result_json="$2"
            shift 2
            ;;
        *)
            exit 2
            ;;
    esac
done
[[ -n "$result_json" ]] || exit 2

/usr/bin/ruby -rjson -e '
action, path = ARGV
operation = action == "device-start" ? "start" : "verify"
result = {
  protocol_version: 1,
  surface: "device",
  operation: operation,
  verification: {
    status: "blocked",
    detail: "Run scripts/run.sh cloud-ios-device with the paired iPhone UDID, then verify the workflow on the phone.",
    checks: { "signed device install" => "blocked" }
  },
  location: { command: ["scripts/run.sh", "cloud-ios-device", "<paired-device-udid>"] },
  evidence_paths: [],
  log_paths: [],
  availability_limitations: [
    "Physical verification is manual. The guarded run command needs a paired, connected, unlocked iPhone with Developer Mode and local Development signing settings. Simulator review remains available through Showroom."
  ]
}
File.write(path, JSON.pretty_generate(result))
' "$action" "$result_json"
