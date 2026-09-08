#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"

case "${1:-}" in
    --ios-simulator)
        shift
        exec "$script_dir/dev-ios-simulator.sh" "$@"
        ;;
    ios-device)
        shift
        exec "$script_dir/run-ios-device.sh" "$@"
        ;;
    ios-simulator)
        shift
        exec "$script_dir/run-ios-simulator.sh" "$@"
        ;;
    describe|device-start|device-verify)
        exec "$script_dir/showroom-delivery.sh" "$@"
        ;;
esac

exec "$script_dir/dev-app.sh" start "$@"
