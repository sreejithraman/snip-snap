import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class SnipLibraryImportTests: XCTestCase {
  func testRenamedListInBackupKeepsCurrentFieldsAndImportsItsSnips() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("target.store"))
    let listID = UUID()
    let currentList = SnipList(
      id: listID,
      name: "Current name",
      systemImage: "tray",
      position: 1
    )
    let backupList = SnipList(
      id: listID,
      name: "Backup name",
      systemImage: "archivebox",
      position: 1
    )
    let transitionID = UUID()
    _ = try await target.mergeTransferSnapshot(
      transferSnapshot(lists: [.inbox, currentList]),
      transitionID: transitionID
    )
    let sourceSnip = snip(content: "Filed in backup", listID: listID)
    let source = transferSnapshot(
      snips: [sourceSnip],
      lists: [.inbox, backupList]
    )

    let preview = try await target.previewImport(source, transitionID: UUID())

    XCTAssertEqual(preview.addedListCount, 0)
    XCTAssertEqual(preview.addedSnipCount, 1)
    let result = try await target.applyImport(preview)
    XCTAssertEqual(result.snapshot.lists.first { $0.id == listID }?.desiredName, "Current name")
    XCTAssertEqual(result.snapshot.lists.first { $0.id == listID }?.systemImage, "tray")
    XCTAssertEqual(result.snapshot.snips.first { $0.id == sourceSnip.id }?.listID, listID)
  }

  func testPreviewDoesNotWriteAndConfirmedApplyMergesStableIdentities() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    let target = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("target.store"))
    let sharedID = UUID()

    _ = try await target.perform(
      .restore(snips: [snip(id: sharedID, content: "Current")]),
      sortedBy: .chronological
    )
    _ = try await source.perform(
      .restore(snips: [
        snip(id: sharedID, content: "Backup edit"),
        snip(content: "Backup only"),
      ]),
      sortedBy: .chronological
    )

    let preview = try await SnipLibraryImport.preview(source: source, target: target)

    XCTAssertEqual(preview.addedSnipCount, 1)
    XCTAssertEqual(preview.recoveredSnipCount, 1)
    XCTAssertEqual(preview.totalSnipCount, 2)
    let beforeApply = await target.snapshot(sortedBy: .chronological)
    XCTAssertEqual(beforeApply.snips.map(\.content), ["Current"])

    let result = try await SnipLibraryImport.apply(preview, to: target)

    XCTAssertEqual(result.addedSnipCount, 1)
    XCTAssertEqual(result.recoveredSnipCount, 1)
    let contents = Set(result.snapshot.snips.map(\.content))
    XCTAssertEqual(contents, ["Current", "Backup edit", "Backup only"])
    XCTAssertEqual(result.snapshot.snips.first { $0.id == sharedID }?.content, "Current")
  }

  func testApplyRejectsAChangedTargetAndLeavesBothChangesIntact() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    let target = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("target.store"))
    _ = try await source.perform(
      .restore(snips: [snip(content: "From backup")]),
      sortedBy: .chronological
    )
    let preview = try await SnipLibraryImport.preview(source: source, target: target)
    _ = try await target.perform(
      .restore(snips: [snip(content: "Arrived later")]),
      sortedBy: .chronological
    )

    do {
      _ = try await SnipLibraryImport.apply(preview, to: target)
      XCTFail("Expected a stale preview to fail")
    } catch SnipLibraryError.importChanged {
    }

    let current = await target.snapshot(sortedBy: .chronological)
    XCTAssertEqual(current.snips.map(\.content), ["Arrived later"])
  }

  func testConfirmedImportEntersDurableUndoHistory() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("target.store")
    let journalURL = directory.appendingPathComponent("device-actions.json")
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    let target = try SwiftDataSnipLibrary(storeURL: storeURL)
    _ = try await source.perform(
      .restore(snips: [snip(content: "From backup")]),
      sortedBy: .chronological
    )
    let preview = try await SnipLibraryImport.preview(source: source, target: target)
    let actions = SnipLibraryDeviceActions(library: target, journalURL: journalURL)

    let imported = try await actions.applyImport(preview, sortedBy: .chronological)
    XCTAssertEqual(imported.snapshot.snips.map(\.content), ["From backup"])

    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
    let reopenedActions = SnipLibraryDeviceActions(library: reopened, journalURL: journalURL)
    let undone = try await reopenedActions.undo(sortedBy: .chronological)
    XCTAssertEqual(undone?.snapshot.snips, [])
  }

  func testConfirmedImportReturnsTheRequestedManualOrder() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("target.store"))
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    let first = Snip(
      createdAt: Date(timeIntervalSince1970: 100),
      content: "First",
      origin: .quickEntry,
      manualPosition: -1
    )
    let second = Snip(
      createdAt: Date(timeIntervalSince1970: 300),
      content: "Second",
      origin: .quickEntry,
      manualPosition: 1
    )
    _ = try await target.perform(.restore(snips: [first, second]), sortedBy: .manual)
    _ = try await source.perform(
      .restore(snips: [Snip(
        createdAt: Date(timeIntervalSince1970: 200),
        content: "Imported",
        origin: .quickEntry,
        manualPosition: 0
      )]),
      sortedBy: .manual
    )
    let preview = try await SnipLibraryImport.preview(source: source, target: target)
    let actions = SnipLibraryDeviceActions(
      library: target,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )

    let result = try await actions.applyImport(preview, sortedBy: .manual)

    let expected = try await target.checkedSnapshot(sortedBy: .manual)
    let chronological = try await target.checkedSnapshot(sortedBy: .chronological)
    XCTAssertEqual(result.snapshot, expected)
    XCTAssertNotEqual(result.snapshot.snips.map(\.id), chronological.snips.map(\.id))
  }

  func testModeManagedLibraryImportsThroughItsReservedWritePath() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    _ = try await source.perform(
      .restore(snips: [snip(content: "Managed import")]),
      sortedBy: .chronological
    )
    let persistence = try SwiftDataSyncModePersistence(
      rootURL: directory.appendingPathComponent("SyncMode", isDirectory: true)
    )
    let target = try await persistence.activeLibrary()

    let preview = try await SnipLibraryImport.preview(source: source, target: target)
    let result = try await SnipLibraryImport.apply(preview, to: target)

    XCTAssertEqual(result.snapshot.snips.map(\.content), ["Managed import"])
    let reopened = try SwiftDataSyncModePersistence(
      rootURL: directory.appendingPathComponent("SyncMode", isDirectory: true)
    )
    let reopenedSnapshot = await (try await reopened.activeLibrary())
      .snapshot(sortedBy: .chronological)
    XCTAssertEqual(reopenedSnapshot.snips.map(\.content), ["Managed import"])
  }

  private func snip(
    id: UUID = UUID(),
    content: String,
    listID: UUID = SnipList.inboxID,
    updatedAt: TimeInterval = 100
  ) -> Snip {
    Snip(
      id: id,
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 50),
      updatedAt: Date(timeIntervalSince1970: updatedAt),
      content: content,
      origin: .quickEntry,
      listID: listID
    )
  }

  private func transferSnapshot(
    snips: [Snip] = [],
    lists: [SnipList]
  ) -> SnipLibraryTransferSnapshot {
    SnipLibraryTransferSnapshot(
      revision: 0,
      snips: snips,
      lists: lists,
      attachmentData: [:]
    )
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnipLibraryImportTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
