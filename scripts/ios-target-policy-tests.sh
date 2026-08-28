#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
project_file="$repo_dir/SnipSnap.xcodeproj/project.pbxproj"
ios_source_dir="$repo_dir/SnipSnapiOS"

for required_file in \
    SnipSnapiOSApp.swift \
    IOSAppModel.swift \
    IOSAppRootView.swift \
    LibraryViews.swift \
    EditorViews.swift; do
    grep -F -- "$required_file" "$project_file" >/dev/null
done

if rg -n \
    '(^|[^A-Za-z])(import AppKit|import CloudKit|NSPasteboard|SelectionCapture|GlobalHotKey|ClipboardHistory|SnipSnapPanel)' \
    "$ios_source_dir"; then
    print -u2 "The iOS source tree includes a forbidden Mac or cloud dependency."
    exit 1
fi

ios_target="$({
    awk '
        /^[[:space:]]*E50000000000000000000001 \/\* SnipSnapiOS \*\/ = \{/ { capture = 1 }
        capture { print }
        capture && /productType = "com.apple.product-type.application"/ { exit }
    ' "$project_file"
})"
[[ "$ios_target" == *"SnipSnapCore"* ]]
[[ "$ios_target" == *"SnipSnapPersistence"* ]]
[[ "$ios_target" != *"Sparkle"* ]]

ios_sources="$({
    awk '
        /^[[:space:]]*E90000000000000000000001 \/\* Sources \*\/ = \{/ { capture = 1 }
        capture { print }
        capture && /runOnlyForDeploymentPostprocessing = 0/ { exit }
    ' "$project_file"
})"
for forbidden_file in \
    SelectionCapture.swift \
    GlobalHotKeyManager.swift \
    ClipboardHistory.swift \
    SnipSnapPanel.swift; do
    [[ "$ios_sources" != *"$forbidden_file"* ]]
done

print "iOS target policy checks passed."
