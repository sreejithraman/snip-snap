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
      cancelEnableAction: { await calls.record("cancel") }
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
    XCTAssertTrue(model.detail.contains("previous account’s snips stay separate"))
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
      cancelEnableAction: { await gate.wait() }
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
  func testSetupCancelDuringEnableStillLetsBothResultsApplyInOrder() async {
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      enableAction: {
        await gate.wait()
        return .settingUp()
      },
      cancelEnableAction: {}
    )

    let enable = Task { @MainActor in await model.enableICloudSync() }
    await gate.waitUntilSuspended()
    await model.cancelICloudSyncSetup()
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .ready)

    gate.open()
    await enable.value

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .enabling())
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


extension SyncedContentSettingsModelTests {
  @MainActor
  func testLegacyExplicitAdmissionRefusesTypedRetryWithoutTouchingWinnerOrPriorIssue() async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .failed(.waitingForConnection))
    work.retain(settings)
    let gate = work.gate()
    var winnerCalls = 0
    var loserCalls = 0
    let winner = work.start {
      await settings.performExplicitSync {
        winnerCalls += 1
        await gate.suspend()
      }
    }
    guard await work.ready(gate.entered, "legacy explicit admission") else {
      await work.cleanUp(); return
    }
    let loser = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { _ in
          loserCalls += 1
          return .finished(.noChange, .notRequired)
        }
        guard case .notRun(.overlappingExplicitAction) = outcome else {
          return XCTFail("The actual shared admission must report overlap")
        }
      } catch { XCTFail("Admission refusal must be a notRun result: \(error)") }
    }
    let completed = await loser.finished.wait(for: .seconds(2))
    XCTAssertTrue(completed, "Typed refusal must not join the legacy winner")
    XCTAssertEqual(winnerCalls, 1)
    XCTAssertEqual(loserCalls, 0)
    XCTAssertTrue(gate.isHeld)
    XCTAssertFalse(winner.finished.isSet)
    XCTAssertFalse(settings.canSyncNow)
    XCTAssertEqual(settings.state, .failed(.waitingForConnection))
    gate.release()
    let finished = await winner.finished.wait(for: .seconds(2))
    XCTAssertTrue(finished, "Legacy winner must end after its own release")
    XCTAssertTrue(settings.canSyncNow)
    XCTAssertEqual(settings.state, .failed(.waitingForConnection))
    await work.cleanUp()
    XCTAssertEqual(loserCalls, 0)
  }

  @MainActor
  func testTypedExplicitAdmissionRefusesLegacyRetryWithoutFinishingTheWinner() async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
    work.retain(settings)
    let gate = work.gate()
    var winnerCalls = 0
    var loserCalls = 0
    let winner = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { _ in
          winnerCalls += 1
          await gate.suspend()
          return .finished(.noChange, .notRequired)
        }
        guard case .completed = outcome else {
          return XCTFail("Core must project the admitted raw original return")
        }
      } catch { XCTFail("Unexpected winner error: \(error)") }
    }
    guard await work.ready(gate.entered, "typed explicit admission") else {
      await work.cleanUp(); return
    }
    let loser = work.start { await settings.performExplicitSync { loserCalls += 1 } }
    let completed = await loser.finished.wait(for: .seconds(2))
    XCTAssertTrue(completed, "The legacy loser must return without joining typed work")
    XCTAssertEqual(winnerCalls, 1)
    XCTAssertEqual(loserCalls, 0)
    XCTAssertFalse(winner.finished.isSet)
    XCTAssertTrue(gate.isHeld)
    XCTAssertEqual(settings.state, .removalPending)
    XCTAssertTrue(settings.canFinishDeleting)
    XCTAssertNil(settings.finishDeletingIssue)
    gate.release()
    let finished = await winner.finished.wait(for: .seconds(2))
    XCTAssertTrue(finished)
    XCTAssertEqual(settings.state, .removalPending, "Releasing admission is not removal completion")
    await work.cleanUp()
    XCTAssertEqual(loserCalls, 0)
  }

  @MainActor
  func testTypedThrowPreservesErrorIdentityAndReleasesOnlyItsOwnAdmission() async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .failed(.waitingForConnection))
    work.retain(settings)
    let failure = OriginalOutcomeFailure()
    var caughtOriginal = false
    let throwing = work.start {
      do {
        _ = try await settings.performExplicitSyncWithOutcome { _ in throw failure }
        XCTFail("A thrown original action must not become completed success")
      } catch { caughtOriginal = (error as AnyObject) === failure }
    }
    guard await work.prompt(throwing.finished, "original throwing action") else {
      await work.cleanUp(); return
    }
    XCTAssertTrue(caughtOriginal)
    XCTAssertTrue(settings.canSyncNow)
    XCTAssertEqual(settings.state, .failed(.waitingForConnection))
    let gate = work.gate()
    let next = work.start { await settings.performExplicitSync { await gate.suspend() } }
    guard await work.ready(gate.entered, "next legacy owner after throw") else {
      await work.cleanUp(); return
    }
    throwing.task.cancel()
    var loserCalls = 0
    let loser = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { _ in
          loserCalls += 1
          return .finished(.noChange, .notRequired)
        }
        guard case .notRun(.overlappingExplicitAction) = outcome else {
          return XCTFail("A completed prior caller cannot release the next owner's admission")
        }
      } catch { XCTFail("Unexpected refusal error: \(error)") }
    }
    let completed = await loser.finished.wait(for: .seconds(2))
    XCTAssertTrue(completed)
    XCTAssertEqual(loserCalls, 0)
    XCTAssertTrue(gate.isHeld)
    XCTAssertFalse(next.finished.isSet)
    await work.cleanUp()
  }

  @MainActor
  func testTypedCancellationKeepsAdmissionUntilItsBodyExitsAndDoesNotInventAReport() async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .failed(.waitingForConnection))
    work.retain(settings)
    let gate = work.gate()
    var cancelled = false
    let owner = work.start {
      do {
        _ = try await settings.performExplicitSyncWithOutcome { _ in
          await gate.suspend()
          try Task.checkCancellation()
          return .finished(.noChange, .notRequired)
        }
        XCTFail("Real cancellation before an origin must throw, not fabricate a report")
      } catch is CancellationError { cancelled = true }
      catch { XCTFail("The actual cancellation must survive: \(error)") }
    }
    guard await work.ready(gate.entered, "cancellable typed body") else {
      await work.cleanUp(); return
    }
    owner.task.cancel()
    var loserCalls = 0
    let loser = work.start { await settings.performExplicitSync { loserCalls += 1 } }
    let refused = await loser.finished.wait(for: .seconds(2))
    XCTAssertTrue(refused)
    XCTAssertEqual(loserCalls, 0)
    XCTAssertTrue(gate.isHeld)
    XCTAssertFalse(owner.finished.isSet)
    gate.release()
    guard await work.prompt(owner.finished, "cancelled body released") else {
      await work.cleanUp(); return
    }
    XCTAssertTrue(cancelled)
    XCTAssertTrue(settings.canSyncNow)
    XCTAssertEqual(settings.state, .failed(.waitingForConnection))
    let nextGate = work.gate()
    let next = work.start { await settings.performExplicitSync { await nextGate.suspend() } }
    guard await work.ready(nextGate.entered, "new owner after cancellation") else {
      await work.cleanUp(); return
    }
    owner.task.cancel()
    let laterLoser = work.start { await settings.performExplicitSync { loserCalls += 1 } }
    let laterRefused = await laterLoser.finished.wait(for: .seconds(2))
    XCTAssertTrue(laterRefused)
    XCTAssertEqual(loserCalls, 0)
    XCTAssertTrue(nextGate.isHeld)
    XCTAssertFalse(next.finished.isSet)
    await work.cleanUp()
  }

  @MainActor
  func testTypedEnableWaitsForItsRealRequiredCompletionBeforeReportingSuccess() async {
    let work = OriginalOutcomeOwnership()
    let events = DeleteEventRecorder()
    let gate = work.gate()
    let settings = SyncedContentSettingsModel(mode: .localOnly, enableAction: {
      await events.record("enable")
      return .enabled
    })
    work.retain(settings)
    settings.setEnableCompletionAction {
      await events.record("required application")
      await gate.suspend()
    }
    let enable = work.start {
      let outcome = await settings.enableICloudSyncWithOutcome()
      guard case .completed(let report) = outcome else {
        return XCTFail("Actual enabled plus completed hook must produce its original report")
      }
      guard case .succeeded = report.operation.status else {
        return XCTFail("The actual enable and required completion succeeded")
      }
      XCTAssertEqual(report.operation.message, "Your snips and attachments sync through iCloud.")
    }
    guard await work.ready(gate.entered, "real enable completion hook") else {
      await work.cleanUp(); return
    }
    let premature = await enable.finished.wait(for: .seconds(2))
    XCTAssertFalse(premature, "Required application is awaited, not optional current evidence")
    XCTAssertTrue(gate.isHeld)
    XCTAssertEqual(settings.mode, .localOnly)
    XCTAssertEqual(settings.state, .enabling())
    gate.release()
    guard await work.prompt(enable.finished, "enabled report after required hook") else {
      await work.cleanUp(); return
    }
    let actualEvents = await events.values()
    XCTAssertEqual(actualEvents, ["enable", "required application"])
    XCTAssertEqual(settings.mode, .iCloudSync)
    XCTAssertEqual(settings.state, .ready)
    await work.cleanUp()
  }

  @MainActor
  func testTypedEnableReportsActualPendingSetupWithoutCallingTheCompletionHook() async {
    let work = OriginalOutcomeOwnership()
    let events = DeleteEventRecorder()
    let settings = SyncedContentSettingsModel(mode: .localOnly, enableAction: {
      await events.record("enable")
      return .settingUp(.waitingForConnection)
    })
    work.retain(settings)
    settings.setEnableCompletionAction { await events.record("must not apply pending setup") }
    let enable = work.start {
      let outcome = await settings.enableICloudSyncWithOutcome()
      guard case .completed(let report) = outcome else { return XCTFail("Pending setup is an original outcome") }
      guard case .succeeded = report.operation.status else {
        return XCTFail("Existing pending-setup operation encoding is success, not enabled confirmation")
      }
      XCTAssertEqual(report.operation.message, "Connect to the internet to finish setup.")
    }
    guard await work.prompt(enable.finished, "pending setup report") else {
      await work.cleanUp(); return
    }
    let actualEvents = await events.values()
    XCTAssertEqual(actualEvents, ["enable"])
    XCTAssertEqual(settings.mode, .localOnly)
    XCTAssertEqual(settings.state, .enabling(.waitingForConnection))
    await work.cleanUp()
  }

  @MainActor
  func testTypedEnableReportsItsActualRequiredHookFailure() async {
    let work = OriginalOutcomeOwnership()
    let failure = OriginalOutcomeFailure()
    var hookCalls = 0
    let settings = SyncedContentSettingsModel(mode: .localOnly, issueMapper: { _ in .attachmentMissing },
                                            enableAction: { .enabled })
    work.retain(settings)
    settings.setEnableCompletionAction { hookCalls += 1; throw failure }
    let enable = work.start {
      let outcome = await settings.enableICloudSyncWithOutcome()
      guard case .completed(let report) = outcome else { return XCTFail("The real failed enable owns a report") }
      guard case .failed = report.operation.status else {
        return XCTFail("A real required application failure cannot be optional unverified success")
      }
      XCTAssertEqual(report.operation.message, "Can’t read an attachment. Retry sync. If it still fails, contact support.")
    }
    guard await work.prompt(enable.finished, "required hook failure report") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(hookCalls, 1)
    XCTAssertEqual(settings.mode, .localOnly)
    XCTAssertEqual(settings.state, .failed(.attachmentMissing))
    await work.cleanUp()
  }

  @MainActor
  func testTypedLateEnableCannotReportSuccessAfterTheOriginalStatusSessionStops() async {
    let work = OriginalOutcomeOwnership()
    let gate = work.gate()
    let settings = SyncedContentSettingsModel(mode: .localOnly, enableAction: {
      await gate.suspend()
      return .enabled
    })
    work.retain(settings)
    let enable = work.start {
      let outcome = await settings.enableICloudSyncWithOutcome()
      guard case .interrupted = outcome else {
        return XCTFail("A stopped original session cannot manufacture an enabled report")
      }
    }
    guard await work.ready(gate.entered, "original enable before status-session stop") else {
      await work.cleanUp(); return
    }
    settings.recordSyncStopped(.iCloudAccountChanged)
    gate.release()
    guard await work.prompt(enable.finished, "late original enable report") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(settings.mode, .localOnly)
    XCTAssertEqual(settings.state, .failed(.iCloudAccountChanged))
    await work.cleanUp()
  }
}


