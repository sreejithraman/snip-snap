import Foundation
import SnipSnapCore
import XCTest
@testable import SnipSnapPersistence

final class BackupExportTests: XCTestCase {
  func testBackupKeepsEarlierAttachmentsWhenLaterDownloadsEvictThem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupExport-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let bytes = [Data("first attachment".utf8), Data("second attachment".utf8)]
    let attachments = bytes.enumerated().map { index, data in
      SnipAttachment(id: UUID(), fileName: "\(index).txt", relativePath: "\(index).txt", contentType: "public.text", byteCount: Int64(data.count))
    }
    let archive = SnipLibraryArchive(snips: [Snip(content: "Complete backup", origin: .quickEntry, attachments: attachments)], lists: [.inbox], seenRequestIDs: [], attachmentURLs: [:])
    let cache = EvictingBackupCache(root: root, attachments: attachments, bytes: bytes)
    let backup = root.appendingPathComponent("Backup")
    try await JSONSnipArchiveTransfer.write(archive, to: backup) { try await cache.prepare($0) }
    let restored = try JSONSnipArchiveTransfer.read(from: backup)
    for (index, attachment) in attachments.enumerated() {
      XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.attachmentURLs[attachment.id])), bytes[index])
    }
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".Backup.") })
  }

  func testFailedOrCancelledDownloadLeavesNoPartialBackup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupExportFailure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let attachment = SnipAttachment(id: UUID(), fileName: "file.txt", relativePath: "file.txt", contentType: "public.text", byteCount: 4)
    let archive = SnipLibraryArchive(snips: [Snip(content: "Required file", origin: .quickEntry, attachments: [attachment])], lists: [.inbox], seenRequestIDs: [], attachmentURLs: [:])
    for cancelled in [false, true] {
      do {
        try await JSONSnipArchiveTransfer.write(archive, to: root.appendingPathComponent("Backup")) { _ in
          if cancelled { throw CancellationError() }
          throw SnipLibraryError.attachmentCopyFailed
        }
        XCTFail("An incomplete backup must fail")
      } catch {
        if cancelled { XCTAssertTrue(error is CancellationError) }
        else { XCTAssertEqual(error as? SnipLibraryError, .attachmentCopyFailed) }
      }
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
  }
}

private actor EvictingBackupCache {
  let root: URL
  let attachments: [SnipAttachment]
  let bytes: [Data]
  var previous: URL?
  init(root: URL, attachments: [SnipAttachment], bytes: [Data]) {
    self.root = root; self.attachments = attachments; self.bytes = bytes
  }
  func prepare(_ attachment: SnipAttachment) throws -> URL {
    if let previous { try FileManager.default.removeItem(at: previous) }
    let index = attachments.firstIndex(where: { $0.id == attachment.id })!
    let url = root.appendingPathComponent("cache-\(index).txt")
    try bytes[index].write(to: url)
    previous = url
    return url
  }
}
