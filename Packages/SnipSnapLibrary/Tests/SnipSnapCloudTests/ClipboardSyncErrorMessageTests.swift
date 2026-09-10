import CloudKit
@testable import SnipSnapCloud
import XCTest

final class ClipboardSyncErrorMessageTests: XCTestCase {
  func testSyncMessagesMapCloudKitIssuesWithoutRawDetails() {
    XCTAssertEqual(
      ClipboardSyncErrorMessage.sync(for: CKError(.networkUnavailable)),
      "Snip Snap couldn’t sync clipboard history. Check your connection, then try again."
    )
    XCTAssertEqual(
      ClipboardSyncErrorMessage.sync(for: CKError(.quotaExceeded)),
      "Snip Snap couldn’t sync clipboard history. iCloud storage is full. Free up space, then try again."
    )
    XCTAssertEqual(
      ClipboardSyncErrorMessage.sync(for: CKError(.notAuthenticated)),
      "Snip Snap couldn’t sync clipboard history. Snip Snap can’t check your iCloud account. Try again."
    )
  }

  func testFallbackDoesNotExposeRawNSErrorDetails() {
    let error = NSError(
      domain: "ClipboardCloudKit",
      code: 41,
      userInfo: [NSLocalizedDescriptionKey: "Private file path /secret"]
    )

    let message = ClipboardSyncErrorMessage.sync(for: error)

    XCTAssertEqual(
      message,
      "Snip Snap couldn’t sync clipboard history. Try again. If this keeps happening, check for an update or contact support."
    )
    XCTAssertFalse(message.contains("/secret"))
  }

  func testClipboardCloudErrorsKeepTheirSpecificReasons() {
    XCTAssertEqual(
      ClipboardSyncErrorMessage.sync(for: ClipboardCloudError.busy),
      "Snip Snap couldn’t sync clipboard history. Clipboard history is already syncing."
    )
    XCTAssertEqual(
      ClipboardSyncErrorMessage.sync(for: ClipboardCloudError.payloadTooLarge),
      "Snip Snap couldn’t sync clipboard history. Snip Snap can’t sync a clipboard entry larger than 32 MB."
    )
  }

  func testDeleteMessageKeepsTheOperationAndMappedReason() {
    XCTAssertEqual(
      ClipboardSyncErrorMessage.deleteSyncedHistory(for: CKError(.quotaExceeded)),
      "Snip Snap couldn’t delete synced clipboard history. iCloud storage is full. Free up space, then try again."
    )
  }
}
