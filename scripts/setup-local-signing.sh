#!/bin/zsh
set -euo pipefail
umask 077

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"

fail() {
    print -u2 "local signing: $1"
    exit 1
}
(( $# == 0 )) || { print -u2 "Usage: $0"; exit 2; }

# Git lists the primary checkout first. NUL records preserve spaces in its path.
IFS= read -r -d '' primary_record < <(git -C "$repo_dir" worktree list --porcelain -z)
[[ "$primary_record" == 'worktree '* ]] || fail "could not find the primary checkout"
primary_dir="${primary_record#worktree }"
[[ -d "$primary_dir/Config" && ! -L "$primary_dir/Config" ]] || \
    fail "the primary checkout needs a real Config directory"
[[ -d "$repo_dir/Config" && ! -L "$repo_dir/Config" ]] || \
    fail "this checkout needs a real Config directory"

if [[ ! -e "$primary_dir/Config/Local.xcconfig" && ! -L "$primary_dir/Config/Local.xcconfig" ]]; then
    print "No local signing settings in the primary checkout; leaving this worktree unchanged."
    exit 0
fi

files=(Local.xcconfig Local.entitlements LocalMac.entitlements LocalIOS.entitlements MacRelease.entitlements TestFlight.entitlements)
pending=()
# Check all sources and destinations before copying. Never replace local files.
for name in "${files[@]}"; do
    source_file="$primary_dir/Config/$name"
    [[ -e "$source_file" || -L "$source_file" ]] || continue
    [[ -f "$source_file" && ! -L "$source_file" ]] || fail "Config/$name in the primary checkout must be a regular file"
    git -C "$primary_dir" check-ignore -q "Config/$name" || \
        fail "Config/$name in the primary checkout must be ignored and untracked"
    git -C "$repo_dir" check-ignore -q "Config/$name" || \
        fail "Config/$name in this checkout must be ignored and untracked"
    target="$repo_dir/Config/$name"
    [[ ! -L "$target" ]] || fail "Config/$name is a symlink; move it aside before copying"
    if [[ -e "$target" ]]; then
        [[ -f "$target" ]] && /usr/bin/cmp -s "$source_file" "$target" || \
            fail "Config/$name differs; keep your edits or move it aside before copying"
        continue
    fi
    pending+=("$name")
done
for name in "${pending[@]}"; do
    /bin/cp -n "$primary_dir/Config/$name" "$repo_dir/Config/$name"
done
print "Local signing settings copied from the primary checkout."
