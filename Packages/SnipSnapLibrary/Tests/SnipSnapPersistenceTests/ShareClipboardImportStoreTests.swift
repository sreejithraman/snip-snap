import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import XCTest

final class ShareClipboardImportStoreTests: XCTestCase {
  func testRichTextRoundTripsWithoutChangingPlainText() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = ShareImportRequest(content: "Bold", destinationListID: SnipList.inboxID)
    let richText = ClipboardRepresentation(type: "public.rtf", data: Data("{\\rtf1\\b Bold}".utf8))
    try queueClipboardRequest(request, richText: [richText], in: root)

    let summary = await ShareClipboardImportStore(sharedRootURL: root)
      .importPendingWithRepresentations { imported, urls, representations in
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
    let ready = root.appendingPathComponent(
      "Share/ClipboardImports/\(request.requestID.uuidString).ready"
    )
    try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
    try JSONEncoder().encode(request).write(to: ready.appendingPathComponent("clipboard.json"))

    let summary = await ShareClipboardImportStore(sharedRootURL: root)
      .importPendingWithRepresentations { imported, _, representations in
        XCTAssertEqual(imported, request)
        XCTAssertTrue(representations.isEmpty)
      }

    XCTAssertEqual(summary, ShareImportSummary(imported: 1, failed: 0))
  }

  func testClipboardQueueStaysSeparateFromSnipsAndImportsAcrossRelaunch() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = ShareImportRequest(
      content: "https://example.com",
      destinationListID: SnipList.inboxID
    )
    try queueClipboardRequest(request, in: root)
    let savedSnipCount = await ShareImportStore(sharedRootURL: root).pendingImportCount()
    XCTAssertEqual(savedSnipCount, 0)

    let reopened = ShareClipboardImportStore(sharedRootURL: root)
    let summary = await reopened.importPendingWithRepresentations { imported, urls, _ in
      XCTAssertEqual(imported.content, request.content)
      XCTAssertEqual(imported.requestID, request.requestID)
      XCTAssertTrue(urls.isEmpty)
    }
    XCTAssertEqual(summary, ShareImportSummary(imported: 1, failed: 0))
    let pending = await reopened.pendingImportCount()
    XCTAssertEqual(pending, 0)
  }

  func testFailedImportKeepsFilesAndStableRequestForRetry() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("Keep this file".utf8)
    let relativePath = "Files/\(UUID().uuidString)/source.txt"
    let request = ShareImportRequest(
      content: "",
      destinationListID: SnipList.inboxID,
      attachments: [
        ShareImportAttachment(
          fileName: "source.txt",
          contentType: "public.plain-text",
          byteCount: Int64(bytes.count),
          relativePath: relativePath
        )
      ]
    )
    try queueClipboardRequest(request, in: root, files: [(relativePath, bytes)])

    let store = ShareClipboardImportStore(sharedRootURL: root)
    let first = await store.importPendingWithRepresentations { imported, urls, _ in
      XCTAssertEqual(imported.requestID, request.requestID)
      XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), bytes)
      throw CocoaError(.fileWriteOutOfSpace)
    }
    XCTAssertEqual(first, ShareImportSummary(imported: 0, failed: 1))
    let pending = await store.pendingImportCount()
    XCTAssertEqual(pending, 1)
    let destination = root.appendingPathComponent("owned.txt")
    let retried = await store.importPendingWithRepresentations { imported, urls, _ in
      XCTAssertEqual(imported.requestID, request.requestID)
      try FileManager.default.copyItem(at: XCTUnwrap(urls.first), to: destination)
    }
    XCTAssertEqual(retried, ShareImportSummary(imported: 1, failed: 0))
    XCTAssertEqual(try Data(contentsOf: destination), bytes)
  }

  func testDrainRejectsFilePathOutsideStaging() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = ShareImportRequest(
      content: "",
      destinationListID: SnipList.inboxID,
      attachments: [
        ShareImportAttachment(
          fileName: "secret",
          contentType: nil,
          byteCount: 1,
          relativePath: "../../outside.txt"
        )
      ]
    )
    try queueClipboardRequest(request, in: root)

    let summary = await ShareClipboardImportStore(sharedRootURL: root)
      .importPendingWithRepresentations { _, _, _ in
        XCTFail("A path outside the queue must not be delivered.")
      }

    XCTAssertEqual(summary, ShareImportSummary(imported: 0, failed: 1))
    let pending = await ShareClipboardImportStore(sharedRootURL: root).pendingImportCount()
    XCTAssertEqual(pending, 1)
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func queueClipboardRequest(
    _ request: ShareImportRequest,
    richText: [ClipboardRepresentation] = [],
    in root: URL,
    files: [(relativePath: String, data: Data)] = []
  ) throws {
    let ready = root.appendingPathComponent(
      "Share/ClipboardImports/\(request.requestID.uuidString).ready",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
    for file in files {
      let url = ready.appendingPathComponent(file.relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try file.data.write(to: url)
    }
    let envelope = ClipboardShareEnvelope(
      request: request,
      richTextRepresentations: richText
    )
    try JSONEncoder().encode(envelope).write(to: ready.appendingPathComponent("clipboard.json"))
  }
}

private struct ClipboardShareEnvelope: Codable {
  let request: ShareImportRequest
  let richTextRepresentations: [ClipboardRepresentation]
}
