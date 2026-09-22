import CloudKit
import Foundation
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapCore
@testable import SnipSnapPersistence

final class CloudSyncDiagnosticsTests: XCTestCase {
  func testAttachmentErrorCodeClassifiesKnownFailuresWithoutErrorDescriptions() {
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(CKError(.assetNotAvailable)),
      "cloudkit.\(CKError.Code.assetNotAvailable.rawValue)"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(CloudAttachmentStorageError.hashMismatch),
      "storage.hashMismatch"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(
        CloudAttachmentStorageError.symbolicLinkDescendant
      ),
      "storage.symbolicLinkDescendant"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(CloudRecordError.missingAsset),
      "record.missingAsset"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(CloudTransportError.fetchFailed),
      "transport.fetchFailed"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(CocoaError(.fileReadNoSuchFile)),
      "cocoa.\(CocoaError.Code.fileReadNoSuchFile.rawValue)"
    )
  }

  func testAttachmentErrorCodeDoesNotIncludeUnknownErrorDescription() {
    struct PrivateFailure: LocalizedError {
      let errorDescription: String? = "private file name and path"
    }

    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(PrivateFailure()),
      "other.PrivateFailure"
    )
  }

  func testAttachmentErrorCodeClassifiesSnipLibraryFailures() {
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(SnipLibraryError.storeUnavailable),
      "library.storeUnavailable"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(SnipLibraryError.invalidStore),
      "library.invalidStore"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(SnipLibraryError.attachmentCopyFailed),
      "library.attachmentCopyFailed"
    )
  }

}
