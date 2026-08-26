#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"

case "${1:-}" in
    describe|device-start|device-verify)
        exec "$script_dir/showroom-delivery.sh" "$@"
        ;;
esac

exec "$script_dir/dev-app.sh" start "$@"
