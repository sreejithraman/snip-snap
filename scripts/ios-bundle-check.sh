#!/bin/zsh

snip_snap_check_ios_bundle() {
    local app_path="$1"
    local build_marker="${2:-}"
    local app_executable="$app_path/Snip Snap iOS"
    local extension_path="$app_path/PlugIns/SnipSnapShareExtension.appex"
    local extension_executable="$extension_path/SnipSnapShareExtension"
    [[ -d "$extension_path" ]] || {
        print -u2 "iOS bundle check: the app is missing its embedded Share extension: $extension_path"
        return 1
    }
    [[ -f "$app_executable" && -f "$extension_path/Info.plist" && \
       -f "$extension_executable" ]] || {
        print -u2 "iOS bundle check: the app does not contain a built Share extension bundle: $extension_path"
        return 1
    }
    [[ -f "$app_path/PrivacyInfo.xcprivacy" && \
       -f "$extension_path/PrivacyInfo.xcprivacy" ]] || {
        print -u2 "iOS bundle check: the app or Share extension is missing its privacy manifest."
        return 1
    }
    if [[ -n "$build_marker" ]]; then
        [[ -f "$build_marker" && "$app_executable" -nt "$build_marker" && \
           "$extension_executable" -nt "$build_marker" ]] || {
            print -u2 "iOS bundle check: the app or Share extension was not built in this matrix run."
            return 1
        }
    fi
}
