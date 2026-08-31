#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
catalog="$repo_dir/Shared/Localizable.xcstrings"
package_catalogs=(
    "$repo_dir/Packages/SnipSnapLibrary/Sources/SnipSnapCore/Resources/Localizable.xcstrings"
    "$repo_dir/Packages/SnipSnapLibrary/Sources/SnipSnapPersistence/Resources/Localizable.xcstrings"
    "$repo_dir/Packages/SnipSnapLibrary/Sources/SnipSnapCloud/Resources/Localizable.xcstrings"
)
app_source_roots=(
    "$repo_dir/Shared"
    "$repo_dir/SnipSnap"
    "$repo_dir/SnipSnapiOS"
    "$repo_dir/SnipSnapShareExtension"
)
shipping_source_roots=(
    "${app_source_roots[@]}"
    "$repo_dir/Packages/SnipSnapLibrary/Sources"
)
project_file="$repo_dir/SnipSnap.xcodeproj/project.pbxproj"
policy_dir="$(mktemp -d)"
trap 'rm -rf "$policy_dir"' EXIT

catalog_index=0
for checked_catalog in "$catalog" "${package_catalogs[@]}"; do
    [[ "$(/usr/bin/plutil -extract version raw "$checked_catalog")" == "1.1" ]] || {
        print -u2 "$checked_catalog must use the Xcode 26 format for generated symbols."
        exit 1
    }

    symbol_dir="$policy_dir/catalog-$catalog_index-symbols"
    catalog_index=$((catalog_index + 1))
    /bin/mkdir -p "$symbol_dir"
    xcrun xcstringstool generate-symbols \
        "$checked_catalog" \
        --output-directory "$symbol_dir" \
        --language swift

    if [[ "$checked_catalog" != "$catalog" ]]; then
        module_dir="${checked_catalog:h:h}"
        checked_symbols="$module_dir/${module_dir:t}GeneratedStringSymbols.swift"
        if [[ "${module_dir:t}" == SnipSnapCloud ]]; then
            symbol_guard='#if !SNIP_SNAP_SWIFTBUILD && !Xcode'
        else
            symbol_guard='#if !SNIP_SNAP_SWIFTBUILD && (!Xcode || DEBUG)'
        fi
        {
            print "$symbol_guard"
            print
            /bin/cat "$symbol_dir/GeneratedStringSymbols_Localizable.swift"
            print
            print '#endif'
        } > "$symbol_dir/ExpectedGeneratedStringSymbols.swift"
        generated_symbols="$symbol_dir/ExpectedGeneratedStringSymbols.swift"
        /usr/bin/cmp -s "$generated_symbols" "$checked_symbols" || {
            print -u2 "$checked_symbols must match its Xcode-generated catalog symbols."
            exit 1
        }
    fi
done

/usr/bin/grep -Fq 'STRING_CATALOG_GENERATE_SYMBOLS = YES' \
    "$repo_dir/Config/Shared.xcconfig" || {
    print -u2 "Shipping targets must generate typed string-catalog symbols."
    exit 1
}

/usr/bin/grep -Fq 'defaultLocalization: "en"' \
    "$repo_dir/Packages/SnipSnapLibrary/Package.swift" || {
    print -u2 "SnipSnapLibrary must declare its source language."
    exit 1
}

if /usr/bin/grep -REn --include='*.swift' \
    'String\([[:space:]]*localized:[[:space:]]*"' \
    "${shipping_source_roots[@]}"; then
    print -u2 "A literal String(localized:) call bypasses generated catalog symbols."
    exit 1
fi

if /usr/bin/grep -REn --include='*.swift' \
    '(Text|Button|Label|Menu|Picker|Section|Toggle|ProgressView|TextField|LabeledContent|NavigationLink|ContentUnavailableView)\("[^"[:space:]]' \
    "${shipping_source_roots[@]}"; then
    print -u2 "A literal SwiftUI string bypasses generated catalog symbols."
    exit 1
fi

if /usr/bin/grep -REn --include='*.swift' \
    '(Text|Button|Label|Menu|Picker|Section|Toggle|ProgressView|TextField|LabeledContent|NavigationLink|ContentUnavailableView)\([^?[:cntrl:]]*\?[[:space:]]*"' \
    "${app_source_roots[@]}"; then
    print -u2 "A conditional SwiftUI label bypasses generated catalog symbols."
    exit 1
fi

if /usr/bin/grep -REn --include='*.swift' \
    '(\.navigationTitle|\.accessibility(Label|Hint)|\.help|\.alert|\.confirmationDialog|GroupBox|PanelMultilineTextInput|PanelListSectionHeader|listSectionHeader|recoverySnipCard|values)\("[^"[:space:]]|(NSMenuItem|NSButton)\(title:[[:space:]]*"|NSTextField\(labelWithString:[[:space:]]*"' \
    "${shipping_source_roots[@]}"; then
    print -u2 "A literal display string bypasses generated catalog symbols."
    exit 1
fi

if /usr/bin/grep -REn --include='*.swift' \
    '(fileName:[[:space:]]*"|"Selection\.(png|tiff)"|"Pasted Image\.|"Snip Snap Snip\.md")' \
    "${app_source_roots[@]}"; then
    print -u2 "A literal user-visible file name bypasses generated catalog symbols."
    exit 1
fi

if /usr/bin/grep -REn --include='*.swift' \
    'bundle:[[:space:]]*\.main|Bundle\.main' \
    "$repo_dir/Packages/SnipSnapLibrary/Sources"; then
    print -u2 "A package localization bypasses its module resource bundle."
    exit 1
fi

xcrun xcstringstool print "$catalog" | /usr/bin/sort -u > "$policy_dir/catalog-keys"

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
    "${app_source_roots[@]}"; then
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
