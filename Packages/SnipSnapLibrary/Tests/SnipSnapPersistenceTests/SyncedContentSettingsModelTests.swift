import SnipSnapCore
import Synchronization
import XCTest

final class SyncedContentSettingsModelTests: XCTestCase {
  @MainActor
  func testStatusTitleNamesEachModeAndIssue() {
    let cases: [(SyncedContentMode, SyncedContentSyncIssue?, String)] = [
      (.localOnly, nil, "Sync off"),
      (.iCloudSync, nil, "Sync on"),
      (.iCloudSync, .waitingForConnection, "Waiting for connection"),
      (.iCloudSync, .iCloudStorageFull, "iCloud storage full"),
      (.iCloudSync, .updateRequired, "Update Snip Snap"),
      (.iCloudSync, .appDataIssue, "Couldn’t sync"),
      (.iCloudSync, .attachmentStorageUnavailable, "Couldn’t save an attachment"),
    ]
    for (mode, issue, title) in cases {
      let model = SyncedContentSettingsModel(mode: mode)
      if let issue { model.recordSyncFailure(issue) }
      XCTAssertEqual(model.statusTitle, title, "\(mode) \(String(describing: issue))")
    }
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
    var completionRan = false
    model.setDisableCompletionAction {
      completionRan = true
      XCTAssertFalse(model.canSyncNow)
    }
    await model.disableICloudSync(.useCurrentCache)
    XCTAssertTrue(completionRan)
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

    _ = model.recordSyncStarted()
    XCTAssertTrue(model.canEnableClipboardSync)
    model.recordSyncCompleted()
    var completionRan = false
    model.setDisableCompletionAction {
      completionRan = true
      XCTAssertEqual(model.mode, .iCloudSync)
      XCTAssertFalse(model.canEnableClipboardSync)
    }
    await model.disableICloudSync(.useCurrentCache)
    XCTAssertTrue(completionRan)
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

    _ = model.recordSyncStarted()
    model.recordSyncCompleted()
    XCTAssertEqual(model.state, .ready)

    model.recordSyncFailure(.iCloudUnavailable)
    _ = model.recordSyncStarted()
    XCTAssertEqual(model.state, .failed(.iCloudUnavailable))
    model.recordSyncCompleted()
    XCTAssertEqual(model.state, .failed(.iCloudUnavailable))
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .ready)

    _ = model.recordSyncStarted()
    model.recordSyncFailure(.iCloudStorageFull)
    model.recordSyncCompleted()
    XCTAssertEqual(model.state, .failed(.iCloudStorageFull))
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .ready)

    model.recordSyncStopped(.iCloudDataReset)
    model.recordOutstandingSyncRecovered()
    XCTAssertEqual(model.state, .failed(.iCloudDataReset))
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
    XCTAssertTrue(model.detail.contains("your library is kept on this device"))

    model.recordSyncStopped(.iCloudAccountChanged)
    XCTAssertEqual(model.statusTitle, "iCloud account changed")
    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertTrue(model.detail.contains("your snips are kept on this device"))
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
}

/// Suspends a Synced Content action until the test opens it.
@MainActor
final class SyncedContentActionGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  /// Fails the test, instead of hanging it, if the action doesn't reach `wait()` in time.
  func waitUntilSuspended(file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while continuation == nil {
      guard ContinuousClock.now < deadline else {
        return XCTFail("The action never reached the gate", file: file, line: line)
      }
      await Task.yield()
    }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}

private actor DeleteEventRecorder {
  private var events: [String] = []
  func record(_ event: String) { events.append(event) }
  func values() -> [String] { events }
}
