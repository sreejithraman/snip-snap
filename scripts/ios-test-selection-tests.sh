#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
test_dir="$(mktemp -d)"
trap '/bin/rm -rf "$test_dir"' EXIT

# Listing and invalid selections must work without Xcode or a booted device.
mkdir -p "$test_dir/bin"
cat > "$test_dir/bin/xcrun" <<'STUB'
#!/bin/zsh
print -u2 'Selection validation reached simulator discovery'
exit 99
STUB
chmod +x "$test_dir/bin/xcrun"
export PATH="$test_dir/bin:$PATH"
"$script_dir/run.sh" --ios-simulator --list-ui-groups > "$test_dir/groups"
grep -F 'smoke' "$test_dir/groups" >/dev/null

/usr/bin/ruby "$script_dir/ios-test-selection.rb" --ui-group smoke > "$test_dir/selection"
grep -Fx 'testCreatesAndEditsTextSnip' "$test_dir/selection" >/dev/null
grep -Fx 'testSelectionPersistsAcrossLists' "$test_dir/selection" >/dev/null
[[ "$(sort -u "$test_dir/selection" | wc -l | tr -d ' ')" == "$(wc -l < "$test_dir/selection" | tr -d ' ')" ]]
/usr/bin/ruby "$script_dir/ios-test-selection.rb" --ui-test testCopiesTextOnlySnip > "$test_dir/selection"
[[ "$(cat "$test_dir/selection")" == testCopiesTextOnlySnip ]]
/usr/bin/ruby "$script_dir/ios-test-selection.rb" --ui-test all > "$test_dir/selection"
[[ "$(cat "$test_dir/selection")" == all ]]
# Select both direct XCTestCase classes and subclasses of the shared model fixture.
/usr/bin/ruby "$script_dir/ios-test-selection.rb" --unit-test IOSHapticFeedbackTests > "$test_dir/selection"
[[ "$(cat "$test_dir/selection")" == IOSHapticFeedbackTests ]]
/usr/bin/ruby "$script_dir/ios-test-selection.rb" --unit-test IOSSnipCopyTests > "$test_dir/selection"
[[ "$(cat "$test_dir/selection")" == IOSSnipCopyTests ]]

for arguments in \
 '--ui-group unknown' \
 '--ui-test testMisspelledMethod' \
 '--unit-test MisspelledTestClass' \
 '--ui-group smoke --ui-test testCopiesTextOnlySnip' \
 '--ui-group smoke --unit-test IOSAppModelTests' \
 '--ui-test testCopiesTextOnlySnip --ui-test testCreatesAndEditsTextSnip' \
 '--unit-test IOSAppModelTests --unit-test IOSCopyShareTests' \
 '--ui-group smoke --ui-group lists' \
 '--list-ui-groups --ui-test all'; do
 if "$script_dir/run.sh" --ios-simulator ${=arguments} > "$test_dir/output" 2>&1; then
  print -u2 "Accepted invalid selection: $arguments"; exit 1
 fi
 if grep -F 'Selection validation reached simulator discovery' "$test_dir/output" >/dev/null; then
  cat "$test_dir/output" >&2; exit 1
 fi
done

# A renamed/removed method must break its group instead of silently reducing coverage.
mkdir -p "$test_dir/repo/scripts" "$test_dir/repo/SnipSnapiOSUITests"
cp "$script_dir/ios-test-selection.rb" "$test_dir/repo/scripts/"
sed 's/func testCreatesAndEditsTextSnip(/func testRenamedEditingWorkflow(/' \
 "$script_dir/../SnipSnapiOSUITests/SnipSnapiOSUITests.swift" \
 > "$test_dir/repo/SnipSnapiOSUITests/SnipSnapiOSUITests.swift"
if /usr/bin/ruby "$test_dir/repo/scripts/ios-test-selection.rb" --ui-group smoke > "$test_dir/output" 2>&1; then
 print -u2 'A group silently accepted a missing workflow'; exit 1
fi
grep -F 'testCreatesAndEditsTextSnip' "$test_dir/output" >/dev/null
print 'iOS test selection checks passed.'