extension SyncedContentSettingsModelTests {
  @MainActor
  func testTypedOverlapDoesNotClearTheWinningRemovalsActualFailure() async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
    work.retain(settings)
    let gate = work.gate()
    let winner = work.start {
      await settings.performExplicitSync {
        settings.recordSyncFailure(.waitingForConnection)
        await gate.suspend()
      }
    }
    guard await work.ready(gate.entered, "winning removal retry after its own issue") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(settings.finishDeletingIssue, .waitingForConnection)
    var loserCalls = 0
    let loser = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { _ in
          loserCalls += 1
          return .finished(.noChange, .notRequired)
        }
        guard case .notRun(.overlappingExplicitAction) = outcome else {
          return XCTFail("Real overlap must refuse before clearing removal failure")
        }
      } catch { XCTFail("Unexpected refusal error: \(error)") }
    }
    let completed = await loser.finished.wait(for: .seconds(2))
    XCTAssertTrue(completed)
    XCTAssertEqual(loserCalls, 0)
    XCTAssertEqual(settings.finishDeletingIssue, .waitingForConnection)
    XCTAssertEqual(settings.state, .removalPending)
    XCTAssertEqual(settings.detail, "Some synced content is still in iCloud. This device keeps a recovery copy.")
    XCTAssertTrue(gate.isHeld)
    XCTAssertFalse(winner.finished.isSet)
    gate.release()
    guard await work.prompt(winner.finished, "winning removal body finished") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(settings.state, .removalPending)
    XCTAssertEqual(settings.finishDeletingIssue, .waitingForConnection)
    await work.cleanUp()
    XCTAssertEqual(loserCalls, 0)
  }

  @MainActor
  func testTypedEnableAfterAnOldAccountStopDoesNotInheritTheOldRemovalIssue() async {
    let work = OriginalOutcomeOwnership()
    let events = DeleteEventRecorder()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending,
      enableAction: { await events.record("enable"); return .enabled })
    work.retain(settings)
    let failedRemoval = work.start {
      await settings.performExplicitSync { settings.recordSyncFailure(.waitingForConnection) }
    }
    guard await work.prompt(failedRemoval.finished, "old explicit removal issue") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(settings.finishDeletingIssue, .waitingForConnection)
    settings.recordSyncStopped(.iCloudAccountChanged)
    settings.setEnableCompletionAction { await events.record("required application") }
    let enable = work.start {
      let outcome = await settings.enableICloudSyncWithOutcome()
      guard case .completed(let report) = outcome else { return XCTFail("Actual fresh enable must own its report") }
      guard case .succeeded = report.operation.status else {
        return XCTFail("An old removal/account issue cannot replace the new original enabled outcome")
      }
      XCTAssertEqual(report.operation.message, "Your snips and attachments sync through iCloud.")
    }
    guard await work.prompt(enable.finished, "fresh original enable after old account stop") else {
      await work.cleanUp(); return
    }
    let actualEvents = await events.values()
    XCTAssertEqual(actualEvents, ["enable", "required application"])
    XCTAssertEqual(settings.mode, .iCloudSync)
    XCTAssertEqual(settings.state, .ready)
    XCTAssertNil(settings.finishDeletingIssue)
    await work.cleanUp()
  }
}

