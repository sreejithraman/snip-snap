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
}
