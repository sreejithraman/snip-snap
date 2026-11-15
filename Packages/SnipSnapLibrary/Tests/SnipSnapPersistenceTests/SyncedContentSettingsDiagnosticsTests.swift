import Foundation
import SnipSnapCore
import Synchronization
import XCTest

final class SyncedContentSettingsDiagnosticsTests: XCTestCase {
  @MainActor
  func testIncompleteDeleteRecordsTheRetryIssueAndSuccessDoesNot() async {
    let events = Mutex<[AppDiagnosticEvent]>([])
    let recorder = AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    let complete = SyncedContentSettingsModel(
      mode: .iCloudSync, deleteAction: { .completed }, diagnostics: recorder
    )
    await complete.deleteSyncedContent()
    XCTAssertEqual(complete.state, .deleted)
    XCTAssertTrue(events.withLock { $0.isEmpty })

    let pending = SyncedContentSettingsModel(
      mode: .iCloudSync, deleteAction: { .removalPending }, diagnostics: recorder
    )
    await pending.deleteSyncedContent()

    XCTAssertEqual(pending.state, .removalPending)
    XCTAssertEqual(events.withLock { $0 }, [
      .failure(operation: "sync.delete", errorCode: "sync.someChangesPending", visibility: .user)
    ])
  }

  @MainActor
  func testRestoredSyncFailureRecordsTheVisibleIssueWithoutPrivateSetupDetails() {
    let events = Mutex<[AppDiagnosticEvent]>([])
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      initialState: .failed(.setupBlocked("private-file.txt")),
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )

