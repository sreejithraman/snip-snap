# iOS checks

Choose focused checks for the affected behavior during development, diagnosis,
and handoff. [Build and test](building.md#build-and-test) owns the check cadence.

## Choose a check

| Change | Focused coverage |
| --- | --- |
| Shared records, persistence, or CLI | Affected package tests and platform consumers |
| iOS model, copy/share logic, or gestures | Affected iOS unit classes and UI methods |
| Inline editor or composer | Affected methods or `editing` |
| List creation, appearance, or moves | Affected methods or `lists` |
| Done or delete feedback, Undo, or its deadline | Affected methods or `undo` |
| Gathered selection, merge, or batch actions | Affected methods or `gathering` |
| Attachments or system pickers | Affected methods or `attachments`; satisfy picker fixtures |
| Share sheet or embedded extension | Affected methods or `share`, with the exclusive Share fixture |
| Broad UI changes or a quick sanity check | `smoke`, then affected workflows |
| Test runner or build scripts | Script policy checks and a real run of the affected path |

The groups select explicit workflows, not every test in a feature. Inspect their
methods in `scripts/ios-test-selection.rb` and add related regressions for the
actual change. There is no automatic selection based on changed files.

## Maintain focused coverage

Update UI test methods alongside feature behavior, including setup, selectors,
and assertions. Check user-visible outcomes rather than internal view structure.
When replacing a method, carry its relevant coverage into the replacement.

When adding, renaming, splitting, or removing methods, review the affected
`GROUPS` entries in `scripts/ios-test-selection.rb`. Update relevant membership
and descriptions in the same change, along with documentation examples that
name those methods. Keep `smoke` small and feature groups representative;
exhaustive edge cases can remain individually selectable.

Run `./scripts/ios-test-selection-tests.sh` and list the groups after changing
selections. The selector catches missing and duplicate members; choosing useful
coverage for new behavior remains part of the feature change.

## Run targeted tests

List the groups without Xcode or a running Simulator:

```sh
./scripts/run.sh --ios-simulator --list-ui-groups
```

Choose a booted Simulator in T3's Device panel or Simulator. Set `SIMULATOR_ID`
locally; do not check its value into the repository. All commands below run the
worktree's isolated Dev app, with its own bundle ID, name, store, and badge.

```sh
./scripts/run.sh --ios-simulator --simulator-id "$SIMULATOR_ID" --ui-group smoke
./scripts/run.sh --ios-simulator --simulator-id "$SIMULATOR_ID" --ui-group editing
./scripts/run.sh --ios-simulator --simulator-id "$SIMULATOR_ID" \
  --ui-test testSearchEditReopensInItsOriginalListWithoutDiscardingDraft
./scripts/run.sh --ios-simulator --simulator-id "$SIMULATOR_ID" --unit-test IOSAppModelTests
./scripts/run.sh --ios-simulator --simulator-id "$SIMULATOR_ID" --unit-test all
```

Pass one test selection per command. Repeated or mixed selectors fail before
building. UI method and unit class names are validated too. Removed or renamed
group members fail validation instead of silently reducing coverage. Groups run in one XCTest invocation, with parallel
testing disabled and no automatic retry option. XCTest installs and launches the
Dev app for the selected tests. Omit the selector to open the interactive Dev app.

Package checks support Swift's existing filter:

```sh
swift test --package-path Packages/SnipSnapLibrary --filter SnipLibraryBehaviorTests
swift test --package-path Packages/SnipSnapLibrary
```

The normal account-free gates remain:

```sh
./scripts/test.sh --mac-only
./scripts/test.sh --ios-only
```

The Mac gate includes policy and package tests. The iOS gate runs unit tests and
checks the app's embedded Share extension and privacy manifests. For interactive
app checks and focused or full Dev tests, use `scripts/run.sh`. Compile-only
output from `scripts/build.sh` is not a runnable Dev app.

## Development, PR, and integration cadence

During development, run the affected package filter, iOS unit class, or UI method
first. Use its named group after a repair settles. Add related regressions when
the change crosses a feature boundary; a group is an explicit selection, not a
coverage guarantee.

Before a PR is ready, run both normal account-free gates above. The full package
gate retains sync ordering, recovery, migration, and account-isolation coverage.
For changed iOS workflows, run the affected UI methods or feature groups and
related regressions. Script changes need their policy checks and a real run of
the affected path. Keep failures from any broader run visible and triage their
relationship to the change.

For scheduled integration, run the full UI suite on the relevant iPhone and iPad
families with the required Photos and Files fixtures:

```sh
./scripts/run.sh --ios-simulator --simulator-id "$SIMULATOR_ID" --ui-test all
```

Keep every skip and unmet precondition visible. Release acceptance also follows the
[release checklist](release-checklist.md) and the
[release matrix](building.md#build-and-test). Local fake-transport tests do not
establish live CloudKit or physical-device coverage.

## Reuse build output locally

The Dev runner already keeps a build cache for its claimed Dev slot. The normal
test gates use fresh DerivedData and remove it on exit. For repeated local Mac
checks, the existing override retains a cache inside this worktree:

```sh
SNIP_SNAP_DERIVED_DATA="$PWD/artifacts/local-mac-cache" ./scripts/test.sh --mac-only
```

Each Mac app-host invocation still gets a new store and diagnostics directory.
An explicit cache retains those run directories and Xcode results for inspection;
it does not reuse the previous test library. Keep one writer per cache, use a
different cache for each worktree and Xcode version, and remove only your own
idle cache when reclaiming disk space. Leave the default fresh path available
for clean integration checks.

An empty DerivedData directory does not clear Swift Package Manager's separate
build cache or the OS file cache. When comparing timings, record both states,
the same selection and build settings, and host load. Separate policy checks,
compilation, test-runner startup, and test execution. Caching build output does
not shorten a native UI wait or replace test-store and fixture isolation. Keep
iOS parallel testing disabled; the current paths share device and system UI state.

## Fixtures and isolation

Most UI tests launch with a unique `SNIP_SNAP_UI_TEST_STORE` and seed local snips,
lists, or attachments through the existing UI-test launch environment. Relaunch
checks deliberately reuse that test's store. Those local fixtures need no account
and do not establish live CloudKit coverage.

The extension-import and Share-page workflows use the Dev app's normal app-group
store so the app and extension see the same library. They use unique content and
list names. Setting a temporary store only on the main app would split that
library and invalidate the integration check.

The `share` group, full UI suite, and focused `testShareExtension*` and
`testSharePageShowsEveryListThenSaves` tests start a Python 3 loopback fixture on
port 58493. Its exclusive lock covers the run. Coordinate across worktrees before
starting those checks. Let the owner finish and release its fixture normally;
never remove another run's lock or restart global services. Separate Dev bundle
IDs alone do not isolate this port or a shared Simulator.

Existing conditional tests have these preconditions:

- Compact-library and compact-selector tests require iPhone. The sidebar test
  `testClipboardHidesSavedListActionsOnIPad` requires regular-width iPad.
- `testPhotoPickerStagesAChosenImage` and
  `testEditorKeepsStagedPhotoWhenPhotoPickerIsCancelled` require at least one
  image in the selected Simulator's Photos library. They declare a skip when
  the system picker has no selectable image.
- `testNativePickerAddReplacePreviewAndSaveWhenFixturesAreSeeded` requires
  `attachment-one.txt` and `attachment-two.txt` in local Files and the test-runner
  environment `SNIP_SNAP_UI_TEST_PICKER_FIXTURES=1`. It declares a skip unless
  explicitly enabled. The files must be reachable through the native picker.
  After seeding them, forward the opt-in to the test runner:

  ```sh
  TEST_RUNNER_SNIP_SNAP_UI_TEST_PICKER_FIXTURES=1 ./scripts/run.sh \
    --ios-simulator --simulator-id "$SIMULATOR_ID" \
    --ui-test testNativePickerAddReplacePreviewAndSaveWhenFixturesAreSeeded
  ```

Record actual skips and their preconditions for each run. A declared skip is
unexercised coverage, not a passing assertion. Exercise device-specific workflows
on the matching device family before claiming coverage for that family.

## Diagnose and retain results

Keep evidence under ignored `artifacts/`. Give each attempt a distinct build log:

```sh
mkdir -p artifacts/ios-checks
./scripts/run.sh --ios-simulator --simulator-id "$SIMULATOR_ID" \
  --ui-test testCreatesAndEditsTextSnip \
  --build-log "$PWD/artifacts/ios-checks/edit-attempt-1.log"
```

The runner writes the corresponding `edit-attempt-1-ui-test.log` and prints the
Dev identity and build location. Preserve the `.xcresult` named in the test log;
copy it into the attempt's evidence directory before later runs or cleanup.
The normal `scripts/test.sh` gates delete their temporary DerivedData on exit.
Set an ignored local path to retain their results:

```sh
SNIP_SNAP_DERIVED_DATA="$PWD/artifacts/mac-check/derived-data" ./scripts/test.sh --mac-only
```

Use `xcrun xcresulttool get test-results summary --path <result.xcresult>` and
`xcrun xcresulttool get test-results tests --path <result.xcresult>` for totals
and per-method outcomes. Account for every selected method exactly once;
zero tests, unfinished methods, or duplicate outcomes do not establish a pass.

Record HEAD plus a hash or patch for uncommitted source, Xcode/OS, device model
and runtime, Dev identity, exact commands, fixture setup, exit status, durations,
and every outcome. Keep failed attempts with their screenshots, assertions, and
later dispositions. Classify failures from evidence as product defects, test
selector/driver/timing defects, or fixture/environment blockers. Preserve the
original assertions when repairing a test driver.

The iPhone pager retains offscreen lists in its accessibility tree. For membership
checks, select the intended list and retain its `snip-list-UUID` container. Include
disabled rows within that owner. A global row query can find a snip in another
retained list.

A selected compact tab opens List actions when tapped again. Check selection
before choosing a list, and derive taps from the tab's intersection with the
visible selector. Its accessibility frame can extend beneath neighboring controls.

System edit-menu entries use their native element types. Inspect the captured
hierarchy instead of assuming that an entry such as Paste is a cell. The Share
apps row loads asynchronously. Wait for its first cell before discovering or
scrolling to an activity. Its frames can be relative to the remote collection;
the driver maps those through the current host sheet before swiping.

The Share destination menu loads rows as it scrolls. Reveal each required list
before checking or selecting it. Locate the menu independently of its loaded
rows; it can reopen near a remembered destination with Inbox unloaded. Its
accessibility frame can extend below the visible popup; use the scroll bar's
visible vertical range for gestures. These workflows retain the normal app-group
library. Scale their compact-selector navigation budget with the retained tabs;
the default budget for isolated test stores stays unchanged.

Wait up to 15 seconds for the system Share content collection before checking
its apps row. A cold simulator can present an empty remote container while the
system service starts. Keep the separate eight-second row check and the original
activity, extension, Save, and import assertions. This increases the allowed
system startup time; it does not establish an eight-second end-to-end limit.

After selecting the Share activity, wait up to 15 seconds for an existing
extension state before checking its editor. System process and accessibility
startup can outlast the editor's separate readiness budget. Keep the original
editor, content, Save, and import-count assertions; an error state establishes
startup only and must still fail those assertions.

The system Photos picker can show a loading placeholder before its controls
appear. Wait for that phase to finish before asserting the Photos control or
checking whether the image fixture is missing.

Before keyboard-sensitive geometry or drag assertions, check that the keyboard
frame is inside the app. `exists` can also match an offscreen keyboard. Wait for
custom menu destinations to appear after presentation; the menu hides its
accessibility contents until its animation finishes.

Keep timed actions within the product's real deadline. The `undo` group separates
immediate restoration from layout and contrast inspection. The presentation test
reads one interface snapshot and crops one screenshot after capture; screenshot
processing does not consume the functional test's six-second Undo window.

Iterate with the smallest failing method, then its related group. After repairs
settle, complete the affected coverage under the cadence above. For an intermittent
failure, choose a bounded confirmation count in advance and restore equivalent fresh
state for each attempt. Report all attempts; one lucky rerun is not a reliability
baseline. Leave diagnostics enabled while investigating unexplained failures;
`--no-test-diagnostics` is an explicit troubleshooting option described in
[Build and test](building.md#build-and-test).