private final class OriginalOutcomeFailure: Error, @unchecked Sendable {}

// A timeout ends observation only; it never releases either retry's behavior gate.
private final class OriginalOutcomeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var isSet: Bool { lock.withLock { fired } }

    func fire() {
        let pending = lock.withLock {
            fired = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume(returning: true) }
    }

    private func observe() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Bool? = lock.withLock {
                    if fired { return true }
                    if Task.isCancelled { return false }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            self.lock.withLock { self.waiters.removeValue(forKey: id) }?.resume(returning: false)
        }
    }

    func wait(for timeout: Duration) async -> Bool {
        if isSet { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.observe() }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch {}
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

private final class OriginalOutcomeGate: @unchecked Sendable {
    let entered = OriginalOutcomeSignal()
    private let lock = NSLock()
    private var released = false
    private var pending: CheckedContinuation<Void, Never>?
    var isHeld: Bool { entered.isSet && lock.withLock { !released } }

    func suspend() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if released { return true }
                pending = continuation
                return false
            }
            entered.fire()
            if resume { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            let continuation = pending
            pending = nil
            return continuation
        }
        continuation?.resume()
    }
}

@MainActor
private final class OriginalOutcomeTask {
    let finished: OriginalOutcomeSignal
    let task: Task<Void, Never>

