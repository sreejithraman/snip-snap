import SnipSnapCore
import XCTest

final class SyncedContentSettingsModelTests: XCTestCase {
  @MainActor
  func testLocalOnlyCopyNamesTheCloudKitBoundaryWithoutClaimingDeviceOnlyStorage() {
    let model = SyncedContentSettingsModel(mode: .localOnly)

    XCTAssertEqual(
      model.detail,
      "Snip Snap does not send local-only data to CloudKit."
    )
    XCTAssertFalse(model.detail.contains("stay on this device"))
    XCTAssertFalse(model.detail.contains("Nothing is uploaded"))
  }

  @MainActor
  func testICloudReadyDetailStatesThePrivacyBoundaryWithoutOverclaimingEncryption() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    XCTAssertTrue(model.detail.contains("private iCloud database"))
    XCTAssertTrue(model.detail.contains("cannot inspect private records in CloudKit Console"))
    XCTAssertTrue(model.detail.contains("encrypts synced data in transit and at rest"))
    XCTAssertTrue(model.detail.contains("encrypted values and files use CKAsset data"))
    XCTAssertTrue(
      model.detail.contains(
        "Those user fields and attachments are end-to-end encrypted only when Advanced Data Protection is on"
      )
    )
  }

  @MainActor
  func testConfirmedDeleteReportsProgressAndExplainsTheRemainingControlRecord() async {
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
    XCTAssertTrue(model.detail.contains("local recovery copy"))
    XCTAssertTrue(model.detail.contains("control record"))
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
    XCTAssertEqual(model.statusTitle, "Old Synced Content Removal Pending")
    XCTAssertEqual(
      model.detail,
      "Snip Snap started a fresh empty synced collection, but it could not remove all old iCloud data yet. It will retry the next time it syncs. Your local recovery copy remains."
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
    XCTAssertEqual(model.statusTitle, "Setting Up iCloud Sync…")
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
    XCTAssertEqual(model.statusTitle, "iCloud Is Unavailable")
    XCTAssertEqual(
      model.detail,
      "Snip Snap can’t reach iCloud right now. Your changes are safe on this device, and sync will try again."
    )

    model.recordSyncStarted()
    model.recordSyncCompleted()
    XCTAssertEqual(model.state, .ready)
  }

  @MainActor
  func testOnlyASettledRetryClearsAnOutstandingIssue() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    model.recordSyncFailure(.iCloudUnavailable)
    model.recordSyncCompleted()
    XCTAssertEqual(model.state, .failed(.iCloudUnavailable))
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .ready)

    model.recordSyncFailure(.iCloudStorageFull)
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .ready)
  }

  @MainActor
  func testRetryingAndUserActionFailuresHaveDifferentStatusMessages() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    model.recordSyncFailure(.waitingForConnection)
    XCTAssertEqual(model.statusTitle, "Waiting for a Connection")
    XCTAssertTrue(model.detail.contains("will sync when you’re back online"))

    model.recordSyncFailure(.iCloudStorageFull)
    XCTAssertEqual(model.statusTitle, "iCloud Storage Is Full")
    XCTAssertTrue(model.detail.contains("Free up some iCloud storage"))

    model.recordSyncFailure(.updateRequired)
    XCTAssertEqual(model.statusTitle, "Update Snip Snap to Sync")
    XCTAssertTrue(model.detail.contains("Update Snip Snap"))
  }

  @MainActor
  func testInternalSyncFailureDoesNotShowRawErrorDetails() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    model.recordSyncFailure(.appDataIssue)

    XCTAssertEqual(model.statusTitle, "Snip Snap Couldn’t Sync")
    XCTAssertFalse(model.detail.contains("CloudRecordError"))
    XCTAssertFalse(model.detail.contains("error 2"))
    XCTAssertTrue(model.detail.contains("Your changes are safe on this device"))
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
    XCTAssertEqual(model.statusTitle, "Local Only")
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
    XCTAssertEqual(model.statusTitle, "iCloud Is Unavailable")
    XCTAssertTrue(model.detail.contains("sync will try again"))
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

    XCTAssertEqual(model.statusTitle, "iCloud Sync Setup Stopped")
    XCTAssertTrue(model.detail.contains("could not finish setting up iCloud Sync"))
    XCTAssertTrue(model.detail.contains("local library remains available"))
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
    XCTAssertEqual(model.statusTitle, "iCloud Sync Was Turned Off")
    XCTAssertTrue(model.detail.contains("will not upload it again"))

    model.recordSyncStopped(.iCloudAccountChanged)
    XCTAssertEqual(model.statusTitle, "iCloud Account Changed")
    XCTAssertTrue(model.detail.contains("separate local library"))
  }

  @MainActor
  func testAttachmentStorageFailureExplainsTheLocalProblem() {
    let model = SyncedContentSettingsModel(mode: .iCloudSync)

    model.recordSyncFailure(.attachmentStorageUnavailable)

    XCTAssertEqual(model.statusTitle, "An Attachment Couldn’t Be Saved")
    XCTAssertTrue(model.detail.contains("safe place"))
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
