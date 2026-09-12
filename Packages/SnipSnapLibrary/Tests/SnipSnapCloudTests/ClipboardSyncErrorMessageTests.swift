import CloudKit
@testable import SnipSnapCloud
import XCTest

final class ClipboardSyncErrorMessageTests: XCTestCase {
  func testSyncMessagesMapCloudKitIssuesWithoutRawDetails() {
    XCTAssertEqual(
      ClipboardSyncErrorMessage.sync(for: CKError(.networkUnavailable)),
      "Couldn’t sync clipboard history. Check your connection, then try again."
    )
    XCTAssertEqual(
      ClipboardSyncErrorMessage.sync(for: CKError(.quotaExceeded)),
      "Couldn’t sync clipboard history. iCloud storage is full. Free up space, then try again."
    )
    XCTAssertEqual(
      ClipboardSyncErrorMessage.sync(for: CKError(.notAuthenticated)),
      "Couldn’t sync clipboard history. Can’t check your iCloud account. Try again later."
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
      "Couldn’t sync clipboard history. Try again. If it still fails, update Snip Snap or contact support."
    )
    XCTAssertFalse(message.contains("/secret"))
  }

  func testClipboardCloudErrorsKeepTheirSpecificReasons() {
    XCTAssertEqual(
      ClipboardSyncErrorMessage.sync(for: ClipboardCloudError.busy),
      "Couldn’t sync clipboard history. Wait for sync to finish."
    )
    XCTAssertEqual(
      ClipboardSyncErrorMessage.sync(for: ClipboardCloudError.payloadTooLarge),
      "Couldn’t sync clipboard history. Clipboard entries over 32 MB can’t sync. Contact support for help."
    )
  }

  func testDeleteMessageKeepsTheOperationAndMappedReason() {
    XCTAssertEqual(
      ClipboardSyncErrorMessage.deleteSyncedHistory(for: CKError(.quotaExceeded)),
      "Couldn’t delete synced clipboard history. iCloud storage is full. Free up space, then try again."
    )
  }
}
