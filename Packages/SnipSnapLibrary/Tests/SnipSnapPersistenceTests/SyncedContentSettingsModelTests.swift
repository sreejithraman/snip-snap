import SnipSnapCore
import XCTest

final class SyncedContentSettingsModelTests: XCTestCase {
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
      enableAction: { await calls.record("enable") }
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
  func testEncryptedResetShowsChoicesAndReplacesLibraryBeforeReportingReady() async {
    let calls = DeleteEventRecorder()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      encryptedDataResetAction: { choice in
        XCTAssertEqual(choice, .restoreFromThisDevice)
        await calls.record("resolve")
        return .resolved
      }
    )
    model.setEncryptedDataResetCompletionAction {
      XCTAssertEqual(model.state, .resolvingEncryptedDataReset)
      await calls.record("replace-library")
    }

    model.recordEncryptedDataReset()
    XCTAssertEqual(model.state, .encryptedDataReset)
    XCTAssertFalse(model.canDelete)
    XCTAssertTrue(model.detail.contains("read-only recovery copy"))

    await model.resolveEncryptedDataReset(.restoreFromThisDevice)

    let events = await calls.values()
    XCTAssertEqual(events, ["resolve", "replace-library"])
    XCTAssertEqual(model.mode, .iCloudSync)
    XCTAssertEqual(model.state, .ready)
  }

  @MainActor
  func testKeepingSyncOffLeavesTheAppLocalOnlyAfterLibraryReplacement() async {
    let calls = DeleteEventRecorder()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      enableAction: { await calls.record("enable") },
      encryptedDataResetAction: { choice in
        XCTAssertEqual(choice, .keepSyncOff)
        return .resolved
      }
    )
    model.setEncryptedDataResetCompletionAction {}
    model.recordEncryptedDataReset()

    await model.resolveEncryptedDataReset(.keepSyncOff)

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .ready)
    XCTAssertEqual(model.statusTitle, "Local Only")
    XCTAssertTrue(model.canEnable)

    await model.enableICloudSync()

    let events = await calls.values()
    XCTAssertEqual(events, ["enable"])
    XCTAssertEqual(model.mode, .iCloudSync)
  }

  @MainActor
  func testAResetDuringResolutionKeepsTheRecoveryChoicesVisible() async {
    let calls = DeleteEventRecorder()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      encryptedDataResetAction: { _ in .requiresChoice }
    )
    model.setEncryptedDataResetCompletionAction {
      await calls.record("replace-library")
    }
    model.recordEncryptedDataReset()

    await model.resolveEncryptedDataReset(.restoreFromThisDevice)

    let events = await calls.values()
    XCTAssertEqual(events, ["replace-library"])
    XCTAssertEqual(model.mode, .iCloudSync)
    XCTAssertEqual(model.state, .encryptedDataReset)
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
