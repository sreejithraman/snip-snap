import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class SnipLibraryImportTests: XCTestCase {
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
    updatedAt: TimeInterval = 100
  ) -> Snip {
    Snip(
      id: id,
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 50),
      updatedAt: Date(timeIntervalSince1970: updatedAt),
      content: content,
      origin: .quickEntry
    )
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnipLibraryImportTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
