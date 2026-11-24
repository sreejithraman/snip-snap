import Foundation
import SnipSnapCore
import Synchronization
import XCTest

final class SyncedContentSettingsDiagnosticsTests: XCTestCase {
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
}