    init(_ operation: @escaping @MainActor () async -> Void) {
        let completion = OriginalOutcomeSignal()
        finished = completion
        task = Task {
            await operation()
            completion.fire()
        }
    }
}

@MainActor
private final class OriginalOutcomeOwnership {
    private var gates: [OriginalOutcomeGate] = []
    private var tasks: [OriginalOutcomeTask] = []
    private var resources: [AnyObject] = []
    private var retainedAfterFailedJoin: OriginalOutcomeOwnership?

    func retain(_ resource: AnyObject) { resources.append(resource) }

    func gate() -> OriginalOutcomeGate {
        let gate = OriginalOutcomeGate()
        gates.append(gate)
        return gate
    }

    func start(_ operation: @escaping @MainActor () async -> Void) -> OriginalOutcomeTask {
        let task = OriginalOutcomeTask(operation)
        tasks.append(task)
        return task
    }

    func ready(_ signal: OriginalOutcomeSignal, _ stage: String) async -> Bool {
        let ready = await signal.wait(for: .seconds(30))
        XCTAssertTrue(ready, "Original-outcome setup/readiness failed: \(stage)")
        return ready
    }

    func cleanUp() async {
        let cleanup = Task { @MainActor [self] in
            gates.forEach { $0.release() }
            tasks.forEach { $0.task.cancel() }
            let deadline = ContinuousClock.now + .seconds(30)
            var settled = true
            for operation in tasks {
                let joined = await operation.finished.wait(for: deadline - ContinuousClock.now)
                XCTAssertTrue(joined, "Original-outcome cleanup could not join an owned caller")
                if joined { await operation.task.value } else { settled = false }
            }
            guard settled else {
                retainedAfterFailedJoin = self
                return
            }
            tasks.removeAll()
            gates.removeAll()
            resources.removeAll()
        }
        await cleanup.value
    }
}

