import SnipSnapCore
import Synchronization
import XCTest

final class SyncedContentSettingsModelTests: XCTestCase {
  @MainActor
  func testLocalOnlyCopyNamesTheSyncBoundaryWithoutClaimingDeviceOnlyStorage() {
    let model = SyncedContentSettingsModel(mode: .localOnly)

    XCTAssertEqual(
      model.detail,
      "Your snips aren’t syncing with iCloud."
    )
    XCTAssertFalse(model.detail.contains("stay on this device"))
    XCTAssertFalse(model.detail.contains("Nothing is uploaded"))
  }

  @MainActor
  func testICloudReadyDetailExplainsWhatSyncs() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    XCTAssertEqual(model.detail, "Your snips and attachments sync through iCloud.")
  }

  @MainActor
  func testConfirmedDeleteReportsProgressAndTheRecoveryCopy() async {
    let calls = DeleteCallCounter()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      deleteAction: {
        await calls.record()
        return .completed
      }
    )

    await model.deleteSyncedContent()

    let count = await calls.value()
    XCTAssertEqual(count, 1)
    XCTAssertEqual(model.state, .deleted)
    XCTAssertFalse(model.canDelete)
    XCTAssertTrue(model.detail.contains("recovery copy"))
  }

  @MainActor
  func testDeletedSyncedCollectionCanStillBeCopiedToLocalOnly() async {
    let calls = DeleteEventRecorder()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      disableAction: { _ in await calls.record("disable") },
      deleteAction: { .completed }
    )

    await model.deleteSyncedContent()

    XCTAssertEqual(model.state, .deleted)
    XCTAssertTrue(model.canDisable)

    await model.disableICloudSync(.useCurrentCache)

    let events = await calls.values()
    XCTAssertEqual(events, ["disable"])
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .ready)
  }

  @MainActor
  func testDeleteCompletesTheAppLibrarySwitchBeforeReportingSuccess() async {
    let calls = DeleteEventRecorder()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      deleteAction: {
        await calls.record("delete")
        return .completed
      }
    )
    model.setDeleteCompletionAction {
      await calls.record("replace-library")
    }

    await model.deleteSyncedContent()

    let events = await calls.values()
    XCTAssertEqual(events, ["delete", "replace-library"])
    XCTAssertEqual(model.state, .deleted)
  }

  @MainActor
  func testPendingRemovalUsesApprovedCopyAndHidesDelete() async {
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      deleteAction: { .removalPending }
    )

    await model.deleteSyncedContent()

    XCTAssertEqual(model.state, .removalPending)
    XCTAssertEqual(model.statusTitle, "Deletion incomplete")
    XCTAssertEqual(
      model.detail,
      "Some synced content is still in iCloud. This device keeps a recovery copy."
    )
    XCTAssertFalse(model.canDelete)
  }

  @MainActor
  func testTryAgainFinishesDeletingOnlyWhenARemovalIsIncomplete() {
    XCTAssertTrue(
      SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending).canFinishDeleting
    )
    let otherStates: [SyncedContentSettingsState] = [
      .ready, .syncing, .disabling, .deleting, .deleted, .failed(.retryingSoon), .enabling(),
    ]
    for state in otherStates {
      XCTAssertFalse(
        SyncedContentSettingsModel(mode: .iCloudSync, initialState: state).canFinishDeleting,
        "iCloud sync in \(state)"
      )
    }
    for state in otherStates + [.removalPending] {
      XCTAssertFalse(
        SyncedContentSettingsModel(mode: .localOnly, initialState: state).canFinishDeleting,
        "Local-only in \(state)"
      )
    }
  }

  @MainActor
  func testTryAgainStaysOfferedWhileItsRetryRuns() async {
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)

    await settings.performExplicitSync { XCTAssertTrue(settings.canFinishDeleting) }
  }

  @MainActor
  func testSuccessfulSyncFinishesARemovalWhoseCompletionReportWasLost() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)
    model.recordRemovalPending()

    _ = model.recordSyncStarted()
    model.recordSyncFailure(.iCloudUnavailable)
    XCTAssertEqual(model.state, .removalPending)

    let laterStart = model.recordSyncStarted()
    model.recordSyncCompleted(laterStart)
    XCTAssertEqual(model.state, .deleted)
    XCTAssertEqual(model.statusTitle, "Synced content deleted")
  }

  @MainActor
  func testSyncStartedBeforeADeleteCannotFinishItsRemoval() async {
    let model = SyncedContentSettingsModel(mode: .iCloudSync, deleteAction: { .removalPending })
    model.recordSyncFailure(.iCloudUnavailable)
    let olderStart = model.recordSyncStarted()

    await model.deleteSyncedContent()
    XCTAssertEqual(model.state, .removalPending)
    model.recordSyncCompleted(olderStart)
    XCTAssertEqual(model.state, .removalPending)

    let laterStart = model.recordSyncStarted()
    model.recordSyncCompleted(laterStart)
    XCTAssertEqual(model.state, .deleted)
  }

  @MainActor
  func testSyncStartedDuringOneRemovalCannotFinishALaterOne() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)
    model.recordRemovalPending()
    let earlierStart = model.recordSyncStarted()

    model.recordSyncStopped(.iCloudAccountChanged)
    model.recordEnableCompleted()
    XCTAssertEqual(model.mode, .iCloudSync)
    XCTAssertEqual(model.state, .ready)
    model.recordRemovalPending()
    model.recordSyncCompleted(earlierStart)

    XCTAssertEqual(model.state, .removalPending)
  }

  @MainActor
  func testRemovalReportFromASyncStartedBeforeADeleteCannotFinishIt() async {
    let model = SyncedContentSettingsModel(mode: .iCloudSync, deleteAction: { .removalPending })
    model.recordSyncFailure(.iCloudUnavailable)
    let olderStart = model.recordSyncStarted()

    await model.deleteSyncedContent()
    XCTAssertEqual(model.state, .removalPending)
    model.recordRemovalCompleted(olderStart)
    XCTAssertEqual(model.state, .removalPending)

    let laterStart = model.recordSyncStarted()
    model.recordRemovalCompleted(laterStart)
    XCTAssertEqual(model.state, .deleted)
  }

  @MainActor
  func testRemovalReportDuringADeleteLeavesTheOutcomeToTheDelete() async {
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      deleteAction: {
        await gate.wait()
        return .removalPending
      }
    )

    let delete = Task { @MainActor in await model.deleteSyncedContent() }
    guard await gate.waitUntilSuspended(within: .seconds(5)) else {
      return XCTFail("The delete never reached its action")
    }
    let start = model.recordSyncStarted()
    model.recordRemovalCompleted(start)
    XCTAssertEqual(model.state, .deleting)

    gate.open()
    await delete.value
    XCTAssertEqual(model.state, .removalPending)
  }

  @MainActor
  func testPendingReportDuringADeleteLeavesTheOutcomeToTheDelete() async {
    let events = Mutex<[AppDiagnosticEvent]>([])
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      deleteAction: {
        await gate.wait()
        return .removalPending
      },
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )

    let delete = Task { @MainActor in await model.deleteSyncedContent() }
    guard await gate.waitUntilSuspended(within: .seconds(5)) else {
      return XCTFail("The delete never reached its action")
    }
    model.recordRemovalPending()
    XCTAssertEqual(model.state, .deleting)

    gate.open()
    await delete.value
    XCTAssertEqual(model.state, .removalPending)
    XCTAssertEqual(events.withLock { $0.map(\.operation) }, ["sync.delete"])
  }

  @MainActor
  func testPendingReportDuringACompletedDeleteEndsDeleted() async {
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      deleteAction: {
        await gate.wait()
        return .completed
      }
    )

    let delete = Task { @MainActor in await model.deleteSyncedContent() }
    guard await gate.waitUntilSuspended(within: .seconds(5)) else {
      return XCTFail("The delete never reached its action")
    }
    model.recordRemovalPending()
    gate.open()
    await delete.value

    XCTAssertEqual(model.state, .deleted)
  }

  @MainActor
  func testRemovalReportShowsDeletedWhenSettingsShowedNoRemoval() {
    let syncing = SyncedContentSettingsModel(mode: .iCloudSync)
    let syncingStart = syncing.recordSyncStarted()
    XCTAssertEqual(syncing.state, .syncing)
    syncing.recordRemovalCompleted(syncingStart)
    XCTAssertEqual(syncing.state, .deleted)

    let ready = SyncedContentSettingsModel(mode: .iCloudSync)
    let readyStart = ready.recordSyncStarted()
    ready.recordOutstandingSyncRecovered()
    XCTAssertEqual(ready.state, .ready)
    ready.recordRemovalCompleted(readyStart)
    XCTAssertEqual(ready.state, .deleted)

    let failed = SyncedContentSettingsModel(
      mode: .iCloudSync,
      initialState: .failed(.iCloudUnavailable)
    )
    let failedStart = failed.recordSyncStarted()
    failed.recordRemovalCompleted(failedStart)
    XCTAssertEqual(failed.state, .deleted)
  }

  @MainActor
  func testExplicitEnableSwitchesModeOnlyAfterLibraryReplacement() async {
    let calls = DeleteEventRecorder()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      enableAction: {
        await calls.record("enable")
        return .enabled
      }
    )
    model.setEnableCompletionAction {
      XCTAssertEqual(model.mode, .localOnly)
      await calls.record("replace-library")
    }

    await model.enableICloudSync()

    let events = await calls.values()
    XCTAssertEqual(events, ["enable", "replace-library"])
    XCTAssertEqual(model.mode, .iCloudSync)
    XCTAssertEqual(model.state, .ready)
  }

  @MainActor
  func testSyncNowRequiresAnIdleEnabledLibrary() async {
    let local = SyncedContentSettingsModel(mode: .localOnly)
    XCTAssertFalse(local.canSyncNow)

    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      disableAction: { _ in }
    )
    XCTAssertTrue(model.canSyncNow)
    _ = model.recordSyncStarted()
    XCTAssertFalse(model.canSyncNow)
    model.recordSyncFailure(.waitingForConnection)
    XCTAssertTrue(model.canSyncNow)
    model.setDisableCompletionAction {
      XCTAssertFalse(model.canSyncNow)
    }
    await model.disableICloudSync(.useCurrentCache)
    XCTAssertFalse(model.canSyncNow)
  }

  @MainActor
  func testExplicitRetryBlocksOtherSurfacesWithoutClearingFailure() async {
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      initialState: .failed(.waitingForConnection)
    )
    var continuation: CheckedContinuation<Void, Never>?
    let retry = Task { @MainActor in
      await model.performExplicitSync {
        await withCheckedContinuation { continuation = $0 }
      }
    }
    while continuation == nil { await Task.yield() }
    XCTAssertFalse(model.canSyncNow)
    XCTAssertEqual(model.state, .failed(.waitingForConnection))
    var secondCallRan = false
    await model.performExplicitSync { secondCallRan = true }
    XCTAssertFalse(secondCallRan)
    continuation?.resume()
    await retry.value
    XCTAssertTrue(model.canSyncNow)
    XCTAssertEqual(model.state, .failed(.waitingForConnection))
  }

  @MainActor
  func testClipboardSyncEligibilityFollowsMainSyncSetupAndDisableTransitions() async {
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      enableAction: { .settingUp(.waitingForConnection) },
      disableAction: { _ in }
    )
    XCTAssertFalse(model.canEnableClipboardSync)

    await model.enableICloudSync()
    XCTAssertFalse(model.canEnableClipboardSync)
    model.recordEnableCompleted()
    XCTAssertTrue(model.canEnableClipboardSync)

    let start = model.recordSyncStarted()
    XCTAssertTrue(model.canEnableClipboardSync)
    model.recordSyncCompleted(start)
    model.setDisableCompletionAction {
      XCTAssertEqual(model.mode, .iCloudSync)
      XCTAssertFalse(model.canEnableClipboardSync)
    }
    await model.disableICloudSync(.useCurrentCache)
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertFalse(model.canEnableClipboardSync)
  }

  @MainActor
  func testOfflineEnableStaysLocalAndSettingUpUntilLifecycleCompletes() async {
    let calls = DeleteEventRecorder()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      enableAction: { .settingUp() },
      cancelEnableAction: { await calls.record("cancel"); return .cancelled }
    )

    await model.enableICloudSync()

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .enabling())
    XCTAssertEqual(model.statusTitle, "Setting up sync…")
    XCTAssertTrue(model.canCancelEnable)

    await model.cancelICloudSyncSetup()

    let cancelEvents = await calls.values()
    XCTAssertEqual(cancelEvents, ["cancel"])
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .ready)
    XCTAssertFalse(model.canCancelEnable)

    await model.enableICloudSync()

    model.recordEnableCompleted()

    XCTAssertEqual(model.mode, .iCloudSync)
    XCTAssertEqual(model.state, .ready)
  }

  @MainActor
  func testUnrelatedFailuresKeepTheirSyncControls() async {
    let calls = DeleteEventRecorder()
    let local = SyncedContentSettingsModel(
      mode: .localOnly, initialState: .failed(.appDataIssue),
      enableAction: { .enabled }, cancelEnableAction: { await calls.record("cancel"); return .cancelled }
    )
    let synced = SyncedContentSettingsModel(
      mode: .iCloudSync, initialState: .failed(.appDataIssue),
      enableAction: { throw CocoaError(.fileReadUnknown) },
      cancelEnableAction: { await calls.record("cancel"); return .cancelled },
      hasFailedPendingEnable: { true }, disableAction: { _ in }
    )
    XCTAssertTrue(local.canEnable)
    XCTAssertFalse(local.isSyncRequested)
    XCTAssertTrue(synced.canDisable)
    XCTAssertTrue(synced.isSyncRequested)
    XCTAssertFalse(local.canCancelEnable)
    XCTAssertFalse(synced.canCancelEnable)
    await local.cancelICloudSyncSetup()
    await synced.cancelICloudSyncSetup()
    let events = await calls.values()
    XCTAssertTrue(events.isEmpty)

    await synced.disableICloudSync(.useCurrentCache)
    XCTAssertEqual(synced.mode, .localOnly)
    XCTAssertFalse(synced.canCancelEnable)
    await synced.enableICloudSync()
    XCTAssertEqual(synced.state, .failed(.appDataIssue))
    XCTAssertTrue(synced.canCancelEnable)
    await synced.cancelICloudSyncSetup()
    let afterCancel = await calls.values()
    XCTAssertEqual(afterCancel, ["cancel"])
  }

  @MainActor
  func testRoutineSyncUsesSettingsStatusForProgressAndFailure() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    _ = model.recordSyncStarted()
    XCTAssertEqual(model.state, .syncing)
    XCTAssertEqual(model.statusTitle, "Syncing with iCloud…")

    model.recordSyncFailure(.iCloudUnavailable)
    XCTAssertEqual(model.state, .failed(.iCloudUnavailable))
    XCTAssertEqual(model.statusTitle, "iCloud unavailable")
    XCTAssertEqual(
      model.detail,
      "iCloud isn’t available right now. Sync will try again."
    )

    _ = model.recordSyncStarted()
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .ready)
  }

  @MainActor
  func testOnlyASettledSyncClearsAnOutstandingIssue() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    let firstStart = model.recordSyncStarted()
    model.recordSyncCompleted(firstStart)
    XCTAssertEqual(model.state, .ready)

    model.recordSyncFailure(.iCloudUnavailable)
    let retryStart = model.recordSyncStarted()
    XCTAssertEqual(model.state, .failed(.iCloudUnavailable))
    model.recordSyncCompleted(retryStart)
    XCTAssertEqual(model.state, .failed(.iCloudUnavailable))
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .ready)

    let storageStart = model.recordSyncStarted()
    model.recordSyncFailure(.iCloudStorageFull)
    model.recordSyncCompleted(storageStart)
    XCTAssertEqual(model.state, .failed(.iCloudStorageFull))
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .ready)

    model.recordRemovalPending()
    XCTAssertEqual(model.state, .removalPending)
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .removalPending)
    let removalStart = model.recordSyncStarted()
    model.recordSyncCompleted(removalStart)
    XCTAssertEqual(model.state, .deleted)

    model.recordSyncStopped(.iCloudDataReset)
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .failed(.iCloudDataReset))
  }

  @MainActor
  func testRetryingAndUserActionFailuresHaveDifferentStatusMessages() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    model.recordSyncFailure(.waitingForConnection)
    XCTAssertEqual(model.statusTitle, "Waiting for connection")
    XCTAssertTrue(model.detail.contains("will sync when you’re back online"))

    model.recordSyncFailure(.iCloudStorageFull)
    XCTAssertEqual(model.statusTitle, "iCloud storage full")
    XCTAssertTrue(model.detail.contains("Free up iCloud storage"))

    model.recordSyncFailure(.updateRequired)
    XCTAssertEqual(model.statusTitle, "Update Snip Snap")
    XCTAssertTrue(model.detail.contains("Update Snip Snap"))
  }

  @MainActor
  func testInternalSyncFailureDoesNotShowRawErrorDetails() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    model.recordSyncFailure(.appDataIssue)

    XCTAssertEqual(model.statusTitle, "Couldn’t sync")
    XCTAssertFalse(model.detail.contains("CloudRecordError"))
    XCTAssertFalse(model.detail.contains("error 2"))
    XCTAssertTrue(model.detail.contains("Retry sync"))
  }

  @MainActor
  func testTurningSyncOffCopiesTheLibraryBeforeReportingLocalOnly() async {
    let calls = DeleteEventRecorder()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      disableAction: { choice in
        XCTAssertEqual(choice, .refreshThenCopy)
        await calls.record("disable")
      }
    )
    model.setDisableCompletionAction {
      XCTAssertEqual(model.mode, .iCloudSync)
      await calls.record("replace-library")
    }

    await model.disableICloudSync(.refreshThenCopy)

    let events = await calls.values()
    XCTAssertEqual(events, ["disable", "replace-library"])
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .ready)
    XCTAssertEqual(model.statusTitle, "Sync off")
  }

  @MainActor
  func testFailedRefreshKeepsSyncOnAndAllowsUsingTheDeviceCopy() async {
    struct Offline: LocalizedError {
      var errorDescription: String? { "iCloud is unavailable." }
    }
    let calls = DeleteEventRecorder()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      issueMapper: { _ in .iCloudUnavailable },
      disableAction: { choice in
        switch choice {
        case .refreshThenCopy:
          throw Offline()
        case .useCurrentCache:
          await calls.record("use-cache")
        }
      }
    )

    await model.disableICloudSync(.refreshThenCopy)

    XCTAssertEqual(model.mode, .iCloudSync)
    XCTAssertEqual(model.statusTitle, "iCloud unavailable")
    XCTAssertTrue(model.detail.contains("Sync will try again"))
    XCTAssertTrue(model.canDisable)

    await model.disableICloudSync(.useCurrentCache)

    let events = await calls.values()
    XCTAssertEqual(events, ["use-cache"])
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .ready)
  }

  @MainActor
  func testFailedEnableShowsTheExactCompatibilityErrorAndAllowsRetry() async {
    struct IncompatibleAttachments: LocalizedError {
      var errorDescription: String? {
        "These attachments cannot sync: first.bin; second.bin"
      }
    }
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      issueMapper: { error in .setupBlocked(error.localizedDescription) },
      enableAction: { throw IncompatibleAttachments() }
    )

    await model.enableICloudSync()

    XCTAssertEqual(model.statusTitle, "Couldn’t set up sync")
    XCTAssertFalse(model.detail.contains("Nothing was uploaded or removed"))
    XCTAssertTrue(model.detail.contains("first.bin"))
    XCTAssertTrue(model.detail.contains("second.bin"))
    XCTAssertTrue(model.canEnable)
  }

  @MainActor
  func testDataResetAndAccountChangeUseClearLocalOnlyMessages() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    model.recordSyncStopped(.iCloudDataReset)
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.statusTitle, "Sync turned off")
    XCTAssertTrue(model.detail.contains("won’t upload again"))

    model.recordSyncStopped(.iCloudAccountChanged)
    XCTAssertEqual(model.statusTitle, "iCloud account changed")
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertTrue(model.detail.contains("your snips are kept on this device"))
  }

  @MainActor
  func testAttachmentStorageFailureExplainsTheLocalProblem() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    model.recordSyncFailure(.attachmentStorageUnavailable)

    XCTAssertEqual(model.statusTitle, "Couldn’t save an attachment")
    XCTAssertTrue(model.detail.contains("Retry sync"))
    XCTAssertFalse(model.detail.contains("error 7"))
  }

  @MainActor
  func testLateEnableSuccessCannotReplaceASyncStop() async {
    let calls = DeleteEventRecorder()
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(mode: .localOnly, enableAction: { .enabled })
    model.setEnableCompletionAction {
      await calls.record("replace-library")
      await gate.wait()
    }

    let enable = Task { @MainActor in await model.enableICloudSync() }
    await gate.waitUntilSuspended()
    model.recordSyncStopped(.iCloudAccountChanged)
    gate.open()
    await enable.value

    let events = await calls.values()
    XCTAssertEqual(events, ["replace-library"])
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.iCloudAccountChanged))
  }

  @MainActor
  func testSyncStopDuringEnableKeepsTheStopAndStillReplacesTheLibrary() async {
    let calls = DeleteEventRecorder()
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      enableAction: {
        await gate.wait()
        return .enabled
      }
    )
    model.setEnableCompletionAction { await calls.record("replace-library") }

    let enable = Task { @MainActor in await model.enableICloudSync() }
    await gate.waitUntilSuspended()
    model.recordSyncStopped(.iCloudAccountChanged)
    gate.open()
    await enable.value

    let events = await calls.values()
    XCTAssertEqual(events, ["replace-library"])
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.iCloudAccountChanged))
  }

  @MainActor
  func testLateDisableCannotReplaceAnICloudDataReset() async {
    let calls = DeleteEventRecorder()
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      disableAction: { _ in await gate.wait() }
    )
    model.setDisableCompletionAction { await calls.record("replace-library") }

    let disable = Task { @MainActor in await model.disableICloudSync(.useCurrentCache) }
    await gate.waitUntilSuspended()
    model.recordSyncStopped(.iCloudDataReset)
    gate.open()
    await disable.value

    let events = await calls.values()
    XCTAssertEqual(events, ["replace-library"])
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.iCloudDataReset))
  }

  @MainActor
  func testLateSetupCancelCannotReplaceASyncStop() async {
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      initialState: .enabling(),
      cancelEnableAction: { await gate.wait(); return .cancelled }
    )

    let cancel = Task { @MainActor in await model.cancelICloudSyncSetup() }
    await gate.waitUntilSuspended()
    model.recordSyncStopped(.iCloudAccountChanged)
    gate.open()
    await cancel.value

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.iCloudAccountChanged))
  }

  @MainActor
  func testSuccessfulSetupCancelInvalidatesTheEarlierPendingEnable() async {
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      enableAction: {
        await gate.wait()
        return .settingUp()
      },
      cancelEnableAction: { .cancelled }
    )

    let enable = Task { @MainActor in await model.enableICloudSync() }
    await gate.waitUntilSuspended()
    await model.cancelICloudSyncSetup()
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .ready)

    gate.open()
    await enable.value

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .ready)
  }

  @MainActor
  func testEnableAfterASettledSyncStopTurnsSyncOn() async {
    let model = SyncedContentSettingsModel(mode: .iCloudSync, enableAction: { .enabled })

    model.recordSyncStopped(.iCloudAccountChanged)
    XCTAssertEqual(model.state, .failed(.iCloudAccountChanged))
    await model.enableICloudSync()

    XCTAssertEqual(model.mode, .iCloudSync)
    XCTAssertEqual(model.state, .ready)
  }

  @MainActor
  func testRepeatedSyncStopStillOutranksALateEnable() async {
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      enableAction: {
        await gate.wait()
        return .enabled
      }
    )

    let enable = Task { @MainActor in await model.enableICloudSync() }
    await gate.waitUntilSuspended()
    model.recordSyncFailure(.iCloudAccountChanged)
    XCTAssertEqual(model.state, .failed(.iCloudAccountChanged))
    model.recordSyncStopped(.iCloudAccountChanged)
    gate.open()
    await enable.value

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.iCloudAccountChanged))
  }

  @MainActor
  func testLateCompletedDeleteCannotReplaceASyncStop() async {
    let calls = DeleteEventRecorder()
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      deleteAction: {
        await gate.wait()
        return .completed
      }
    )
    model.setDeleteCompletionAction { await calls.record("replace-library") }

    let delete = Task { @MainActor in await model.deleteSyncedContent() }
    await gate.waitUntilSuspended()
    model.recordSyncStopped(.signInRequired)
    gate.open()
    await delete.value

    let events = await calls.values()
    XCTAssertEqual(events, ["replace-library"])
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.signInRequired))
  }
}

/// Suspends a Synced Content action until the test opens it.
@MainActor
final class SyncedContentActionGate {
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilSuspended() async {
    while continuation == nil { await Task.yield() }
  }

  /// Returns false if the action doesn't reach `wait()` within `limit`.
  func waitUntilSuspended(within limit: Duration) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while continuation == nil {
      guard ContinuousClock.now < deadline else { return false }
      await Task.yield()
    }
    return true
  }

  func open() {
    continuation?.resume()
    continuation = nil
  }
}

private actor DeleteCallCounter {
  private var count = 0
  func record() { count += 1 }
  func value() -> Int { count }
}

private actor DeleteEventRecorder {
  private var events: [String] = []
  func record(_ event: String) { events.append(event) }
  func values() -> [String] { events }
}
