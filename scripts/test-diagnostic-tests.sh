#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_root="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$test_root"' EXIT

SNIP_SNAP_DUMMY_SECRET=must-not-appear DEVELOPER_DIR=/tmp/ExampleXcode SDKROOT=/tmp/ExampleSDK \
    "$script_dir/test-diagnostic.sh" /usr/bin/env > "$test_root/environment"
if /usr/bin/grep -F must-not-appear "$test_root/environment"; then
    print -u2 'Diagnostic commands inherited a secret.'
    exit 1
fi
/usr/bin/grep -Fx 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "$test_root/environment" >/dev/null
/usr/bin/grep -Fx 'DEVELOPER_DIR=/tmp/ExampleXcode' "$test_root/environment" >/dev/null
/usr/bin/grep -Fx 'SDKROOT=/tmp/ExampleSDK' "$test_root/environment" >/dev/null
if /usr/bin/grep -Ev '^(PATH|DEVELOPER_DIR|SDKROOT|TMPDIR)=' "$test_root/environment"; then
    print -u2 'Diagnostic commands inherited an unexpected variable.'
    exit 1
fi

if "$script_dir/test-diagnostic.sh" /bin/zsh -c 'exit 37'; then
    print -u2 'Diagnostic commands hid the tool failure.'
    exit 1
else
    [[ $? == 37 ]]
fi
if "$script_dir/test-diagnostic.sh" env; then
    print -u2 'Diagnostic commands accepted a tool from the inherited PATH.'
    exit 1
else
    [[ $? == 2 ]]
fi
print 'Minimal-environment diagnostic checks passed.'