@MainActor
private extension OriginalOutcomeOwnership {
    func prompt(_ signal: OriginalOutcomeSignal, _ stage: String) async -> Bool {
        let completed = await signal.wait(for: .seconds(2))
        XCTAssertTrue(completed, "Original-outcome completion exceeded prompt budget: \(stage)")
        return completed
    }
}


// Raw returns exercise Core projection only, without application or managed-current proof.
extension SyncedContentSettingsModelTests {
  @MainActor
  func testOriginalFoldStartsBeforeTheBodyAndReturnsTheOriginalReadyDetail() async {
    await checkOriginalProjection(initial: .ready, bodyState: .syncing,
      returning: .finished(.noChange, .notRequired), failed: false,
      message: "Your snips and attachments sync through iCloud.")
  }

  @MainActor
  func testOriginalFetchAndScheduleValuesDoNotEraseTheOriginalPriorIssue() async {
    let values: [SyncedContentOriginalActionReturn] = [
      .finished(.noChange, .notRequired),
      .finished(.contentUpdated, .notRequired),
      .finished(.syncScheduled, .notRequired)
    ]
    for value in values {
      await checkOriginalProjection(initial: .failed(.waitingForConnection),
        bodyState: .failed(.waitingForConnection), returning: value, failed: true,
        message: "Your changes will sync when you’re back online.")
    }
  }

  @MainActor
  func testOriginalSettledValueRecoversItsOwnPriorIssueInTheProjectionOnly() async {
    await checkOriginalProjection(initial: .failed(.waitingForConnection),
      bodyState: .failed(.waitingForConnection), returning: .finished(.syncCompleted, .notRequired),
      failed: false, message: "Your snips and attachments sync through iCloud.")
  }

  @MainActor
  func testOriginalResultValuedIssueUsesItsOwnLiteralDetail() async {
    await checkOriginalProjection(initial: .ready, bodyState: .syncing,
      returning: .finished(.syncIssue(.attachmentUnavailable), .notRequired), failed: true,
      message: "iCloud can’t provide this attachment yet. Sync will try again.")
  }

  @MainActor
  func testOriginalRemovalIssueAndPendingValueKeepTheGenericIncompleteRemovalDetail() async {
    let values: [SyncedContentOriginalActionReturn] = [
      .finished(.syncIssue(.waitingForConnection), .notRequired),
      .finished(.oldSyncedContentRemovalPending, .notRequired)
    ]
    for value in values {
      await checkOriginalProjection(initial: .removalPending, bodyState: .removalPending,
        returning: value, failed: true,
        message: "Some synced content is still in iCloud. This device keeps a recovery copy.")
    }
  }

