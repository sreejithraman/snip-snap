import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class BackupRequestHistoryTests: XCTestCase {
  func testManagedBackupRoundTripPreservesDeletedRequestHistory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourcePersistence = try SwiftDataSyncModePersistence(
      rootURL: root.appendingPathComponent("Source", isDirectory: true)
    )
    let source = try await sourcePersistence.activeLibrary()
    let requestID = UUID()
    let added = try await source.perform(
      .add(
        content: "Deleted before backup", origin: .quickEntry, source: nil,
        listID: SnipList.inboxID, attachmentURLs: [], requestID: requestID, now: Date()
      ),
      sortedBy: .manual
    )
    let snipID = try XCTUnwrap(added.snapshot.snips.first?.id)
    _ = try await source.perform(.delete(ids: [snipID]), sortedBy: .manual)
    let backup = root.appendingPathComponent("Backup", isDirectory: true)
    try JSONSnipArchiveTransfer.write(try await source.archive(), to: backup)

    let targetRoot = root.appendingPathComponent("Target", isDirectory: true)
    let targetPersistence = try SwiftDataSyncModePersistence(rootURL: targetRoot)
    let target = try await targetPersistence.activeLibrary()
    let preview = try await SnipLibraryImport.preview(backupURL: backup, target: target)
    _ = try await target.applyImport(preview)

    let reopened = try SwiftDataSyncModePersistence(rootURL: targetRoot)
    try await assertDuplicate(requestID, in: try await reopened.activeLibrary())
  }

  func testMetadataOnlyImportPreventsDeletedRequestReplayAfterReopen() async throws {
    for useSwiftData in [false, true] {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let requestID = UUID()
      let backup = try writeHistory([requestID], in: root)
      let store = root.appendingPathComponent(useSwiftData ? "snips.store" : "snips.json")
      func open() throws -> any SnipLibrary {
        if useSwiftData { return try SwiftDataSnipLibrary(storeURL: store) }
        return try JSONSnipLibrary(fileURL: store)
      }
      let library = try open()
      let preview = try await SnipLibraryImport.preview(backupURL: backup, target: library)
      XCTAssertEqual(preview.addedSnipCount, 0)
      XCTAssertEqual(preview.addedListCount, 0)
      _ = try await library.applyImport(preview)

      let reopened = try open()
      try await assertDuplicate(requestID, in: reopened)
      let retry = try await SnipLibraryImport.preview(backupURL: backup, target: reopened)
      _ = try await reopened.applyImport(retry)
      try await assertDuplicate(requestID, in: try open())
    }
  }

  func testFailedMetadataOnlyImportRollsBackHistoryAndCanBeRetried() async throws {
    enum SaveFailure: Error { case injected }
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let requestID = UUID()
    let backup = try writeHistory([requestID], in: root)
    let store = root.appendingPathComponent("snips.store")
    let failing = try SwiftDataSnipLibrary(
      storeURL: store,
      afterMutationBeforeSave: { throw SaveFailure.injected }
    )
    let preview = try await SnipLibraryImport.preview(backupURL: backup, target: failing)
    do {
      _ = try await failing.applyImport(preview)
      XCTFail("Expected the injected save failure")
    } catch SaveFailure.injected {}

    let reopened = try SwiftDataSnipLibrary(storeURL: store)
    let failedArchive = try await reopened.archive()
    XCTAssertFalse(failedArchive.seenRequestIDs.contains(requestID))
    let retry = try await SnipLibraryImport.preview(backupURL: backup, target: reopened)
    _ = try await reopened.applyImport(retry)
    try await assertDuplicate(requestID, in: try SwiftDataSnipLibrary(storeURL: store))
  }

  func testModeManagedBackupImportPreservesHistoryAfterReopen() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let requestID = UUID()
    let backup = try writeHistory([requestID], in: root)
    let modeRoot = root.appendingPathComponent("SyncMode", isDirectory: true)
    let persistence = try SwiftDataSyncModePersistence(rootURL: modeRoot)
    let target = try await persistence.activeLibrary()
    let preview = try await SnipLibraryImport.preview(backupURL: backup, target: target)

    _ = try await target.applyImport(preview)

    let reopened = try SwiftDataSyncModePersistence(rootURL: modeRoot)
    try await assertDuplicate(requestID, in: try await reopened.activeLibrary())
  }

  func testImportPreservesRequestHistoryAddedAfterPreviewValidation() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let importedRequestID = UUID()
    let concurrentRequestID = UUID()
    let backup = try writeHistory([importedRequestID], in: root)
    let concurrentBackup = try writeHistory([concurrentRequestID], in: root)
    let store = root.appendingPathComponent("snips.store")
    let other = try SwiftDataSnipLibrary(storeURL: store)
    let target = try SwiftDataSnipLibrary(
      storeURL: store,
      beforeImportCommit: {
        let preview = try await SnipLibraryImport.preview(backupURL: concurrentBackup, target: other)
        _ = try await other.applyImport(preview)
      }
    )
    let preview = try await SnipLibraryImport.preview(backupURL: backup, target: target)
    _ = try await target.applyImport(preview)

    let reopened = try SwiftDataSnipLibrary(storeURL: store)
    try await assertDuplicate(importedRequestID, in: reopened)
    try await assertDuplicate(concurrentRequestID, in: reopened)
  }

  private func assertDuplicate(
    _ requestID: UUID,
    in library: any SnipLibrary,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let replay = try await library.perform(
      .add(
        content: "Must stay deleted", origin: .quickEntry, source: nil,
        listID: SnipList.inboxID, attachmentURLs: [], requestID: requestID, now: Date()
      ),
      sortedBy: .manual
    )
    XCTAssertEqual(replay.outcome, .add(.duplicate), file: file, line: line)
    XCTAssertTrue(replay.snapshot.snips.isEmpty, file: file, line: line)
  }

  private func writeHistory(_ requestIDs: Set<UUID>, in root: URL) throws -> URL {
    let backup = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try JSONSnipArchiveTransfer.write(
      SnipLibraryArchive(
        snips: [], lists: [.inbox], seenRequestIDs: requestIDs, attachmentURLs: [:]
      ),
      to: backup
    )
    return backup
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BackupRequestHistoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
  }
}
