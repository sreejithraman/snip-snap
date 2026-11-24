#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
lane="${1:-}"
configuration=""
destination="generic/platform=macOS"
scheme="SnipSnap"

source "$script_dir/signing-policy.sh"

usage() {
    print -u2 "Usage: $0 cloud|device|testflight|release [--scheme NAME] [--configuration NAME] [--destination DESTINATION]"
}

[[ -n "$lane" ]] || { usage; exit 2; }
shift
while (( $# )); do
    case "$1" in
        --configuration)
            (( $# >= 2 )) || { usage; exit 2; }
            configuration="$2"
            shift 2
            ;;
        --scheme)
            (( $# >= 2 )) || { usage; exit 2; }
            scheme="$2"
            shift 2
            ;;
        --destination)
            (( $# >= 2 )) || { usage; exit 2; }
            destination="$2"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

case "$lane" in
    cloud|device)
        configuration="${configuration:-Debug}"
        ;;
    testflight|release)
        configuration="${configuration:-Release}"
        ;;
    *)
        usage
        exit 2
        ;;
esac

temp_root="$(/usr/bin/mktemp -d /private/tmp/snip-snap-signing.XXXXXX)"
cleanup() {
    [[ "$temp_root" != /private/tmp/snip-snap-signing.* ]] || /bin/rm -rf "$temp_root"
}
trap cleanup EXIT

settings_file="$temp_root/build-settings.txt"
signing_policy_capture_build_settings \
    "$repo_dir" "$configuration" "$destination" "$settings_file" \
    "$temp_root/DerivedData" "$scheme"

signing_policy_preflight "$lane" "$settings_file" "$repo_dir" "$scheme"