    XCTAssertEqual(model.state, .failed(.setupBlocked("private-file.txt")))
    XCTAssertEqual(events.withLock { $0 }, [
      .failure(operation: "sync.run", errorCode: "sync.setupBlocked", visibility: .user)
    ])
    XCTAssertFalse(events.withLock { $0.map(\.line).joined().contains("private-file.txt") })
  }

  @MainActor
  func testLateSetupProgressAfterASyncStopRecordsNoSetupIssue() async {
    let events = Mutex<[AppDiagnosticEvent]>([])
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      enableAction: {
        await gate.wait()
        return .settingUp(.waitingForConnection)
      },
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )

    let enable = Task { @MainActor in await model.enableICloudSync() }
    await gate.waitUntilSuspended()
    model.recordSyncStopped(.iCloudAccountChanged)
    gate.open()
    await enable.value

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.iCloudAccountChanged))
    XCTAssertEqual(events.withLock { $0.map(\.operation) }, ["sync.stop"])
  }

  @MainActor
  func testLateEnableFailureAfterASyncStopKeepsTheStopAndRecordsTheFailure() async {
    struct Offline: Error {}
    let events = Mutex<[AppDiagnosticEvent]>([])
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      enableAction: {
        await gate.wait()
        throw Offline()
      },
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )

    let enable = Task { @MainActor in await model.enableICloudSync() }
    await gate.waitUntilSuspended()
    model.recordSyncStopped(.iCloudAccountChanged)
    gate.open()
    await enable.value

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.iCloudAccountChanged))
    XCTAssertEqual(events.withLock { $0.map(\.operation) }, ["sync.stop", "sync.enable"])
    XCTAssertEqual(events.withLock { $0.last?.outcome }, AppDiagnosticOutcome.failed)
  }

  @MainActor
  func testLateIncompleteDeleteAfterASyncStopRecordsNoPendingRemoval() async {
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
    await gate.waitUntilSuspended()
    model.recordSyncStopped(.signInRequired)
    gate.open()
    await delete.value

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.signInRequired))
    XCTAssertEqual(events.withLock { $0 }, [
      .failure(operation: "sync.stop", errorCode: "sync.signInRequired", visibility: .user)
    ])
  }

  @MainActor
  func testLateDisableFailureAfterASyncStopKeepsTheStopAndRecordsTheFailure() async {
    struct Offline: Error {}
    let events = Mutex<[AppDiagnosticEvent]>([])
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      disableAction: { _ in
        await gate.wait()
        throw Offline()
      },
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )

    let disable = Task { @MainActor in await model.disableICloudSync(.refreshThenCopy) }
    await gate.waitUntilSuspended()
    model.recordSyncStopped(.iCloudDataReset)
    gate.open()
    await disable.value

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.iCloudDataReset))
    XCTAssertEqual(events.withLock { $0.map(\.operation) }, ["sync.stop", "sync.disable"])
    XCTAssertEqual(events.withLock { $0.last?.outcome }, AppDiagnosticOutcome.failed)
  }

  @MainActor
  func testLateSetupCancelFailureAfterASyncStopKeepsTheStopAndRecordsTheFailure() async {
    struct Offline: Error {}
    let events = Mutex<[AppDiagnosticEvent]>([])
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      initialState: .enabling(),
      cancelEnableAction: {
        await gate.wait()
        throw Offline()
      },
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )

    let cancel = Task { @MainActor in await model.cancelICloudSyncSetup() }
    await gate.waitUntilSuspended()
    model.recordSyncStopped(.iCloudAccountChanged)
    gate.open()
    await cancel.value

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.iCloudAccountChanged))
    XCTAssertEqual(events.withLock { $0.map(\.operation) }, ["sync.stop", "sync.cancel_setup"])
    XCTAssertEqual(events.withLock { $0.last?.outcome }, AppDiagnosticOutcome.failed)
  }

  @MainActor
  func testLateDeleteFailureAfterASyncStopKeepsTheStopAndRecordsTheFailure() async {
    struct Offline: Error {}
    let events = Mutex<[AppDiagnosticEvent]>([])
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      deleteAction: {
        await gate.wait()
        throw Offline()
      },
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )

    let delete = Task { @MainActor in await model.deleteSyncedContent() }
    await gate.waitUntilSuspended()
    model.recordSyncStopped(.signInRequired)
    gate.open()
    await delete.value

    XCTAssertEqual(model.mode, .localOnly)
    XCTAssertEqual(model.state, .failed(.signInRequired))
    XCTAssertEqual(events.withLock { $0.map(\.operation) }, ["sync.stop", "sync.delete"])
    XCTAssertEqual(events.withLock { $0.last?.outcome }, AppDiagnosticOutcome.failed)
  }

  @MainActor
  func testFailedTryAgainInDeletionIncompleteRecordsTheIssue() async {
    let events = Mutex<[AppDiagnosticEvent]>([])
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      initialState: .removalPending,
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )
    events.withLock { $0.removeAll() }

    await model.performExplicitSync { model.recordSyncFailure(.waitingForConnection) }

    XCTAssertEqual(model.state, .removalPending)
    XCTAssertEqual(model.finishDeletingIssue, .waitingForConnection)
    XCTAssertEqual(events.withLock { $0 }, [
      .failure(operation: "sync.run", errorCode: "sync.waitingForConnection", visibility: .user)
    ])
  }

  @MainActor
  func testTryAgainThatLeavesDeletionIncompleteRecordsThePendingRemoval() async {
    let events = Mutex<[AppDiagnosticEvent]>([])
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      initialState: .removalPending,
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )
    events.withLock { $0.removeAll() }
    let inFlightStart = model.recordSyncStarted()

    await model.performExplicitSync { model.recordRemovalPending() }

    XCTAssertEqual(model.state, .removalPending)
    XCTAssertEqual(model.finishDeletingIssue, .someChangesPending)
    XCTAssertEqual(events.withLock { $0 }, [
      .failure(operation: "sync.delete", errorCode: "sync.someChangesPending", visibility: .user)
    ])
    // A sync that saw this removal can still finish it.
    model.recordSyncCompleted(inFlightStart)
    XCTAssertEqual(model.state, .deleted)
  }

  @MainActor
  func testSyncFailuresOutsideTryAgainInDeletionIncompleteRecordNothing() {
    let events = Mutex<[AppDiagnosticEvent]>([])
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      initialState: .removalPending,
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )
    events.withLock { $0.removeAll() }

    for _ in 0..<3 { model.recordSyncFailure(.waitingForConnection) }

    XCTAssertEqual(model.state, .removalPending)
    XCTAssertNil(model.finishDeletingIssue)
    XCTAssertTrue(events.withLock { $0.isEmpty })
  }

  @MainActor
  func testPendingRemovalReportsOutsideTryAgainRecordNothing() {
    let events = Mutex<[AppDiagnosticEvent]>([])
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      initialState: .removalPending,
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )
    events.withLock { $0.removeAll() }

    for _ in 0..<3 { model.recordRemovalPending() }

    XCTAssertEqual(model.state, .removalPending)
    XCTAssertNil(model.finishDeletingIssue)
    XCTAssertTrue(events.withLock { $0.isEmpty })
  }

  @MainActor
  func testNextTryAgainClearsTheFailedTryAgainIssueWhenItStarts() async {
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      initialState: .removalPending,
      diagnostics: AppDiagnosticRecorder { _ in }
    )
    await model.performExplicitSync { model.recordSyncFailure(.waitingForConnection) }
    XCTAssertEqual(model.finishDeletingIssue, .waitingForConnection)

    await model.performExplicitSync {
      XCTAssertNil(model.finishDeletingIssue)
      model.recordRemovalPending()
    }

    XCTAssertEqual(model.finishDeletingIssue, .someChangesPending)
  }

  @MainActor
  func testTryAgainThatFinishesDeletingClearsTheIssueAndRecordsNothing() async {
    let events = Mutex<[AppDiagnosticEvent]>([])
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      initialState: .removalPending,
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )
    await model.performExplicitSync { model.recordSyncFailure(.waitingForConnection) }
    XCTAssertEqual(model.finishDeletingIssue, .waitingForConnection)
    events.withLock { $0.removeAll() }

    await model.performExplicitSync {
      let start = model.recordSyncStarted()
      model.recordSyncCompleted(start)
    }

    XCTAssertEqual(model.state, .deleted)
    XCTAssertNil(model.finishDeletingIssue)
    XCTAssertTrue(events.withLock { $0.isEmpty })
  }

  @MainActor
  func testDroppedTryAgainLeavesTheRunningTryAgainIssue() async {
    let gate = SyncedContentActionGate()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      initialState: .removalPending,
      diagnostics: AppDiagnosticRecorder { _ in }
    )
    let running = Task { @MainActor in
      await model.performExplicitSync {
        model.recordSyncFailure(.waitingForConnection)
        await gate.wait()
      }
    }
    await gate.waitUntilSuspended()

    var droppedRan = false
    await model.performExplicitSync { droppedRan = true }

    XCTAssertFalse(droppedRan)
    XCTAssertEqual(model.finishDeletingIssue, .waitingForConnection)
    gate.open()
    await running.value
    XCTAssertEqual(model.finishDeletingIssue, .waitingForConnection)
  }
}
