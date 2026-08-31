#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
catalog="$repo_dir/Shared/Localizable.xcstrings"
project_file="$repo_dir/SnipSnap.xcodeproj/project.pbxproj"
policy_dir="$(mktemp -d)"
trap 'rm -rf "$policy_dir"' EXIT

[[ "$(/usr/bin/plutil -extract version raw "$catalog")" == "1.1" ]] || {
    print -u2 "Localizable.xcstrings must use the Xcode 26 format for generated symbols."
    exit 1
}

/usr/bin/grep -Fq 'STRING_CATALOG_GENERATE_SYMBOLS = YES' \
    "$repo_dir/Config/Shared.xcconfig" || {
    print -u2 "Shipping targets must generate typed string-catalog symbols."
    exit 1
}

xcrun xcstringstool print "$catalog" | /usr/bin/sort -u > "$policy_dir/catalog-keys"

/usr/bin/find \
    "$repo_dir/Shared" \
    "$repo_dir/SnipSnap" \
    "$repo_dir/SnipSnapiOS" \
    "$repo_dir/SnipSnapShareExtension" \
    "$repo_dir/Packages/SnipSnapLibrary/Sources" \
    -name '*.swift' -print0 \
    | /usr/bin/xargs -0 /usr/bin/perl -0777 -ne '
        while (/String\(\s*localized:\s*"((?:[^"\\]|\\.)*)"/g) {
            print "$1\n" unless $1 =~ /\\\(/;
        }
    ' \
    | /usr/bin/sort -u > "$policy_dir/required-literal-keys"

if missing_keys="$(/usr/bin/comm -23 \
    "$policy_dir/required-literal-keys" "$policy_dir/catalog-keys")" \
    && [[ -n "$missing_keys" ]]; then
    print -u2 "String(localized:) keys are missing from Localizable.xcstrings:"
    print -u2 -- "$missing_keys"
    exit 1
fi

for phase_id in \
    A00000000000000000000001 \
    EA0000000000000000000001 \
    FA0000000000000000000001; do
    phase="$({
        /usr/bin/awk -v phase_id="$phase_id" '
            $1 == phase_id { capture = 1 }
            capture { print }
            capture && /runOnlyForDeploymentPostprocessing = 0/ { exit }
        ' "$project_file"
    })"
    [[ "$phase" == *"Localizable.xcstrings"* ]] || {
        print -u2 "A shipping target does not include Localizable.xcstrings: $phase_id"
        exit 1
    }
done

/usr/bin/sed -n \
    '/static let categories = \[/,/static let searchKeywords:/p' \
    "$repo_dir/SnipSnap/SnipListIconCatalog.swift" \
    | /usr/bin/grep -Eo '"[a-z0-9][a-z0-9.]*"' \
    | /usr/bin/tr -d '"' \
    | /usr/bin/sed 's/^/icon./' \
    | /usr/bin/sort -u > "$policy_dir/required-icon-keys"

if missing_icons="$(/usr/bin/comm -23 \
    "$policy_dir/required-icon-keys" "$policy_dir/catalog-keys")" \
    && [[ -n "$missing_icons" ]]; then
    print -u2 "List icons are missing from Localizable.xcstrings:"
    print -u2 -- "$missing_icons"
    exit 1
fi

if /usr/bin/grep -REn \
    '(presentedError|errorMessage|clearDownloadsError|panel\.title|panel\.prompt|window\?*\.title|toolTip)[[:space:]]*=[[:space:]]*"|hud\.show\(message:[[:space:]]*"|AppToast\([^\n]*message:[[:space:]]*"' \
    "$repo_dir/Shared" \
    "$repo_dir/SnipSnap" \
    "$repo_dir/SnipSnapiOS" \
    "$repo_dir/SnipSnapShareExtension"; then
    print -u2 "A plain user-facing string bypasses Localizable.xcstrings."
    exit 1
fi

localized_error_files=(${(f)"$(/usr/bin/grep -Rl --include='*.swift' \
    'LocalizedError' "$repo_dir/Packages/SnipSnapLibrary/Sources")"})
if (( ${#localized_error_files} > 0 )) && /usr/bin/grep -En \
    '^[[:space:]]+"[^"[:space:]][^"]*[[:alpha:]][^"]*"[[:space:]]*$' \
    "${localized_error_files[@]}"; then
    print -u2 "A library error string bypasses Localizable.xcstrings."
    exit 1
fi

print "Localization policy checks passed."
