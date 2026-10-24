import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

final class SnipCLIDataBackupTests: XCTestCase {
  func testSessionPreviewAndImportRoundTripAttachmentBytesAndRejectAStalePreview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source/snips.json"))
    let file = root.appendingPathComponent("evidence.txt")
    let bytes = Data("Exact backup attachment".utf8)
    try bytes.write(to: file)
    _ = try await source.perform(.add(content: "Backed up", origin: .quickEntry, source: nil,
      listID: SnipList.inboxID, attachmentURLs: [file], requestID: UUID(), now: Date()), sortedBy: .chronological)
    let backup = root.appendingPathComponent("Backup")
    try await JSONSnipArchiveTransfer.write(source.archive(), to: backup)
    let target = try JSONSnipLibrary(fileURL: root.appendingPathComponent("target/snips.json"))
    let actions = DirectSnipLibraryUserActions(library: target, previewBackupImport: { url, library in
      try await SnipLibraryImport.preview(backupURL: url, target: library)
    })
    let session = SavedSnipsSession(library: target, userActions: actions)
    let old = try await session.previewImport(from: backup)
    _ = try await target.perform(.add(content: "Concurrent change", origin: .quickEntry, source: nil,
      listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: Date()), sortedBy: .chronological)
    do {
      _ = try await session.applyPendingImport(id: old.id, sortedBy: .chronological)
      XCTFail("Import must preserve the target when its preview is stale")
    } catch SnipLibraryError.importChanged {}
    let fresh = try await session.previewImport(from: backup)
    XCTAssertEqual(fresh.value.addedAttachmentCount, 1)
    let result = try await session.applyPendingImport(id: fresh.id, sortedBy: .chronological)
    XCTAssertEqual(result?.0.addedSnipCount, 1)
    let archive = try await target.archive()
    XCTAssertEqual(Set(archive.snips.map(\.content)), ["Concurrent change", "Backed up"])
    let attachment = try XCTUnwrap(archive.snips.first { $0.content == "Backed up" }?.attachments.first)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archive.attachmentURLs[attachment.id])), bytes)
  }
}
