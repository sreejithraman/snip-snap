import SnipSnapCore
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
      "Sync will retry the deletion. This device keeps a recovery copy."
    )
    XCTAssertFalse(model.canDelete)
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

    model.recordSyncStarted()
    XCTAssertEqual(model.state, .syncing)
    XCTAssertEqual(model.statusTitle, "Syncing with iCloud…")

    model.recordSyncFailure(.iCloudUnavailable)
    XCTAssertEqual(model.state, .failed(.iCloudUnavailable))
    XCTAssertEqual(model.statusTitle, "iCloud unavailable")
    XCTAssertEqual(
      model.detail,
      "iCloud isn’t available right now. Sync will try again."
    )

    model.recordSyncStarted()
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .ready)
  }

  @MainActor
  func testOnlyASettledSyncClearsAnOutstandingIssue() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    model.recordSyncStarted()
    model.recordSyncCompleted()
    XCTAssertEqual(model.state, .ready)

    model.recordSyncFailure(.iCloudUnavailable)
    model.recordSyncStarted()
    XCTAssertEqual(model.state, .failed(.iCloudUnavailable))
    model.recordSyncCompleted()
    XCTAssertEqual(model.state, .failed(.iCloudUnavailable))
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .ready)

    model.recordSyncFailure(.iCloudStorageFull)
    model.recordSyncCompleted()
    XCTAssertEqual(model.state, .failed(.iCloudStorageFull))
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .ready)

    model.recordRemovalPending(true)
    model.recordSyncCompleted()
    XCTAssertEqual(model.state, .removalPending)
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .removalPending)

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
