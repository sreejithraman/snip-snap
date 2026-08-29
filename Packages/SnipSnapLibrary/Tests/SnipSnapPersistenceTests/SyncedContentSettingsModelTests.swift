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
}

private actor DeleteCallCounter {
  private var count = 0
  func record() { count += 1 }
  func value() -> Int { count }
}