  @MainActor
  func testOriginalNormalAndRemovalCompletionValuesFinishTheirOwnPendingRemoval() async {
    let values: [SyncedContentOriginalActionReturn] = [
      .finished(.noChange, .notRequired),
      .finished(.oldSyncedContentRemovalCompleted, .notRequired)
    ]
    for value in values {
      await checkOriginalProjection(initial: .removalPending, bodyState: .removalPending,
        returning: value, failed: false, message: "This device keeps a recovery copy.")
    }
  }

  @MainActor
  func testOriginalRemovalNormalCompletionAfterItsOwnIssueStillProjectsSuccess() async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
    work.retain(settings)
    var calls = 0
    let operation = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { _ in
          calls += 1
          settings.recordSyncFailure(.waitingForConnection)
          XCTAssertEqual(settings.finishDeletingIssue, .waitingForConnection)
          return .finished(.noChange, .notRequired)
        }
        guard case .completed(let report) = outcome else { return XCTFail("Expected the original removal projection") }
        guard case .succeeded = report.operation.status else {
          return XCTFail("Own normal completion takes precedence over the earlier removal issue")
        }
        XCTAssertEqual(report.operation.message, "This device keeps a recovery copy.")
      } catch { XCTFail("Unexpected original projection error: \(error)") }
    }
    guard await work.prompt(operation.finished, "original issue then normal completion fold") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(settings.state, .removalPending, "The report is not permission to publish current completion")
    XCTAssertEqual(settings.finishDeletingIssue, .waitingForConnection)
    await work.cleanUp()
  }

  @MainActor
  func testPureOriginalIssueFoldDoesNotReplayFailureAfterACoreRecoveryEvent() async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync)
    work.retain(settings)
    let operation = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { _ in
          XCTAssertEqual(settings.state, .syncing)
          settings.recordOutstandingSyncRecovered()
          XCTAssertEqual(settings.state, .ready)
          return .finished(.syncIssue(.waitingForConnection), .notRequired)
        }
        guard case .completed(let report) = outcome else { return XCTFail("Expected the original result-valued issue") }
        guard case .failed = report.operation.status else {
          return XCTFail("Current recovery must not rewrite the original issue as success")
        }
        XCTAssertEqual(report.operation.message, "Your changes will sync when you’re back online.")
      } catch { XCTFail("Unexpected original projection error: \(error)") }
    }
    guard await work.prompt(operation.finished, "historical issue projection after Core recovery event") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(settings.state, .ready, "Historical projection must not republish a global issue")
    XCTAssertTrue(settings.canSyncNow)
    await work.cleanUp()
  }

  @MainActor
  func testPureOriginalPriorIssueFoldDoesNotBorrowACoreRecoveryEventsSuccess() async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .failed(.waitingForConnection))
    work.retain(settings)
    let operation = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { _ in
          XCTAssertEqual(settings.state, .failed(.waitingForConnection))
          settings.recordOutstandingSyncRecovered()
          return .finished(.noChange, .notRequired)
        }
        guard case .completed(let report) = outcome else { return XCTFail("Expected the original unresolved action projection") }
        guard case .failed = report.operation.status else {
          return XCTFail("A later current recovery cannot settle this origin's fetch-only value")
        }
        XCTAssertEqual(report.operation.message, "Your changes will sync when you’re back online.")
      } catch { XCTFail("Unexpected original projection error: \(error)") }
    }
    guard await work.prompt(operation.finished, "original prior issue retained after separate Core event") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(settings.state, .ready)
    await work.cleanUp()
  }

  @MainActor
  func testPureOriginalRemovalCompletionCannotCompleteANewerCurrentRemoval() async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
    work.retain(settings)
    let operation = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { start in
          settings.recordRemovalCompleted(start)
          XCTAssertEqual(settings.state, .deleted)
          settings.recordRemovalPending()
          XCTAssertEqual(settings.state, .removalPending)
          return .finished(.noChange, .notRequired)
        }
        guard case .completed(let report) = outcome else { return XCTFail("Expected the original r1 completion projection") }
        guard case .succeeded = report.operation.status else {
          return XCTFail("Original normal completion still belongs to r1, not the current r2")
        }
        XCTAssertEqual(report.operation.message, "This device keeps a recovery copy.")
      } catch { XCTFail("Unexpected original projection error: \(error)") }
    }
    guard await work.prompt(operation.finished, "original removal identity fold") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(settings.state, .removalPending, "Original r1 report cannot complete current r2")
    XCTAssertTrue(settings.canFinishDeleting)
    XCTAssertNil(settings.finishDeletingIssue)
    await work.cleanUp()
  }

  @MainActor
  func testPureOriginalRemovalIssueCannotBorrowALaterCurrentCompletion() async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
    work.retain(settings)
    let operation = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { start in
          settings.recordRemovalCompleted(start)
          return .finished(.syncIssue(.waitingForConnection), .notRequired)
        }
        guard case .completed(let report) = outcome else { return XCTFail("Expected original incomplete removal report") }
        guard case .failed = report.operation.status else {
          return XCTFail("Current deletion completion cannot rewrite the original incomplete removal")
        }
        XCTAssertEqual(report.operation.message, "Some synced content is still in iCloud. This device keeps a recovery copy.")
      } catch { XCTFail("Unexpected original projection error: \(error)") }
    }
    guard await work.prompt(operation.finished, "original failed removal after independent Core completion") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(settings.state, .deleted)
    await work.cleanUp()
  }

  @MainActor
  func testOriginalRequiredFailureFoldRetainsTheErrorAndCannotProjectBackendSuccess() async {
    let work = OriginalOutcomeOwnership()
    let failure = OriginalOutcomeFailure()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, issueMapper: { _ in .attachmentMissing })
    work.retain(settings)
    let operation = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { _ in
          return .finished(.contentUpdated, .failed(failure))
        }
        guard case .completed(let report) = outcome else { return XCTFail("Expected the original required-failure report") }
        guard case .failed = report.operation.status else {
          return XCTFail("Required failure is not optional current-proof loss")
        }
        guard case .failed(let originalError) = report.requiredApplication else {
          return XCTFail("Retain the actual required failure separately from backend value")
        }
        XCTAssertTrue((originalError as AnyObject) === failure)
        XCTAssertEqual(report.operation.message, "Can’t read an attachment. Retry sync. If it still fails, contact support.")
      } catch { XCTFail("Unexpected original projection error: \(error)") }
    }
    guard await work.prompt(operation.finished, "raw required failure projection") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(settings.state, .syncing, "Raw failure projection is not a current-consumer publication")
    await work.cleanUp()
  }

  @MainActor
  func testOriginalContextRejectsALaterStatusSessionEvenForANormalRawReturn() async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync)
    work.retain(settings)
    let operation = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { _ in
          settings.recordSyncStopped(.iCloudAccountChanged)
          return .finished(.noChange, .notRequired)
        }
        guard case .interrupted = outcome else {
          return XCTFail("A stopped original status session cannot complete by reading later state")
        }
      } catch { XCTFail("Expected an interrupted original context: \(error)") }
    }
    guard await work.prompt(operation.finished, "original status-session interruption") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(settings.mode, .localOnly)
    XCTAssertEqual(settings.state, .failed(.iCloudAccountChanged))
    await work.cleanUp()
  }

  @MainActor
  private func checkOriginalProjection(
    initial: SyncedContentSettingsState, bodyState: SyncedContentSettingsState,
    returning raw: SyncedContentOriginalActionReturn, failed: Bool, message: String
  ) async {
    let work = OriginalOutcomeOwnership()
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: initial)
    work.retain(settings)
    var bodyCalls = 0
    let operation = work.start {
      do {
        let outcome = try await settings.performExplicitSyncWithOutcome { _ in
          bodyCalls += 1
          XCTAssertEqual(settings.state, bodyState)
          return raw
        }
        guard case .completed(let report) = outcome else { return XCTFail("Expected Core's original value projection") }
        switch report.operation.status {
        case .succeeded: XCTAssertFalse(failed, "This original value must retain failure")
        case .failed: XCTAssertTrue(failed, "This original value must retain success")
        }
        XCTAssertEqual(report.operation.message, message)
      } catch { XCTFail("Unexpected Core projection error: \(error)") }
    }
    guard await work.prompt(operation.finished, "pure original value/detail projection") else {
      await work.cleanUp(); return
    }
    XCTAssertEqual(bodyCalls, 1)
    XCTAssertEqual(settings.state, bodyState, "Pure original projection cannot replay current progress")
    await work.cleanUp()
  }
}
