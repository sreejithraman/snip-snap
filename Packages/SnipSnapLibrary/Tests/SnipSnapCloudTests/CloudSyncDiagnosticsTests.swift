import CloudKit
import Foundation
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapCore
@testable import SnipSnapPersistence

final class CloudSyncDiagnosticsTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
      try FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

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

  func testAttachmentEventContainsOnlyStableDiagnosticFields() {
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentEvent(
        stage: .assetCopy,
        outcome: "failed",
        errorCode: "cocoa.4"
      ),
      "attachment_download stage=asset_copy outcome=failed error=cocoa.4"
    )
  }

  func testDiagnosticStoreExportsVersionedPrivacySafeEvents() throws {
    let store = CloudDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1.2.3",
      appBuild: "42"
    )
    store.append(
      "attachment_download stage=asset_copy outcome=failed error=cocoa.4",
      at: Date(timeIntervalSince1970: 0)
    )

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertTrue(export.contains("format=1 app_version=1.2.3 app_build=42"))
    XCTAssertTrue(export.contains("1970-01-01T00:00:00"))
    XCTAssertTrue(export.contains("stage=asset_copy outcome=failed error=cocoa.4"))
  }

  func testDiagnosticStoreDropsOldestWholeEventsAtSizeLimit() throws {
    let store = CloudDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 190,
      appVersion: "1",
      appBuild: "2"
    )
    store.append("attachment_download stage=remote_fetch outcome=started marker=old")
    store.append("attachment_download stage=remote_fetch outcome=failed marker=new")

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertFalse(export.contains("marker=old"))
    XCTAssertTrue(export.contains("marker=new"))
    XCTAssertLessThanOrEqual(export.utf8.count, 190)
  }

  func testDiagnosticStoreCanBeCleared() throws {
    let store = CloudDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1",
      appBuild: "2"
    )
    store.append("attachment_download stage=remote_fetch outcome=started")
    _ = try store.makeShareableFile()

    try store.clear()
    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertFalse(export.contains("attachment_download"))
  }

  func testDiagnosticStoreWritesOneHeaderAcrossMultipleEvents() throws {
    let store = CloudDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1",
      appBuild: "2"
    )
    store.append("attachment_download stage=remote_fetch outcome=started")
    store.append("attachment_download stage=remote_fetch outcome=succeeded bytes=12")

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertEqual(export.components(separatedBy: "Snip Snap diagnostics").count - 1, 1)
    XCTAssertEqual(export.components(separatedBy: "privacy=attachment-stage-events-only").count - 1, 1)
    XCTAssertEqual(export.components(separatedBy: "attachment_download").count - 1, 2)
  }

  func testDiagnosticStoreRepairsRepeatedLegacyHeadersOnAppend() throws {
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    let eventsURL = temporaryDirectory.appendingPathComponent("attachment-events.txt")
    try """
      Snip Snap diagnostics
      format=1 app_version=0.5.1 app_build=84
      privacy=attachment-stage-events-only
      Snip Snap diagnostics
      format=1 app_version=0.5.1 app_build=84
      privacy=attachment-stage-events-only
      2026-09-21T19:43:28Z attachment_download stage=cache_install outcome=failed error=other.SnipLibraryError
      """.write(to: eventsURL, atomically: true, encoding: .utf8)
    let store = CloudDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "0.5.1",
      appBuild: "85"
    )

    store.append("attachment_download stage=remote_fetch outcome=started")
    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertEqual(export.components(separatedBy: "Snip Snap diagnostics").count - 1, 1)
    XCTAssertTrue(export.contains("stage=cache_install outcome=failed"))
    XCTAssertTrue(export.contains("stage=remote_fetch outcome=started"))
  }
}
