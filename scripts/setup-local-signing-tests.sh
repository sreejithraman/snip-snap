#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
test_root="$(mktemp -d)"
trap '/bin/rm -rf "$test_root"' EXIT
primary="$test_root/main checkout"
worktree="$test_root/worktree"
files=(Local.xcconfig Local.entitlements LocalMac.entitlements LocalIOS.entitlements MacRelease.entitlements TestFlight.entitlements)
mkdir -p "$primary/scripts" "$primary/Config"
cp "$script_dir/setup-local-signing.sh" "$primary/scripts/"
git -C "$primary" init -q
for name in "${files[@]}"; do print "/Config/$name" >> "$primary/.gitignore"; done
print 'placeholder' > "$primary/Config/tracked.example"
git -C "$primary" add .
git -C "$primary" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
git -C "$primary" worktree add -q --detach "$worktree"
run_setup() { "$worktree/scripts/setup-local-signing.sh" >/dev/null; }
reject_setup() {
    if run_setup 2>/dev/null; then print -u2 'accepted unsafe setup'; exit 1; fi
}
# Missing maintainer settings must not block contributors.
run_setup
[[ ! -e "$worktree/Config/Local.xcconfig" ]]
for name in "${files[@]}"; do print "test $name" > "$primary/Config/$name"; done
# A late conflict must prevent all copies.
print conflicting > "$worktree/Config/TestFlight.entitlements"
reject_setup
[[ ! -e "$worktree/Config/Local.xcconfig" ]]
rm "$worktree/Config/TestFlight.entitlements"
run_setup
run_setup
"$primary/scripts/setup-local-signing.sh" >/dev/null
for name in "${files[@]}"; do
    [[ -f "$worktree/Config/$name" && ! -L "$worktree/Config/$name" ]]
    cmp -s "$primary/Config/$name" "$worktree/Config/$name"
done
[[ -z "$(git -C "$worktree" ls-files --others --exclude-standard Config)" ]]
# Worktree edits never change the main copy, and reruns preserve those edits.
print edited > "$worktree/Config/Local.xcconfig"
reject_setup
[[ "$(cat "$primary/Config/Local.xcconfig")" == 'test Local.xcconfig' ]]
[[ "$(cat "$worktree/Config/Local.xcconfig")" == edited ]]
rm "$worktree/Config/Local.xcconfig"
# Reject even dangling destination links.
ln -s "$test_root/missing" "$worktree/Config/Local.xcconfig"
reject_setup
rm "$worktree/Config/Local.xcconfig"
# Ignored-but-tracked sources and destinations are not safe.
git -C "$primary" add -f Config/Local.xcconfig
reject_setup
git -C "$primary" rm --cached -q Config/Local.xcconfig
run_setup
git -C "$worktree" add -f Config/Local.xcconfig
reject_setup
git -C "$worktree" rm --cached -q Config/Local.xcconfig
# Never follow source symlinks, including links outside the repo.
mv "$primary/Config/Local.xcconfig" "$test_root/private.xcconfig"
ln -s "$test_root/private.xcconfig" "$primary/Config/Local.xcconfig"
reject_setup
rm "$primary/Config/Local.xcconfig"
ln -s "$test_root/missing" "$primary/Config/Local.xcconfig"
reject_setup
print 'Local signing setup tests passed.'
