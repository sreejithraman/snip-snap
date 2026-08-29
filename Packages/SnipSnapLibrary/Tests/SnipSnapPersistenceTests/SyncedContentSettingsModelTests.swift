import SnipSnapCore
import XCTest

final class SyncedContentSettingsModelTests: XCTestCase {
  @MainActor
  func testConfirmedDeleteReportsProgressAndExplainsTheRemainingControlRecord() async {
    let calls = DeleteCallCounter()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      deleteAction: { await calls.record() }
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
      deleteAction: { await calls.record("delete") }
    )
    model.setDeleteCompletionAction {
      await calls.record("replace-library")
    }

    await model.deleteSyncedContent()

    let events = await calls.values()
    XCTAssertEqual(events, ["delete", "replace-library"])
    XCTAssertEqual(model.state, .deleted)
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
