import Foundation
import SwiftData
import XCTest
@testable import SnipSnapCore
@testable import SnipSnapPersistence

final class SnipPinTests: XCTestCase {
  func testPinClearsDoneAndBulkToggleIgnoresPins() throws {
    let pinned = Snip(content: "Reusable", origin: .quickEntry, isDone: true)
    let regular = Snip(content: "Task", origin: .quickEntry, isDone: true)
    var state = SnipLibraryState(snips: [pinned, regular], lists: [.inbox], seenRequestIDs: [])
    func run(_ command: SnipLibraryCommand) throws {
      _ = try state.perform(command, prepareAttachments: { _, _ in [] }, pruneAttachments: { _, _ in })
    }
    try run(.setPinned(ids: [pinned.id], pinned: true))
    let originalPin = try XCTUnwrap(state.snips.first?.pinnedAt)
    XCTAssertFalse(state.snips[0].isDone)
    try run(.setPinned(ids: [pinned.id], pinned: true))
    XCTAssertEqual(state.snips[0].pinnedAt, originalPin)
    try run(.toggleDoneMany(ids: [pinned.id, regular.id]))
    XCTAssertFalse(state.snips[0].isDone)
    XCTAssertFalse(state.snips[1].isDone)
    try run(.setDone(ids: [pinned.id, regular.id], done: true))
    XCTAssertFalse(state.snips[0].isDone)
    XCTAssertTrue(state.snips[1].isDone)
    try run(.togglePinned(id: pinned.id))
    XCTAssertFalse(state.snips[0].isPinned)
    XCTAssertFalse(state.snips[0].isDone)
  }

  func testPinsSortFirstInBothModesAndDecodeEnforcesInvariant() throws {
    let older = Snip(content: "Old pin", origin: .quickEntry, pinnedAt: Date(timeIntervalSince1970: 10))
    let newer = Snip(content: "New pin", origin: .quickEntry, pinnedAt: Date(timeIntervalSince1970: 20))
    let regular = Snip(content: "Regular", origin: .quickEntry)
    for mode in [SnipSortMode.chronological, .manual] {
      XCTAssertEqual(Snip.sorted([regular, older, newer], by: mode).map(\.id), [newer.id, older.id, regular.id])
    }
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any])
    json["isDone"] = true
    let imported = try JSONDecoder().decode(Snip.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertTrue(imported.isPinned)
    XCTAssertFalse(imported.isDone)
    json.removeValue(forKey: "pinnedAt")
    let legacy = try JSONDecoder().decode(Snip.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertFalse(legacy.isPinned)
    XCTAssertTrue(legacy.isDone)
  }

  func testPinsSurviveBothDurableAdaptersAndUnpin() async throws {
    for useSwiftData in [false, true] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appendingPathComponent(useSwiftData ? "snips.store" : "snips.json")
      func open() throws -> any SnipLibrary {
        if useSwiftData { return try SwiftDataSnipLibrary(storeURL: url) }
        return try JSONSnipLibrary(fileURL: url)
      }
      let library = try open()
      let added = try await library.perform(.add(content: "Pin me", origin: .quickEntry, source: nil, listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: Date()), sortedBy: .chronological)
      let id = try XCTUnwrap(added.snapshot.snips.first?.id)
      let result = try await library.perform(.setPinned(ids: [id], pinned: true), sortedBy: .chronological)
      let reopened = try open()
      let snapshot = await reopened.snapshot(sortedBy: .chronological)
      XCTAssertEqual(snapshot.snips.first?.pinnedAt, result.snapshot.snips.first?.pinnedAt)
      XCTAssertTrue(snapshot.snips.first?.isPinned == true)
      _ = try await reopened.perform(.setPinned(ids: [id], pinned: false), sortedBy: .manual)
      let final = await (try open()).snapshot(sortedBy: .manual)
      XCTAssertFalse(try XCTUnwrap(final.snips.first).isPinned)
    }
  }

  func testTransferDigestTracksPinsAndKeepsOldDigestVersionsStable() {
    let snip = Snip(content: "Reusable", origin: .quickEntry)
    var pinned = snip
    pinned.pinnedAt = Date(timeIntervalSince1970: 123)
    XCTAssertNotEqual(SnipLibraryTransferPlanner.digest(snip: snip, attachmentData: [:]), SnipLibraryTransferPlanner.digest(snip: pinned, attachmentData: [:]))
    for version in [1, 2] {
      XCTAssertEqual(SnipLibraryTransferPlanner.digest(snip: snip, attachmentData: [:], version: version), SnipLibraryTransferPlanner.digest(snip: pinned, attachmentData: [:], version: version))
    }
  }

  func testV4StoreMigratesWithSnipsIntact() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snips.store")
    let snip = Snip(content: "Existing", origin: .quickEntry, isDone: true)
    do {
      let schema = Schema(versionedSchema: SnipSnapSchemaV4.self)
      let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("Legacy", schema: schema, url: url, cloudKitDatabase: .none)])
      let context = ModelContext(container)
      context.insert(StoredSnipRecord(snip))
      context.insert(StoredListRecord(.inbox))
      try context.save()
    }
    let library = try SwiftDataSnipLibrary(storeURL: url)
    let snapshot = await library.snapshot(sortedBy: .chronological)
    XCTAssertEqual(snapshot.snips.first?.id, snip.id)
    XCTAssertTrue(snapshot.snips.first?.isDone == true)
    XCTAssertFalse(snapshot.snips.first?.isPinned == true)
    let result = try await library.perform(.setPinned(ids: [snip.id], pinned: true), sortedBy: .chronological)
    XCTAssertTrue(result.snapshot.snips.first?.isPinned == true)
    XCTAssertFalse(result.snapshot.snips.first?.isDone == true)
  }
}
