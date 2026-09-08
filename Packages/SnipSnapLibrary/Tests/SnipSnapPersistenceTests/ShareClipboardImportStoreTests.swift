import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import XCTest

final class ShareClipboardImportStoreTests: XCTestCase {
  func testRichTextRoundTripsWithoutChangingPlainText() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ShareClipboardImportStore(sharedRootURL: root)
    let request = ShareImportRequest(content: "Bold", destinationListID: SnipList.inboxID)
    let richText = ClipboardRepresentation(type: "public.rtf", data: Data("{\\rtf1\\b Bold}".utf8))
    _ = try await store.save(request, richTextRepresentations: [richText])
    let summary = await store.importPendingWithRepresentations { imported, urls, representations in
      XCTAssertEqual(imported.content, "Bold")
      XCTAssertTrue(urls.isEmpty)
      XCTAssertEqual(representations, [richText])
    }
    XCTAssertEqual(summary, ShareImportSummary(imported: 1, failed: 0))
  }

  func testReadsRequestQueuedBeforeRichTextEnvelope() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = ShareImportRequest(content: "Existing queue", destinationListID: SnipList.inboxID)
    let ready = root.appendingPathComponent("Share/ClipboardImports/\(request.requestID.uuidString).ready")
    try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
    try JSONEncoder().encode(request).write(to: ready.appendingPathComponent("clipboard.json"))
    let summary = await ShareClipboardImportStore(sharedRootURL: root).importPendingWithRepresentations {
      imported, _, representations in
      XCTAssertEqual(imported, request)
      XCTAssertTrue(representations.isEmpty)
    }
    XCTAssertEqual(summary, ShareImportSummary(imported: 1, failed: 0))
  }

  func testClipboardQueueStaysSeparateFromSnipsAndImportsAcrossRelaunch() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = ShareImportRequest(content: "https://example.com", destinationListID: SnipList.inboxID)
    let store = ShareClipboardImportStore(sharedRootURL: root)
    _ = try await store.save(request)
    let savedSnipCount = await ShareImportStore(sharedRootURL: root).pendingImportCount()
    XCTAssertEqual(savedSnipCount, 0)

    let reopened = ShareClipboardImportStore(sharedRootURL: root)
    let summary = await reopened.importPending { imported, urls in
      XCTAssertEqual(imported, request)
      XCTAssertTrue(urls.isEmpty)
    }
    XCTAssertEqual(summary, ShareImportSummary(imported: 1, failed: 0))
    let pending = await reopened.pendingImportCount()
    XCTAssertEqual(pending, 0)
  }

  func testFailedImportKeepsFilesAndStableRequestForRetry() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    let bytes = Data("Keep this file".utf8)
    try bytes.write(to: source)
    let staging = try ShareImportStagingArea(sharedRootURL: root)
    let attachment = try staging.copyProviderFile(at: source, contentType: "public.plain-text")
    let request = ShareImportRequest(
      content: "", destinationListID: SnipList.inboxID,
      attachments: [attachment], requestID: staging.requestID
    )
    let store = ShareClipboardImportStore(sharedRootURL: root)
    _ = try await store.save(request)
    try FileManager.default.removeItem(at: source)
    let first = await store.importPending { imported, urls in
      XCTAssertEqual(imported.requestID, request.requestID)
      XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), bytes)
      throw CocoaError(.fileWriteOutOfSpace)
    }
    XCTAssertEqual(first, ShareImportSummary(imported: 0, failed: 1))
    let pending = await store.pendingImportCount()
    XCTAssertEqual(pending, 1)
    let destination = root.appendingPathComponent("owned.txt")
    let retried = await store.importPending { imported, urls in
      XCTAssertEqual(imported.requestID, request.requestID)
      try FileManager.default.copyItem(at: XCTUnwrap(urls.first), to: destination)
    }
    XCTAssertEqual(retried, ShareImportSummary(imported: 1, failed: 0))
    XCTAssertEqual(try Data(contentsOf: destination), bytes)
  }

  func testRejectsFilePathOutsideStaging() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ShareClipboardImportStore(sharedRootURL: root)
    let request = ShareImportRequest(
      content: "", destinationListID: SnipList.inboxID,
      attachments: [ShareImportAttachment(fileName: "secret", contentType: nil,
        byteCount: 1, relativePath: "../../outside.txt")]
    )
    do {
      _ = try await store.save(request)
      XCTFail("An attachment outside intake must not publish")
    } catch {
      XCTAssertEqual(error as? ShareImportError, .invalidStaging)
    }
    let pending = await store.pendingImportCount()
    XCTAssertEqual(pending, 0)
  }

  func testRepeatedSavePublishesOneRequest() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ShareClipboardImportStore(sharedRootURL: root)
    let request = ShareImportRequest(content: "Once", destinationListID: SnipList.inboxID)
    _ = try await store.save(request)
    _ = try await store.save(request)
    let pending = await store.pendingImportCount()
    XCTAssertEqual(pending, 1)
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
