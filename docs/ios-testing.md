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
| Share sheet or embedded extension | Affected methods or `share`, with its own Share fixture |
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

Choose a booted Simulator in T3's Device panel or Simulator. For a SimLock
lease, also pass its device set; see
[iPhone Duo and SimLock simulators](#iphone-duo-and-simlock-simulators). Set
`SIMULATOR_ID` locally; do not check its value into the repository. All
commands below run the worktree's isolated Dev app, with its own bundle ID,
name, store, and badge.

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

## iPhone Duo and SimLock simulators

T3's SimLock host keeps leased simulators in SimLock's own device set, not
Xcode's default set. Pass that set to the runner. The runner reads
`SIMLOCK_IOS_DEVICE_SET`, and `--simulator-set PATH` overrides it, for both
`ios-simulator` and `--ios-simulator`. A custom set needs Xcode 27 or later.
Without a set, the runner uses the default set as before.

### Launch the Dev app on a leased Duo

The iPhone Duo needs Xcode 27.1 or later and the iOS 27.1 runtime. In T3, call
`device_list`, then `device_open` with the `simlock-` host and
`simlock:ios:iPhone Duo`. Copy three values from its `agentDevice` result.
Pass `AD_ARGS` to every `$AD` call so each call targets your lease.
`session list` shows every T3 thread's sessions on that host, so select yours
by name. Then read the lease's UDID and set, and launch:

```sh
AD='/…/agent-device'                                       # command
AD_ARGS=('--config' '/…/hosts/….json' '--session' 't3-…')  # targetArgs, in order
SESSION='t3-…'                                             # session
sessions="$("$AD" session list --json "${AD_ARGS[@]}")"
field() {
  print -r -- "$sessions" | ruby -rjson -e '
    mine = JSON.parse(STDIN.read).dig("data", "sessions").find { |s| s["name"].end_with?(":#{ARGV[0]}") }
    puts mine.fetch(ARGV[1])' "$SESSION" "$1"
}
UDID="$(field device_udid)"
SET="$(field ios_simulator_device_set)"
SIMLOCK_IOS_DEVICE_SET="$SET" ./scripts/run.sh ios-simulator "$UDID"
```

To seed 24 Inbox rows for layout checks, relaunch with the long-list fixture
in its own store:

```sh
SIMCTL_CHILD_SNIP_SNAP_UI_TESTING=1 SIMCTL_CHILD_SNIP_SNAP_UI_TEST_STORE=duo \
SIMCTL_CHILD_SNIP_SNAP_UI_TEST_LONG_LIST=1 \
  simlock simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID"
```

`BUNDLE_ID` is the `Bundle:` line the runner prints. Keyboard input does not
reach iOS 27 guests through SimLock, so `agent-device fill` cannot type.

### Run UI tests on the Duo

UI tests build, install, run, and type on the leased Duo:

```sh
./scripts/run.sh --ios-simulator --simulator-id "$UDID" --simulator-set "$SET" \
  --ui-test testCreatesAndEditsTextSnip
```

Use XCUITest for typed input. A test cannot fold the Duo itself, but it sees a
fold the host makes while it runs: the window changes between 466×678 (closed)
and 951×669 (open or half-open), and XCTest logs "Interface orientation
changed". [Fold during a UI test](#fold-during-a-ui-test) shows how a test asks
the host for each pose.

### Change the pose

The Duo has an outer panel (466×678 points, lit when closed) and an inner panel
(669×951 points, lit when open or half-open). The app gets a 951×669 window on
the inner panel.

`agent-device fold` refuses SimLock-set simulators. Run its fold helper
through SimLock instead. agent-device caches a built helper after its first
fold on a default-set Duo. Otherwise build one from its source:

```sh
FOLD_HELPER="$(ls -d ~/.agent-device/fold-helper/*/fold-helper 2>/dev/null | head -1)"
if [[ -z "$FOLD_HELPER" ]]; then
  FOLD_HELPER="$PWD/artifacts/duo/fold-helper"
  mkdir -p "${FOLD_HELPER:h}"
  xcrun --sdk iphonesimulator clang -mios-simulator-version-min=15.0 -fobjc-arc \
    -framework Foundation -framework IOKit \
    "$(ls -d ~/.t3/tools/agent-device/*/node_modules/agent-device/apple/fold-helper/Fold.m | tail -1)" \
    -o "$FOLD_HELPER"
fi
simlock simctl spawn "$UDID" "$FOLD_HELPER" closed    # or open, half-open
```

The helper sends the hinge angle but does not verify it. Check the lit panel
with `"$AD" snapshot --json "${AD_ARGS[@]}"`: `data.viewport` is 466×678
when closed and 951×669 when open or half-open. Half-open moves the sidebar
edge to the hinge. Refs and coordinates change with every pose, so snapshot
again after a fold.

### Fold during a UI test

Four tests fold the Duo:

- `testFocusedComposerSurvivesFoldingTheDuo` types into the composer and
  checks its draft and keyboard focus after each pose.
- `testFoldingTheDuoKeepsPlaceAndUnsentWork` checks gathered snips, an active
  search, the Settings sheet, and a list's draft with an attachment.
- `testComposerPickersSurviveFoldingTheDuo` keeps the Files and Photos pickers
  open through each pose, then picks a photo if the library has one.
- `testComposerAttachmentPreviewSurvivesFoldingTheDuo` keeps a draft
  attachment's preview open through each pose, with no keyboard over it.

The composer camera closes on a fold and keeps the draft. No UI test drives
it; three checks cover it:

- `testLayoutSwapClosesOnlyTheCameraAndKeepsTheDraft` checks the rule in
  storage and runs everywhere.
- `testRootClosesTheCameraWhenItSwapsLayouts` swaps the real root with the
  camera up. It runs only where `UIImagePickerController.isSourceTypeAvailable(.camera)`
  is true, such as the iPhone Duo simulator. The iPhone simulator and CI may
  have no camera, and presenting one there raises, so it skips.
- A hand check on the Duo covers a real fold.

Each test asks for a pose by writing `NN-<pose>.request` into the directory
named by `SNIP_SNAP_UI_TEST_FOLD_DIR`. `NN` counts requests already in the
directory, so the tests can share it. The host folds and answers with
`NN-<pose>.done`. Without that directory, the tests skip. Start the host loop,
then a test:

```sh
FOLDS="$(mktemp -d)"
while sleep 0.5; do
  for request in "$FOLDS"/*.request(N); do
    name="${request:t:r}"
    [[ -e "$FOLDS/$name.done" ]] && continue
    simlock simctl spawn "$UDID" "$FOLD_HELPER" "${name#*-}" && sleep 3
    : > "$FOLDS/$name.done"
  done
done &
TEST_RUNNER_SNIP_SNAP_UI_TEST_FOLD_DIR="$FOLDS" ./scripts/run.sh --ios-simulator \
  --simulator-id "$UDID" --simulator-set "$SET" --ui-test testFocusedComposerSurvivesFoldingTheDuo
kill %1
```

Before the next run, reset with the app in front:

```sh
simlock simctl spawn "$UDID" "$FOLD_HELPER" open && sleep 3
"$AD" open "$BUNDLE_ID" "${AD_ARGS[@]}" && sleep 3
simlock simctl spawn "$UDID" "$FOLD_HELPER" closed && sleep 3
simlock simctl io "$UDID" screenshot --display=primary reset-closed.png
```

Check that `reset-closed.png` shows the app, not the Home Screen, before the
next run. See Known limits.

### Capture each panel

`agent-device screenshot` and T3's `device_screenshot` cannot choose between
the two panels. Name the lit panel:

```sh
simlock simctl io "$UDID" screenshot --display=primary closed.png      # outer
simlock simctl io "$UDID" screenshot --display=primary-1 open.png      # inner
```

`simlock simctl io "$UDID" enumerate` lists the screens. The dark panel
captures as a black image.

### Open Split View on the inner panel

Fold open, then go to the Home Screen:

```sh
"$AD" open com.apple.springboard "${AD_ARGS[@]}"
```

Long-press the app icon and choose "Open in Split View". The app opens on the
left in a 469×669 window, and the Home Screen fills the right side. To put the
app on the right instead, long-press another app's icon, such as Settings,
choose "Open in Split View", then tap the app's icon in the right-hand Home
Screen.

The app gets the compact layout in both halves. On the right, the window
includes the status-bar column, so its trailing safe-area inset is about 84
points, as on the closed panel. On the left, the system puts the toolbar column
on the leading side. Capture with `--display=primary-1`.

Opening SpringBoard through agent-device ends Split View, so arrange the split
last.

### Known limits

- Rotation does nothing on the leased Duo, so closed landscape is not
  reachable. `"$AD" orientation landscape-left "${AD_ARGS[@]}"` reports
  "unconfirmed". In a UI test, `XCUIDevice.shared.orientation = .landscapeLeft`
  reports landscape, but the window and panel capture stay unchanged when
  closed or open. `simlock rotate` refuses a T3-owned lease. So
  `testListEditorIconSearchKeepsControlsReachable`, which asks for landscape,
  fails on the closed panel ("Icon search must stay pinned").
- Typing works only through XCUITest, and only on the outer panel. XCTest key
  events do not reach the inner panel.
- Moving between panels can end text editing: the system keyboard resigns the
  focused field. Runs for PR 279 saw this after half-opens; later runs kept
  focus. When it happens, the composer drops its focus, and one tap resumes
  typing.
- A run that ends on the inner panel can leave the next run unable to give a
  text field keyboard focus. Reset with the app in front before the next run,
  as in [Fold during a UI test](#fold-during-a-ui-test).
- A reset with the Home Screen in front can leave apps that launch on the
  closed panel off screen. XCTest then sees a 466×678 window while the outer
  panel shows the Home Screen, and taps reach SpringBoard.
- Half-open is checked only through the layout change, not the hinge angle. Its
  window matches open.
- After the app moves from the inner panel back to the outer panel, XCTest can
  wait 60 seconds per action and log "App animations complete notification not
  received". The app is idle then: a sample shows its main thread waiting for
  events, and its windows hold no running Core Animation animations. It stalled
  with and without a focused composer. Expect slow runs; the wait is not an app
  animation.
- `agent-device fold`, `agent-device screenshot`, and `device_screenshot`
  fail on SimLock-set simulators, as described above.

When done, call `device_close` with `shutdown: true`. That ends the lease, and
SimLock wipes the device.

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
an OS-assigned loopback port. The runner passes that run's URL to XCTest and
cleans up only its own fixture. Separate worktrees can run their fixtures at the
same time. Keep each run on its own Simulator and Dev identity; separate ports
do not isolate a shared Simulator. Never stop another run's processes or restart
global services.

Existing conditional tests have these preconditions:

- Compact-library and compact-selector tests require a compact window. Large
  iPhones can use the sidebar layout in landscape. The sidebar test
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
