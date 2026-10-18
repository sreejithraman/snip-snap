# Test and legacy-code audit

Audited from `f6b9ec54bb0584597b9276c42b1c335fd08901d5`.
The scope covered the shared package, macOS and iOS app tests, Xcode source
membership, and the normal test runner and its policy checks. Three independent
audit tasks covered cloud, persistence/CLI, and app code. This is a bounded audit,
not proof that every remaining declaration is used by an external consumer.

## Removal evidence

- `SnipLibraryCommand.importArchive` had one caller, in
  `MacLocalSnipLibraryOpenTests`. App imports use
  `SnipLibraryImport.preview(backupURL:target:)` and `applyImport`.
  The old command and the unused static `SwiftDataSnipLibrary.importArchive`
  originated in `5bfb61e4` (#92). ADR 0012 now requires previewed imports through
  the normal record rules. The replacement test retains the content, list, attachment-byte, and
  deleted-request replay assertions. The old command and its attachment
  preparation plumbing are removed.
- `AppModel.copySelectionNow` had four test callers and no production caller.
  Commit `8ca88088` (#169) moved production copying to
  `copySnipsAndMarkDone`. Tests now call its existing awaited counterpart and
  retain their clipboard and completion assertions.
- `AppModel.canReorderSelection` had two test callers. They now call the live
  `canReorder(ids:)` method with the current selection.
- `AppCoordinator.isPanelWindow` only exposed private state to one test. Its
  replacement calls composer expansion and verifies that the attached panel
  resizes while the other window stays unchanged.
- Removed a namespace key's equality comparison with itself and a repeated
  namespace assertion. The literal golden namespace encoding remains covered.

## Bugs found by preserving assertions

The backup test covered the old import command rather than the app's import
flow. Moving it to preview/apply reproduced two failures: the imported store
lost request IDs for previously deleted snips, and replaying one of those
requests added a snip instead of returning duplicate. The fix carries that
backup history into the existing atomic merge. Request history is monotonic;
the merge must retain concurrent target additions and must not commit imported
history after a failed write. Content and sync digest formats stay unchanged.

Independent review also traced the app's backup exporter through the
mode-managed library. That wrapper rebuilt request history from live snips and
dropped deleted requests before export. A managed export/import/reopen test
reproduced the resulting resurrection. The wrapper now reads the underlying
store's complete archive and retains ordered read-health reporting, recovery
quarantines, and its cached snapshot behavior.

The clipboard retry test's sleep gate could register a continuation after its
cancellation handler had already run. A task cancelled before entering the gate
then waited forever. A bounded regression reproduced the failure. Registration
now checks cancellation under the same lock as the handler. The regression
cleans up the broken waiter so a future failure cannot hang the test run.

The iOS test runner exited on an Xcode failure without printing its result
summary before automatic cleanup. A runner regression reproduced the missing
summary. iOS failures now print available result summaries, matching the Mac
path, and preserve Xcode's original exit status even if summary extraction fails.

The Mac preview-recovery test also failed with the correct image visible. Its
pixel helper converted to the monitor's device RGB profile before applying fixed
thresholds. A known red tile acquired a green component of exactly `0.2`, failing
the strict comparison. The helper now converts the whole bitmap to sRGB before
sampling; converting individual colors did not account for its ICC profile. The image-recovery,
expanded-text, pixel-count, threshold, and timeout assertions remain intact.
No thumbnail or view implementation change was needed.

## Retained coverage and candidates

- Legacy text sync remains reachable. `SyncModeStore` decodes an absent protocol
  field as `legacyTextV1`, and `CloudSyncModeCoordinator` selects its adapter.
  Keep old-manifest recovery tests and the adapter.
- Legacy deferred-deletion tests use old persisted JSON and exercise restart,
  local deletion, and ambiguous absence. Production reconciliation still accepts
  those states. Keep them.
- `legacyBindingV1` also labels current corrupt-shadow recovery. Its name does
  not establish obsolescence.
- The JSON library has no app instantiation, but remains a fixture and parity
  adapter across many tests. ADR 0012 makes JSON backup-only in production;
  ADR 0021 still describes dual-adapter tests. Removing the adapter requires
  migrating those fixtures and preserving JSON format coverage. This audit
  retains it rather than deleting those tests.
- Test-fixture commands `restoreList`, `restoreReplacing`, and `replaceAll`
  remain useful for constructing precise recovery and merge cases. `.restore`
  also serves production deletion undo.
- `CommandNumberPicker.legacyOwner` still serves the ownerless
  `setOrderedTargets([])` call in `ContentView`.
- `placeOnClipboardNow` supports awaited cancellation and final-result
  assertions. The live pending-write wait method returns `Void` and cannot
  replace those assertions without changing the clipboard interface.
- Drag-session and pasteboard-lease observers protect interaction and resource
  lifetimes. They are useful test seams.
- App Swift files and test files have Xcode Sources membership with no duplicate
  membership. The release-note Ruby tests run through
  `release-automation-tests.sh`; they are not orphaned from `test.sh`.
- Existing skips cover signed CloudKit prerequisites, OS hot-key contention,
  device layout, manually seeded Photos/Files, or root permission behavior.
  None was removed to obtain a pass.

## Verification

- The initial `scripts/test.sh` run passed all common policy checks and package
  tests, then found the Mac bitmap-measurement failure. The test was repaired
  after an isolated reproduction; its assertions were not weakened.
- `swift test --package-path Packages/SnipSnapLibrary --scratch-path
  /tmp/snipsnap-audit-persistence-build` passed 905 XCTest tests and 17 Swift
  Testing tests, with no failures. This run built before the later managed
  archive-export fix. Thirteen focused backup-history, managed-read, admission,
  and transition tests passed against that final change, including the new
  managed export/import/reopen regression.
- The final complete unsigned Mac scheme test passed 445 tests, failed none,
  and skipped one signed CloudKit transport contract. It used the normal
  `scripts/test.sh` Xcode configuration, default test parallelism, and an
  isolated store and DerivedData directory. The repaired preview test and the
  replacement attached-window behavior test both passed.
- The stable `scripts/test.sh --ios-only` run reported 281 passing tests and no
  failures or skips. The built app's Share extension and both privacy manifests
  passed the bundle check. The first Simulator startup attempt did not produce
  useful test results. A subsequent passing test run also encountered a shell
  error because the runner was edited while executing; the stable rerun above
  replaces that evidence.
- `scripts/test-runner-tests.sh`, `scripts/derived-data-tests.sh`,
  `scripts/tracked-input-policy.sh`, and `git diff --check` passed after the
  relevant runner changes. The runner regression first failed for the missing
  iOS failure summary, then passed while preserving failure exit codes.
- Both request-history bugs and the cancellation helper had failing regressions
  before their fixes. Five backup-history tests and one cancellation regression
  were added. Existing migration, attachment, replay, clipboard, ordering,
  namespace, and window assertions remain covered.

Two review rounds used the original base above. Round one found the managed
export defect, which was fixed with a failing regression. The final correctness,
simplification, and design assessments covered the complete integrated change
and found no blockers. Correctness and simplification used separate GPT-6.1 Sol
reviewers at Medium effort; design used Gemini 3.8 Flash High. The preferred
OpenCode alternates hit rate limits before assessment. Their configured
fallbacks supplied all required review coverage.

The design review's optional sorting observation needs no change: updating the
cached snapshot must retain canonical manual order. A second digest comment
would repeat the existing explanation on the request-history field, so it was
not added.

No implementation blocker remains. Signed live CloudKit, physical-device sync,
the full iOS UI matrix, and manually seeded Photos/Files workflows were not run.
Fake-transport tests do not prove live CloudKit delivery. Legacy text sync and
old persisted-state tests remain because their inputs are still accepted.
The separate JSON-fixture migration was saved in the **Snip Snap** list; this
audit leaves its meaningful coverage intact.
