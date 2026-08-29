#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
project_file="$repo_dir/SnipSnap.xcodeproj/project.pbxproj"
ios_source_dir="$repo_dir/SnipSnapiOS"
share_source_dir="$repo_dir/SnipSnapShareExtension"
shared_settings="$repo_dir/Config/Shared.xcconfig"
ios_settings="$repo_dir/Config/iOSShared.xcconfig"
ios_entitlements="$ios_source_dir/SnipSnapiOS.entitlements"
ios_info="$ios_source_dir/Info.plist"
share_entitlements="$share_source_dir/SnipSnapShareExtension.entitlements"

for required_file in \
    SnipSnapiOSApp.swift \
    IOSAppModel.swift \
    IOSAppRootView.swift \
    LibraryViews.swift \
    WorkflowControls.swift \
    EditorViews.swift \
    AttachmentViews.swift \
    SnipSnapiOS.entitlements; do
    grep -F -- "$required_file" "$project_file" >/dev/null
done

ios_group="$({
    awk '
        /^[[:space:]]*E70000000000000000000001 \/\* SnipSnapiOS \*\/ = \{/ { capture = 1 }
        capture { print }
        capture && /sourceTree = "<group>"/ { exit }
    ' "$project_file"
})"
[[ "$ios_group" == *"SnipSnapiOS.entitlements"* ]]
[[ "$ios_group" == *"Info.plist"* ]]

share_group="$({
    awk '
        /^[[:space:]]*F70000000000000000000001 \/\* SnipSnapShareExtension \*\/ = \{/ { capture = 1 }
        capture { print }
        capture && /sourceTree = "<group>"/ { exit }
    ' "$project_file"
})"
for required_file in \
    ShareViewController.swift \
    ShareExtensionModel.swift \
    ShareExtensionInputLoader.swift \
    ShareExtensionView.swift \
    SnipSnapShareExtension.entitlements \
    Info.plist; do
    [[ "$share_group" == *"$required_file"* ]]
done

for required_file in \
    ShareViewController.swift \
    ShareExtensionModel.swift \
    ShareExtensionInputLoader.swift \
    ShareExtensionView.swift \
    SnipSnapShareExtension.entitlements \
    Info.plist; do
    grep -F -- "$required_file" "$project_file" >/dev/null
done

if /usr/bin/grep -En \
    '(^|[^A-Za-z])(import AppKit|import CloudKit|NSPasteboard|SelectionCapture|GlobalHotKey|ClipboardHistory|SnipSnapPanel)' \
    "$ios_source_dir"/*.swift; then
    print -u2 "The iOS source tree includes a forbidden Mac or cloud dependency."
    exit 1
fi

if /usr/bin/grep -En \
    '(^|[^A-Za-z])(import AppKit|import CloudKit|SnipSnapCloud|SwiftDataSnipLibrary|ModelContainer|UIApplication\.shared|openURL|NSExtensionContext\.open)' \
    "$share_source_dir"/*.swift; then
    print -u2 "The Share extension source tree includes a forbidden app, store, or cloud dependency."
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

share_target="$({
    awk '
        /^[[:space:]]*F50000000000000000000001 \/\* SnipSnapShareExtension \*\/ = \{/ { capture = 1 }
        capture { print }
        capture && /productType = "com.apple.product-type.app-extension"/ { exit }
    ' "$project_file"
})"
[[ "$share_target" == *"SnipSnapCore"* ]]
[[ "$share_target" == *"SnipSnapPersistence"* ]]
[[ "$share_target" != *"SnipSnapCloud"* ]]
[[ "$share_target" != *"Sparkle"* ]]

share_sources="$({
    awk '
        /^[[:space:]]*F90000000000000000000001 \/\* Sources \*\/ = \{/ { capture = 1 }
        capture { print }
        capture && /runOnlyForDeploymentPostprocessing = 0/ { exit }
    ' "$project_file"
})"
for required_file in \
    ShareViewController.swift \
    ShareExtensionModel.swift \
    ShareExtensionInputLoader.swift \
    ShareExtensionView.swift; do
    [[ "$share_sources" == *"$required_file"* ]]
done

embed_phase="$({
    awk '
        /^[[:space:]]*F40000000000000000000001 \/\* Embed App Extensions \*\/ = \{/ { capture = 1 }
        capture { print }
        capture && /runOnlyForDeploymentPostprocessing = 0/ { exit }
    ' "$project_file"
})"
[[ "$embed_phase" == *"SnipSnapShareExtension.appex"* ]]
[[ "$ios_target" == *"Embed App Extensions"* ]]
grep -F -- 'target = F50000000000000000000001 /* SnipSnapShareExtension */;' \
    "$project_file" >/dev/null

[[ "$(/usr/bin/sed -nE \
    's/^[[:space:]]*SNIP_SNAP_APP_GROUP_IDENTIFIER = (.*)$/\1/p' \
    "$shared_settings")" == group.org.example.snipsnap ]]
grep -F -- 'CODE_SIGN_ENTITLEMENTS = SnipSnapiOS/SnipSnapiOS.entitlements' \
    "$ios_settings" >/dev/null
grep -F -- 'INFOPLIST_FILE = SnipSnapiOS/Info.plist' "$ios_settings" >/dev/null
[[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.application-groups'.0 raw -o - \
    "$ios_entitlements")" == '$(SNIP_SNAP_APP_GROUP_IDENTIFIER)' ]]
[[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.application-groups'.0 raw -o - \
    "$share_entitlements")" == '$(SNIP_SNAP_APP_GROUP_IDENTIFIER)' ]]
[[ "$(/usr/bin/plutil -extract SnipSnapAppGroupIdentifier raw -o - \
    "$ios_info")" == '$(SNIP_SNAP_APP_GROUP_IDENTIFIER)' ]]
[[ "$(/usr/bin/plutil -extract SnipSnapAppGroupIdentifier raw -o - \
    "$share_source_dir/Info.plist")" == '$(SNIP_SNAP_APP_GROUP_IDENTIFIER)' ]]

print "iOS target policy checks passed."
