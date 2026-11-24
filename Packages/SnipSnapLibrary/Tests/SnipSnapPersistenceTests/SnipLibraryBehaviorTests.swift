import Foundation
import SnipSnapCore
import SwiftData
import XCTest

@testable import SnipSnapPersistence

final class SnipLibraryBehaviorTests: XCTestCase {

  func testMovingAListPersistsItsOrderAndPreservesItsSnips() async throws {
    try await withLibrary { directory, library in
      for name in ["Work", "Travel", "Reading"] {
        _ = try await library.perform(
          .createList(name: name, systemImage: "list.bullet"), sortedBy: .manual)
      }
      let initial = try await library.checkedSnapshot(sortedBy: .manual)
      let work = try XCTUnwrap(initial.lists.first { $0.name == "Work" })
      let reading = try XCTUnwrap(initial.lists.first { $0.name == "Reading" })
      _ = try await library.perform(
        .add(content: "Keep this note", origin: .quickEntry, source: nil, listID: reading.id,
             attachmentURLs: [], requestID: UUID(), now: Date()), sortedBy: .manual)
      let moved = try await library.perform(.moveList(id: reading.id, before: work.id), sortedBy: .manual)
      for unchanged in initial.lists where unchanged.id != reading.id {
        XCTAssertEqual(moved.snapshot.lists.first { $0.id == unchanged.id }, unchanged)
      }
      let reopened = try open(in: directory)
      let snapshot = try await reopened.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.lists.map(\.name), ["Inbox", "Reading", "Work", "Travel"])
      XCTAssertEqual(snapshot.snips.first?.listID, reading.id)
      _ = try await reopened.perform(.moveList(id: reading.id, before: nil), sortedBy: .manual)
      let reopenedAgain = try open(in: directory)
      let movedToEnd = try await reopenedAgain.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(movedToEnd.lists.map(\.name), ["Inbox", "Work", "Travel", "Reading"])
    }
  }

  func testMovingListsRejectsMissingDestinationsAndKeepsInboxFixed() async throws {
    try await withLibrary { _, library in
      _ = try await library.perform(.createList(name: "Work", systemImage: "list.bullet"), sortedBy: .manual)
      let initial = try await library.checkedSnapshot(sortedBy: .manual)
      let work = try XCTUnwrap(initial.lists.first { $0.name == "Work" })
      let commands: [SnipLibraryCommand] = [
        .moveList(id: SnipList.inboxID, before: nil),
        .moveList(id: work.id, before: SnipList.inboxID),
        .moveList(id: work.id, before: UUID()),
        .moveList(id: UUID(), before: work.id),
      ]
      for command in commands {
        do {
          _ = try await library.perform(command, sortedBy: .manual)
          XCTFail("Invalid moves must fail without changing the library")
        } catch {
          XCTAssertEqual(error as? SnipLibraryError, .invalidList)
        }
        let unchanged = try await library.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(unchanged, initial)
      }
      _ = try await library.perform(.moveList(id: work.id, before: work.id), sortedBy: .manual)
      let unchanged = try await library.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(unchanged, initial)
    }
  }

  func testListColorsSurviveEditsAndReopen() async throws {
    try await withLibrary { directory, library in
      let created = try await library.perform(
        .createList(name: "Work", systemImage: "briefcase", color: .blue), sortedBy: .manual)
      guard case .listCreated(let list) = created.outcome else { return XCTFail("Expected list") }
      XCTAssertEqual(list.color, .blue)
      _ = try await library.perform(
        .updateList(id: list.id, name: "Projects", systemImage: "folder"), sortedBy: .manual)
      let renamed = await library.snapshot(sortedBy: .manual)
      XCTAssertEqual(renamed.lists.first { $0.id == list.id }?.color, .blue)
      _ = try await library.perform(
        .updateList(id: list.id, name: "Projects", systemImage: "folder", color: .set(.pink)),
        sortedBy: .manual)
      let reopened = try open(in: directory)
      let snapshot = await reopened.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.lists.first { $0.id == list.id }?.color, .pink)
      XCTAssertEqual(snapshot.lists.first { $0.id == SnipList.inboxID }?.color, nil)
      _ = try await reopened.perform(
        .updateList(id: list.id, name: "Projects", systemImage: "folder", color: .set(nil)), sortedBy: .manual)
      let clearedLibrary = try open(in: directory)
      let cleared = await clearedLibrary.snapshot(sortedBy: .manual)
      XCTAssertNil(cleared.lists.first { $0.id == list.id }?.color)
    }
  }

  func testListJSONStoresPresetIDAndOldOrUnknownColorsDefaultToNeutral() throws {
    let list = SnipList(id: UUID(), name: "Work", systemImage: "folder", color: .red, position: 1)
    let encoded = try JSONEncoder().encode(list)
    XCTAssertEqual(try JSONDecoder().decode(SnipList.self, from: encoded).color, .red)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "colorPreset")
    legacy["color"] = ["light": "#123456", "dark": "#ABCDEF"]
    let old = try JSONDecoder().decode(SnipList.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertNil(old.color)
    legacy["colorPreset"] = "future-color"
    let unknown = try JSONDecoder().decode(
      SnipList.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertNil(unknown.color)
  }

  func testVersion4StoreMigratesListsToNeutralAndCanSaveColor() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snips.store")
    let list = SnipList(id: UUID(), name: "Existing", systemImage: "star", position: 1)
    do {
      let schema = Schema(versionedSchema: SnipSnapSchemaV4.self)
      let container = try ModelContainer(for: schema, configurations: [
        ModelConfiguration("SnipSnapLocal", schema: schema, url: url, cloudKitDatabase: .none)
      ])
      let context = ModelContext(container)
      context.insert(SnipSnapSchemaV4.StoredListRecord(.inbox))
      context.insert(SnipSnapSchemaV4.StoredListRecord(list))
      try context.save()
    }
    let library = try SwiftDataSnipLibrary(storeURL: url)
    let migrated = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(migrated.lists.first { $0.id == list.id }?.color, nil)
    _ = try await library.perform(
      .updateList(id: list.id, name: list.name, systemImage: list.systemImage, color: .set(.violet)),
      sortedBy: .manual)
    let reopened = try SwiftDataSnipLibrary(storeURL: url)
    let saved = await reopened.snapshot(sortedBy: .manual)
    XCTAssertEqual(saved.lists.first { $0.id == list.id }?.color, .violet)
  }

  func testVersion5StoreDropsColorIDToNeutral() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snips.store")
    let list = SnipList(id: UUID(), name: "Existing", systemImage: "star", position: 1)
    do {
      let schema = Schema(versionedSchema: SnipSnapSchemaV5.self)
      let container = try ModelContainer(for: schema, configurations: [
        ModelConfiguration("SnipSnapLocal", schema: schema, url: url, cloudKitDatabase: .none)
      ])
      let context = ModelContext(container)
      context.insert(SnipSnapSchemaV5.StoredListRecord(.inbox, colorID: "neutral"))
      context.insert(SnipSnapSchemaV5.StoredListRecord(list, colorID: "purple"))
      try context.save()
    }
    let library = try SwiftDataSnipLibrary(storeURL: url)
    let snapshot = await library.snapshot(sortedBy: .manual)
    XCTAssertNil(snapshot.lists.first { $0.id == list.id }?.color)
    let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
    let container = try ModelContainer(for: schema, configurations: [
      ModelConfiguration("SnipSnapLocal", schema: schema, url: url, cloudKitDatabase: .none)
    ])
    let records = try ModelContext(container).fetch(FetchDescriptor<StoredListRecord>())
    XCTAssertNil(records.first { $0.id == list.id }?.colorPresetID)
  }

  func testVersion7StoreDropsHexAndLegacyIDsToNeutralThenSavesPresetID() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snips.store")
    let colored = SnipList(id: UUID(), name: "Colored", systemImage: "star", position: 1)
    let idOnly = SnipList(id: UUID(), name: "ID only", systemImage: "tag", position: 2)
    do {
      let schema = Schema(versionedSchema: SnipSnapSchemaV7.self)
      let container = try ModelContainer(for: schema, configurations: [
        ModelConfiguration("SnipSnapLocal", schema: schema, url: url, cloudKitDatabase: .none)
      ])
      let context = ModelContext(container)
      context.insert(SnipSnapSchemaV6.StoredListRecord(.inbox))
      context.insert(SnipSnapSchemaV6.StoredListRecord(
        colored,
        lightHex: SnipListColorPreset.pink.color.light,
        darkHex: SnipListColorPreset.pink.color.dark
      ))
      context.insert(SnipSnapSchemaV6.StoredListRecord(idOnly, colorID: "purple"))
      try context.save()
    }

    let library = try SwiftDataSnipLibrary(storeURL: url)
    let snapshot = await library.snapshot(sortedBy: .manual)
    XCTAssertNil(snapshot.lists.first { $0.id == colored.id }?.color)
    XCTAssertNil(snapshot.lists.first { $0.id == idOnly.id }?.color)

    _ = try await library.perform(
      .updateList(
        id: colored.id, name: colored.name, systemImage: colored.systemImage,
        color: .set(.pink)),
      sortedBy: .manual)

    let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
    let container = try ModelContainer(for: schema, configurations: [
      ModelConfiguration("SnipSnapLocal", schema: schema, url: url, cloudKitDatabase: .none)
    ])
    let records = try ModelContext(container).fetch(FetchDescriptor<StoredListRecord>())
    XCTAssertEqual(records.first { $0.id == colored.id }?.colorPresetID, "pink")
    XCTAssertNil(records.first { $0.id == idOnly.id }?.colorPresetID)
  }

  func testVersion8StoreDropsHexToNeutralAndPreservesList() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snips.store")
    let list = SnipList(id: UUID(), name: "Existing", systemImage: "star", position: 1)
    do {
      let schema = Schema(versionedSchema: SnipSnapSchemaV8.self)
      let container = try ModelContainer(for: schema, configurations: [
        ModelConfiguration("SnipSnapLocal", schema: schema, url: url, cloudKitDatabase: .none)
      ])
      let context = ModelContext(container)
      context.insert(SnipSnapSchemaV8.StoredListRecord(.inbox))
      context.insert(SnipSnapSchemaV8.StoredListRecord(
        list,
        lightHex: SnipListColorPreset.red.color.light,
        darkHex: SnipListColorPreset.red.color.dark
      ))
      try context.save()
    }

    let library = try SwiftDataSnipLibrary(storeURL: url)
    let snapshot = await library.snapshot(sortedBy: .manual)
    let migrated = try XCTUnwrap(snapshot.lists.first { $0.id == list.id })
    XCTAssertEqual(migrated.name, "Existing")
    XCTAssertEqual(migrated.systemImage, "star")
    XCTAssertNil(migrated.color)
  }

  /// No tagged build wrote a schema older than V4. A store in such a shape must be refused, not
  /// rebuilt: opening it fails and its rows stay readable in their original schema.
  func testStoreOlderThanVersion4IsRefusedAndLeftUnchanged() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snips.store")
    let snip = Snip(content: "Untagged schema", origin: .quickEntry)
    do {
      let schema = Schema(versionedSchema: UntaggedVersion1Schema.self)
      let container = try ModelContainer(for: schema, configurations: [
        ModelConfiguration("SnipSnapLocal", schema: schema, url: url, cloudKitDatabase: .none)
      ])
      let context = ModelContext(container)
      context.insert(SnipSnapSchemaV4.StoredListRecord(.inbox))
      context.insert(StoredSnipRecord(snip))
      try context.save()
    }

    XCTAssertThrowsError(try SwiftDataSnipLibrary(storeURL: url)) { error in
      XCTAssertEqual(error as? SnipLibraryError, .invalidStore)
    }

    let schema = Schema(versionedSchema: UntaggedVersion1Schema.self)
    let container = try ModelContainer(for: schema, configurations: [
      ModelConfiguration("SnipSnapLocal", schema: schema, url: url, cloudKitDatabase: .none)
    ])
    let stored = try ModelContext(container).fetch(FetchDescriptor<StoredSnipRecord>())
    XCTAssertEqual(stored.map(\.id), [snip.id])
  }

  private enum UntaggedVersion1Schema: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
      [
        StoredSnipRecord.self,
        SnipSnapSchemaV4.StoredListRecord.self,
        StoredAttachmentRecord.self,
        StoredSnipAttachmentReference.self,
        StoredRequestRecord.self,
      ]
    }
  }

  func testVersion9ModelsAreVersion8WithTheCurrentListRecord() {
    let names = { (models: [any PersistentModel.Type]) in
      models.map { String(reflecting: $0) }
    }
    let derived = SnipSnapSchemaV8.models.filter { $0 != SnipSnapSchemaV8.StoredListRecord.self }
      + [StoredListRecord.self]
    XCTAssertEqual(names(SnipSnapSchemaV9.models), names(derived))
  }

  func testListAddOrderingAndDuplicateRulesSurviveReopen() async throws {
    try await withLibrary { directory, library in
      let work = try await createList(named: " Work ", in: library)
      await assertThrows(.duplicateList) {
        _ = try await library.perform(
          .createList(name: "work", systemImage: "briefcase"),
          sortedBy: .chronological
        )
      }

      let firstRequest = UUID()
      let first = try await add(
        "First",
        requestID: firstRequest,
        at: 100,
        to: work.id,
        in: library
      )
      let second = try await add(
        "Second",
        requestID: UUID(),
        at: 200,
        to: work.id,
        in: library
      )
      let duplicate = try await library.perform(
        .add(
          content: "Ignored retry",
          origin: .quickEntry,
          source: nil,
          listID: work.id,
          attachmentURLs: [],
          requestID: firstRequest,
          now: Date(timeIntervalSince1970: 300)
        ),
        sortedBy: .chronological
      )
      XCTAssertEqual(duplicate.outcome, .add(.duplicate))
      XCTAssertEqual(duplicate.snapshot.snips.map(\.id), [second.id, first.id])

      let reopened = try open(in: directory)
      let reopenedSnapshot = await reopened.snapshot(sortedBy: .chronological)
      XCTAssertEqual(reopenedSnapshot.lists.map(\.name), ["Inbox", "Work"])
      XCTAssertEqual(reopenedSnapshot.snips.map(\.content), ["Second", "First"])

      let reopenedRetry = try await reopened.perform(
        .add(
          content: "Still ignored",
          origin: .quickEntry,
          source: nil,
          listID: work.id,
          attachmentURLs: [],
          requestID: firstRequest,
          now: Date(timeIntervalSince1970: 400)
        ),
        sortedBy: .chronological
      )
      XCTAssertEqual(reopenedRetry.outcome, .add(.duplicate))
      XCTAssertEqual(reopenedRetry.snapshot.snips.count, 2)
    }
  }

  func testSyncOrderKeysPersistAndDesiredListNamesAreNormalized() async throws {
    try await withLibrary { directory, library in
      let list = try await createList(named: "Résumé", in: library)
      await assertThrows(.duplicateList) {
        _ = try await library.perform(
          .createList(name: "  resume  ", systemImage: "doc"),
          sortedBy: .manual
        )
      }
      let first = try await add("First", requestID: UUID(), at: 10, to: list.id, in: library)
      let second = try await add("Second", requestID: UUID(), at: 20, to: list.id, in: library)
      _ = try await library.perform(
        .place(ids: [first.id], in: list.id, before: second.id, basedOn: .manual),
        sortedBy: .manual
      )
      let beforeReopen = await library.snapshot(sortedBy: .manual)
      let keys = beforeReopen.snips.map(\.manualSortKey)
      XCTAssertEqual(Set(keys).count, 2)
      XCTAssertTrue(keys.contains { $0.data.count != 10 })

      let reopened = try open(in: directory)
      let afterReopen = await reopened.snapshot(sortedBy: .manual)
      XCTAssertEqual(afterReopen.snips.map(\.id), beforeReopen.snips.map(\.id))
      XCTAssertEqual(afterReopen.snips.map(\.manualSortKey), keys)
      XCTAssertEqual(afterReopen.lists.first { $0.id == list.id }?.desiredName, "Résumé")
    }
  }

  func testEditMergeListDeletionAndManualOrderingSurviveReopen() async throws {
    try await withLibrary { directory, library in
      let work = try await createList(named: "Work", in: library)
      let first = try await add("First", requestID: UUID(), at: 100, to: work.id, in: library)
      let second = try await add("Second", requestID: UUID(), at: 200, to: work.id, in: library)
      let staleDate = first.updatedAt.addingTimeInterval(-1)
      await assertThrows(.snipChanged) {
        _ = try await library.perform(
          .update(
            id: first.id,
            content: "Stale",
            attachmentURLs: nil,
            expectedUpdatedAt: staleDate,
            now: Date(timeIntervalSince1970: 300)
          ),
          sortedBy: .manual
        )
      }

      _ = try await library.perform(
        .place(ids: [first.id], in: work.id, before: second.id, basedOn: .manual),
        sortedBy: .manual
      )
      let merged = try await library.perform(
        .merge(ids: [first.id, second.id], now: Date(timeIntervalSince1970: 400)),
        sortedBy: .manual
      )
      guard case .merged(let mergedSnip) = merged.outcome else {
        return XCTFail("Expected merged snip")
      }
      XCTAssertTrue(mergedSnip.content.contains("First"))
      XCTAssertTrue(mergedSnip.content.contains("Second"))

      _ = try await library.perform(.deleteList(id: work.id), sortedBy: .manual)
      let reopened = try open(in: directory)
      let snapshot = await reopened.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.lists, [.inbox])
      XCTAssertEqual(snapshot.snips.map(\.listID), [SnipList.inboxID])
      XCTAssertEqual(snapshot.snips.map(\.id), [mergedSnip.id])
    }
  }

  func testDoneStateManualOrderAndListMovesSurviveReopen() async throws {
    try await withLibrary { directory, library in
      let work = try await createList(named: "Work", in: library)
      let first = try await add("First", requestID: UUID(), at: 100, to: SnipList.inboxID, in: library)
      let second = try await add("Second", requestID: UUID(), at: 200, to: SnipList.inboxID, in: library)
      let third = try await add("Third", requestID: UUID(), at: 300, to: SnipList.inboxID, in: library)

      _ = try await library.perform(
        .setDone(ids: [second.id], done: true),
        sortedBy: .manual
      )
      _ = try await library.perform(
        .place(ids: [third.id, first.id], in: work.id, before: nil, basedOn: .manual),
        sortedBy: .manual
      )

      let reopened = try open(in: directory)
      let snapshot = await reopened.snapshot(sortedBy: .manual)
      XCTAssertEqual(
        snapshot.snips.filter { $0.listID == work.id }.map(\.id),
        [third.id, first.id])
      XCTAssertEqual(snapshot.snips.first(where: { $0.id == second.id })?.isDone, true)
      XCTAssertEqual(snapshot.snips.first(where: { $0.id == second.id })?.listID, SnipList.inboxID)
    }
  }

  func testGuardedInverseRejectsChangedRecordsAndKeepsUnrelatedWrites() async throws {
    try await withLibrary { _, library in
      let first = try await add("First", requestID: UUID(), at: 100, to: SnipList.inboxID, in: library)
      let unrelated = try await add("Unrelated", requestID: UUID(), at: 200, to: SnipList.inboxID, in: library)
      let doneUpdate = try await library.perform(
        .setDone(ids: [first.id], done: true),
        sortedBy: .manual
      )
      let expectedDone = try XCTUnwrap(doneUpdate.snapshot.snips.first(where: { $0.id == first.id }))

      _ = try await library.perform(
        .update(
          id: first.id,
          content: "Changed later",
          attachmentURLs: nil,
          expectedUpdatedAt: expectedDone.updatedAt,
          now: Date(timeIntervalSince1970: 300)
        ),
        sortedBy: .manual
      )

      await assertThrows(.snipChanged) {
        _ = try await library.perform(
          .guarded(
            expectation: SnipLibraryExpectation(expectedSnips: [expectedDone]),
            command: .setDone(ids: [first.id], done: first.isDone)
          ),
          sortedBy: .manual
        )
      }

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.snips.first(where: { $0.id == first.id })?.content, "Changed later")
      XCTAssertEqual(snapshot.snips.first(where: { $0.id == unrelated.id })?.content, "Unrelated")
      XCTAssertEqual(snapshot.snips.count, 2)
    }
  }

  func testGuardedListDeletionRejectsNewListMembers() async throws {
    try await withLibrary { _, library in
      let work = try await createList(named: "Work", in: library)
      let added = try await add(
        "Added elsewhere",
        requestID: UUID(),
        at: 100,
        to: work.id,
        in: library
      )

      await assertThrows(.snipChanged) {
        _ = try await library.perform(
          .guarded(
            expectation: SnipLibraryExpectation(
              expectedListMemberships: [work.id: []]
            ),
            command: .deleteList(id: work.id)
          ),
          sortedBy: .manual
        )
      }

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertTrue(snapshot.lists.contains(where: { $0.id == work.id }))
      XCTAssertEqual(snapshot.snips.first(where: { $0.id == added.id })?.listID, work.id)
    }
  }

  func testGuardedRestoreRejectsADeletedDestinationList() async throws {
    try await withLibrary { _, library in
      let work = try await createList(named: "Work", in: library)
      let removed = try await add("Removed", requestID: UUID(), at: 100, to: work.id, in: library)
      _ = try await library.perform(.delete(ids: [removed.id]), sortedBy: .manual)
      _ = try await library.perform(.deleteList(id: work.id), sortedBy: .manual)

      await assertThrows(.snipChanged) {
        _ = try await library.perform(
          .guarded(
            expectation: SnipLibraryExpectation(requiredListIDs: [work.id]),
            command: .restore(snips: [removed])
          ),
          sortedBy: .manual
        )
      }

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertFalse(snapshot.snips.contains(where: { $0.id == removed.id }))
    }
  }

  func testRestoreRejectsSnipsWhoseListDoesNotExist() async throws {
    try await withLibrary { _, library in
      let orphan = Snip(
        content: "Orphan",
        origin: .quickEntry,
        listID: UUID()
      )

      await assertThrows(.invalidList) {
        _ = try await library.perform(.restore(snips: [orphan]), sortedBy: .manual)
      }

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertTrue(snapshot.snips.isEmpty)
    }
  }

  func testRestoreRetriesIgnoreListIDsOnRecordsThatAlreadyExist() async throws {
    try await withLibrary { _, library in
      let existing = try await add(
        "Existing",
        requestID: UUID(),
        at: 100,
        to: SnipList.inboxID,
        in: library
      )
      let ignoredRetry = Snip(
        id: existing.id,
        requestID: existing.requestID,
        createdAt: existing.createdAt,
        content: "Ignored retry",
        origin: existing.origin,
        listID: UUID()
      )

      _ = try await library.perform(.restore(snips: [ignoredRetry]), sortedBy: .manual)

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.snips, [existing])
    }
  }

  func testBatchRejectsAttachmentPruningBeforeAnySideEffect() async throws {
    try await withLibrary { directory, library in
      let sourceURL = directory.appendingPathComponent("keep-me.txt")
      try Data("Keep".utf8).write(to: sourceURL)
      let added = try await library.perform(
        .add(
          content: "Has file",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [sourceURL],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .manual
      )
      let snip = try XCTUnwrap(added.snapshot.snips.first)
      let attachment = try XCTUnwrap(snip.attachments.first)
      let storedURL = try XCTUnwrap(added.snapshot.attachmentURLs[attachment.id])

      await assertThrows(.invalidCommand) {
        _ = try await library.perform(
          .batch([
            .delete(ids: [snip.id]),
            .pruneAttachments(retaining: []),
          ]),
          sortedBy: .manual
        )
      }

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertTrue(snapshot.snips.contains(where: { $0.id == snip.id }))
      XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
    }
  }

  func testLargeNewTextIsStoredAsAnAttachment() async throws {
    try await withLibrary { directory, library in
      let text = String(repeating: "p", count: LargePastedText.attachmentCharacterLimit)
      let added = try await library.perform(
        .add(
          content: text,
          origin: .selection,
          source: SnipSource(applicationName: "Safari"),
          listID: SnipList.inboxID,
          attachmentURLs: [],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
      let snip = try XCTUnwrap(added.snapshot.snips.first)
      XCTAssertEqual(snip.content, "")
      XCTAssertEqual(snip.attachments.count, 1)
      let attachment = try XCTUnwrap(snip.attachments.first)
      XCTAssertTrue(attachment.fileName.hasPrefix("Pasted Text "))
      XCTAssertTrue(attachment.fileName.hasSuffix(".txt"))
      let storedURL = try XCTUnwrap(added.snapshot.attachmentURLs[attachment.id])
      XCTAssertEqual(
        String(data: try Data(contentsOf: storedURL), encoding: .utf8),
        text)

      let short = try await add(
        String(repeating: "s", count: LargePastedText.attachmentCharacterLimit - 1),
        requestID: UUID(),
        at: 200,
        to: SnipList.inboxID,
        in: library
      )
      XCTAssertEqual(
        short.content.count,
        LargePastedText.attachmentCharacterLimit - 1)
      XCTAssertTrue(short.attachments.isEmpty)
    }
  }

  func testAttachmentRecordsAndSharedFilesSurviveReopen() async throws {
    try await withLibrary { directory, library in
      let sourceURL = directory.appendingPathComponent("note.txt")
      try Data("Attachment body".utf8).write(to: sourceURL)
      let added = try await library.perform(
        .add(
          content: "With file",
          origin: .quickEntry,
          source: SnipSource(applicationName: "Tests", windowTitle: "Contract"),
          listID: SnipList.inboxID,
          attachmentURLs: [sourceURL],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
      let attachment = try XCTUnwrap(added.snapshot.snips.first?.attachments.first)
      XCTAssertEqual(attachment.fileName, "note.txt")
      XCTAssertEqual(attachment.byteCount, 15)
      let storedURL = try XCTUnwrap(added.snapshot.attachmentURLs[attachment.id])
      XCTAssertEqual(
        try Data(contentsOf: storedURL), Data("Attachment body".utf8))

      _ = try await library.perform(
        .add(
          content: "Shares file",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [storedURL],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 200)
        ),
        sortedBy: .chronological
      )

      let reopened = try open(in: directory)
      let snapshot = await reopened.snapshot(sortedBy: .chronological)
      XCTAssertEqual(snapshot.snips.map(\.content), ["Shares file", "With file"])
      XCTAssertEqual(snapshot.snips.last?.source?.windowTitle, "Contract")
      XCTAssertEqual(
        snapshot.snips.flatMap(\.attachments).map(\.id), [attachment.id, attachment.id])
      let reopenedURL = try XCTUnwrap(snapshot.attachmentURLs[attachment.id])
      XCTAssertEqual(
        try Data(contentsOf: reopenedURL), Data("Attachment body".utf8))
    }
  }

  func testUnavailableLibraryRejectsWrites() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = SwiftDataSnipLibrary.unavailable(
      storeURL: directory.appendingPathComponent("unavailable.store")
    )
    await assertThrows(.storeUnavailable) {
      _ = try await library.perform(
        .add(
          content: "Must not appear",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
    }
    let snapshot = await library.snapshot(sortedBy: .chronological)
    XCTAssertTrue(snapshot.snips.isEmpty)
  }

  func testRemainingCommandRulesSurviveReopen() async throws {
    try await withLibrary { directory, library in
      let work = try await createList(named: "Work", in: library)
      let later = try await createList(named: "Later", in: library)
      let first = try await add("First", requestID: UUID(), at: 100, to: work.id, in: library)
      let second = try await add("Second", requestID: UUID(), at: 200, to: work.id, in: library)

      _ = try await library.perform(
        .updateList(id: work.id, name: "Focus", systemImage: "scope"),
        sortedBy: .manual
      )
      let editedAt = Date(timeIntervalSince1970: 300)
      _ = try await library.perform(
        .update(
          id: first.id,
          content: "Edited",
          attachmentURLs: nil,
          expectedUpdatedAt: first.updatedAt,
          now: editedAt
        ),
        sortedBy: .manual
      )
      _ = try await library.perform(
        .setDone(ids: [first.id, second.id], done: true),
        sortedBy: .manual
      )
      _ = try await library.perform(.setDone(ids: [second.id], done: false), sortedBy: .manual)
      _ = try await library.perform(
        .moveChronologically(ids: [first.id, second.id], to: later.id),
        sortedBy: .manual
      )
      _ = try await library.perform(
        .delete(ids: [second.id]),
        sortedBy: .manual
      )
      _ = try await library.perform(.restore(snips: [second]), sortedBy: .manual)

      let replacement = Snip(
        id: UUID(),
        requestID: UUID(),
        createdAt: Date(timeIntervalSince1970: 400),
        content: "Replacement",
        origin: .quickEntry,
        listID: later.id
      )
      let beforeReplacement = await library.snapshot(sortedBy: .manual)
      _ = try await library.perform(
        .delete(ids: Set(beforeReplacement.snips.map(\.id))),
        sortedBy: .manual
      )
      _ = try await library.perform(.restore(snips: [replacement]), sortedBy: .manual)

      let reopened = try open(in: directory)
      let snapshot = await reopened.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.lists.map(\.name), ["Inbox", "Focus", "Later"])
      XCTAssertEqual(snapshot.snips, [replacement])
    }
  }

  func testAttachmentPruningKeepsRetainedFilesAndRemovesTheRest() async throws {
    try await withLibrary { _, library in
      let sourceDirectory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: sourceDirectory) }
      let sourceURL = sourceDirectory.appendingPathComponent("remove-me.txt")
      try Data("Temporary".utf8).write(to: sourceURL)
      let added = try await library.perform(
        .add(
          content: "File",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [sourceURL],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
      let snip = try XCTUnwrap(added.snapshot.snips.first)
      let attachment = try XCTUnwrap(snip.attachments.first)
      let storedURL = try XCTUnwrap(added.snapshot.attachmentURLs[attachment.id])

      _ = try await library.perform(.delete(ids: [snip.id]), sortedBy: .chronological)
      XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
      _ = try await library.perform(
        .pruneAttachments(retaining: [attachment.id]),
        sortedBy: .chronological
      )
      XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
      _ = try await library.perform(
        .pruneAttachments(retaining: []),
        sortedBy: .chronological
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    }
  }

  func testEditingAttachmentsKeepsUnchangedFiles() async throws {
    try await withLibrary { directory, library in
      let sourceDirectory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: sourceDirectory) }
      let firstSource = sourceDirectory.appendingPathComponent("first.txt")
      let secondSource = sourceDirectory.appendingPathComponent("second.txt")
      let replacementSource = sourceDirectory.appendingPathComponent("replacement.txt")
      try Data("First".utf8).write(to: firstSource)
      try Data("Second".utf8).write(to: secondSource)
      try Data("Replacement".utf8).write(to: replacementSource)

      let added = try await library.perform(
        .add(
          content: "Two files",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [firstSource, secondSource],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
      let original = try XCTUnwrap(added.snapshot.snips.first)
      let first = try XCTUnwrap(original.attachments.first)
      let second = try XCTUnwrap(original.attachments.last)
      let firstStoredURL = try XCTUnwrap(added.snapshot.attachmentURLs[first.id])
      let secondStoredURL = try XCTUnwrap(added.snapshot.attachmentURLs[second.id])

      let edited = try await library.perform(
        .editAttachments(
          snipID: original.id,
          content: "Two files, revised",
          edits: [
            .replacement(attachmentID: first.id, sourceURL: replacementSource),
            .existing(attachmentID: second.id),
          ],
          expectedUpdatedAt: original.updatedAt,
          now: Date(timeIntervalSince1970: 200)
        ),
        sortedBy: .chronological
      )
      let revised = try XCTUnwrap(edited.snapshot.snips.first)
      XCTAssertEqual(revised.content, "Two files, revised")
      XCTAssertNotEqual(revised.attachments[0].id, first.id)
      XCTAssertEqual(revised.attachments[1].id, second.id)
      XCTAssertTrue(FileManager.default.fileExists(atPath: firstStoredURL.path))
      _ = try await library.perform(
        .pruneAttachments(retaining: []),
        sortedBy: .chronological
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: firstStoredURL.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: secondStoredURL.path))

      let reopened = try open(in: directory)
      let snapshot = await reopened.snapshot(sortedBy: .chronological)
      let reopenedSnip = try XCTUnwrap(snapshot.snips.first)
      XCTAssertEqual(reopenedSnip.attachments.map(\.id), revised.attachments.map(\.id))
      let replacementURL = try XCTUnwrap(snapshot.attachmentURLs[reopenedSnip.attachments[0].id])
      XCTAssertEqual(try Data(contentsOf: replacementURL), Data("Replacement".utf8))
      XCTAssertEqual(snapshot.attachmentURLs[second.id], secondStoredURL)
    }
  }

  func testSharedFileIsKeptUntilItsLastReferenceIsRemoved() async throws {
    try await withLibrary { _, library in
      let sourceDirectory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: sourceDirectory) }
      let sourceURL = sourceDirectory.appendingPathComponent("shared.txt")
      try Data("Shared".utf8).write(to: sourceURL)

      let firstAdd = try await library.perform(
        .add(
          content: "First reference",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [sourceURL],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
      let first = try XCTUnwrap(firstAdd.snapshot.snips.first)
      let attachment = try XCTUnwrap(first.attachments.first)
      let storedURL = try XCTUnwrap(firstAdd.snapshot.attachmentURLs[attachment.id])
      let secondAdd = try await library.perform(
        .add(
          content: "Second reference",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [storedURL],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 200)
        ),
        sortedBy: .chronological
      )
      let second = try XCTUnwrap(secondAdd.snapshot.snips.first(where: { $0.id != first.id }))
      XCTAssertEqual(second.attachments.first?.id, attachment.id)

      _ = try await library.perform(
        .guarded(
          expectation: SnipLibraryExpectation(expectedSnips: [first]),
          command: .batch([
            .editAttachments(
              snipID: first.id,
              content: first.content,
              edits: [],
              expectedUpdatedAt: first.updatedAt,
              now: Date(timeIntervalSince1970: 300)
            )
          ])
        ),
        sortedBy: .chronological
      )
      XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
      _ = try await library.perform(
        .pruneAttachments(retaining: []),
        sortedBy: .chronological
      )
      XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))

      _ = try await library.perform(
        .guarded(
          expectation: SnipLibraryExpectation(expectedSnips: [second]),
          command: .batch([
            .editAttachments(
              snipID: second.id,
              content: second.content,
              edits: [],
              expectedUpdatedAt: second.updatedAt,
              now: Date(timeIntervalSince1970: 400)
            )
          ])
        ),
        sortedBy: .chronological
      )
      _ = try await library.perform(
        .pruneAttachments(retaining: []),
        sortedBy: .chronological
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    }
  }

  func testEmptyMovesAreNoOpsBeforeListValidation() async throws {
    try await withLibrary { _, library in
      let missingList = UUID()
      _ = try await library.perform(
        .moveChronologically(ids: [], to: missingList),
        sortedBy: .manual
      )
      _ = try await library.perform(
        .place(ids: [], in: missingList, before: nil, basedOn: .manual),
        sortedBy: .manual
      )
      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.lists, [.inbox])
      XCTAssertTrue(snapshot.snips.isEmpty)
    }
  }

  func testRestoreRejectsMalformedSnipsWithoutTrapping() async throws {
    try await withLibrary { _, library in
      let original = try await add(
        "Original",
        requestID: UUID(),
        at: 100,
        to: SnipList.inboxID,
        in: library
      )
      let duplicateID = UUID()
      let duplicateSnips = [
        Snip(
          id: duplicateID,
          requestID: UUID(),
          createdAt: Date(timeIntervalSince1970: 200),
          content: "First duplicate",
          origin: .quickEntry
        ),
        Snip(
          id: duplicateID,
          requestID: UUID(),
          createdAt: Date(timeIntervalSince1970: 300),
          content: "Second duplicate",
          origin: .quickEntry
        ),
      ]
      await assertThrows(.invalidStore) {
        _ = try await library.perform(.restore(snips: duplicateSnips), sortedBy: .chronological)
      }

      let sharedAttachment = SnipAttachment(
        id: UUID(),
        fileName: "shared.txt",
        relativePath: "shared/shared.txt",
        contentType: "text/plain",
        byteCount: 6
      )
      let repeatedAttachment = Snip(
        requestID: UUID(),
        createdAt: Date(timeIntervalSince1970: 400),
        content: "Repeated attachment",
        origin: .quickEntry,
        attachments: [sharedAttachment, sharedAttachment]
      )
      await assertThrows(.invalidStore) {
        _ = try await library.perform(
          .restore(snips: [repeatedAttachment]),
          sortedBy: .chronological
        )
      }

      let sharedSnips = [
        Snip(
          requestID: UUID(),
          createdAt: Date(timeIntervalSince1970: 500),
          content: "Shares attachment one",
          origin: .quickEntry,
          attachments: [sharedAttachment]
        ),
        Snip(
          requestID: UUID(),
          createdAt: Date(timeIntervalSince1970: 600),
          content: "Shares attachment two",
          origin: .quickEntry,
          attachments: [sharedAttachment]
        ),
      ]
      let restored = try await library.perform(
        .restore(snips: sharedSnips),
        sortedBy: .chronological
      )
      XCTAssertEqual(restored.snapshot.snips.count, 3)
      XCTAssertEqual(
        restored.snapshot.snips.filter { $0.id != original.id }
          .flatMap(\.attachments).map(\.id),
        [sharedAttachment.id, sharedAttachment.id])
    }
  }

  func testDeletedRequestIDsAreRememberedAcrossReopen() async throws {
    try await withLibrary { directory, library in
      let requestID = UUID()
      let added = try await add(
        "One durable request",
        requestID: requestID,
        at: 100,
        to: SnipList.inboxID,
        in: library
      )
      _ = try await library.perform(.delete(ids: [added.id]), sortedBy: .chronological)

      let reopened = try open(in: directory)
      let retry = try await reopened.perform(
        .add(
          content: "Relaunch retry",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [],
          requestID: requestID,
          now: Date(timeIntervalSince1970: 200)
        ),
        sortedBy: .chronological
      )
      XCTAssertEqual(retry.outcome, .add(.duplicate))
      XCTAssertTrue(retry.snapshot.snips.isEmpty)
    }
  }

  func testSwiftDataAdaptersDoNotOverwriteEachOthersUnrelatedWrites() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("snips.store")
    let firstEnteredSaveHook = expectation(description: "First client entered save hook")
    let releaseFirstSave = DispatchSemaphore(value: 0)
    let first = try SwiftDataSnipLibrary(
      storeURL: storeURL,
      afterMutationBeforeSave: {
        firstEnteredSaveHook.fulfill()
        releaseFirstSave.wait()
      }
    )
    let second = try SwiftDataSnipLibrary(storeURL: storeURL)

    let firstWrite = Task.detached {
      try await first.perform(
        .add(
          content: "First client",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
    }
    await fulfillment(of: [firstEnteredSaveHook], timeout: 1)

    let secondStarted = expectation(description: "Second client started")
    let secondFinished = expectation(description: "Second client finished")
    secondFinished.isInverted = true
    let secondWrite = Task.detached {
      secondStarted.fulfill()
      defer { secondFinished.fulfill() }
      return try await second.perform(
        .add(
          content: "Second client",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 200)
        ),
        sortedBy: .chronological
      )
    }
    await fulfillment(of: [secondStarted], timeout: 1)
    await fulfillment(of: [secondFinished], timeout: 0.2)
    releaseFirstSave.signal()
    _ = try await firstWrite.value
    _ = try await secondWrite.value

    let snapshot = await first.snapshot(sortedBy: .chronological)
    XCTAssertEqual(snapshot.snips.map(\.content), ["Second client", "First client"])
  }

  func testSwiftDataSaveFailureRollsBackRecordsAndNewAttachmentFiles() async throws {
    enum InjectedFailure: Error { case save }
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("snips.store")
    let sourceURL = directory.appendingPathComponent("source.txt")
    let requestID = UUID()
    try Data("Must roll back".utf8).write(to: sourceURL)
    let library = try SwiftDataSnipLibrary(
      storeURL: storeURL,
      afterMutationBeforeSave: { throw InjectedFailure.save }
    )

    do {
      _ = try await library.perform(
        .add(
          content: "Failed write",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [sourceURL],
          requestID: requestID,
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
      XCTFail("Expected the injected save failure.")
    } catch is InjectedFailure {
    }

    let failedSnapshot = await library.snapshot(sortedBy: .chronological)
    XCTAssertTrue(failedSnapshot.snips.isEmpty)
    let attachmentRoot = directory.appendingPathComponent("Attachments", isDirectory: true)
    let remaining = try? FileManager.default.contentsOfDirectory(atPath: attachmentRoot.path)
    XCTAssertTrue(remaining?.isEmpty ?? true)
    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
    let reopenedSnapshot = await reopened.snapshot(sortedBy: .chronological)
    XCTAssertTrue(reopenedSnapshot.snips.isEmpty)
    let retry = try await reopened.perform(
      .add(
        content: "Retry after rollback",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: requestID,
        now: Date(timeIntervalSince1970: 200)
      ),
      sortedBy: .chronological
    )
    guard case .add(.added) = retry.outcome else {
      return XCTFail("Expected the rolled-back request ID to remain available.")
    }
  }

  func testSwiftDataStorePathKeepsJSONBackupSeparateAndFollowsDevSlotOverride() {
    let url = SwiftDataSnipLibrary.defaultStoreURL(
      fileManager: .default,
      environment: ["SNIP_SNAP_STORE_PATH": "/tmp/snip-snap-dev-slot/snips.json"]
    )
    XCTAssertEqual(url.path, "/tmp/snip-snap-dev-slot/Local/snips.store")
    XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Local")
    XCTAssertEqual(
      SwiftDataSnipLibrary.attachmentRootURL(forStoreURL: url).path,
      "/tmp/snip-snap-dev-slot/Local/Attachments"
    )
  }

  func testCloudDevStorePathSurvivesRelaunchWithoutEnvironment() {
    let url = SwiftDataSnipLibrary.defaultStoreURL(
      fileManager: .default,
      environment: [:],
      infoDictionary: ["SnipSnapDevelopmentStorePath": "/tmp/cloud-dev-slot-6/items.json"]
    )
    XCTAssertEqual(url.path, "/tmp/cloud-dev-slot-6/Local/snips.store")
    XCTAssertEqual(LocalSnipStorePaths(storeURL: url).rootDirectory.path, "/tmp/cloud-dev-slot-6")
  }

  func testCloudDevStorePathTakesPriorityOverLaunchEnvironment() {
    XCTAssertEqual(
      LocalSnipStorePaths.storePathOverride(
        environment: ["SNIP_SNAP_STORE_PATH": "/tmp/other-library/items.json"],
        infoDictionary: ["SnipSnapDevelopmentStorePath": "/tmp/cloud-dev/items.json"]
      ),
      "/tmp/cloud-dev/items.json"
    )
  }

  func testInvalidEmbeddedDevStorePathFallsBackToEnvironment() {
    for embedded in ["$(SNIP_SNAP_DEV_STORE_PATH)", "relative/items.json", ""] {
      XCTAssertEqual(
        LocalSnipStorePaths.storePathOverride(
          environment: ["SNIP_SNAP_STORE_PATH": "/tmp/local-dev/items.json"],
          infoDictionary: ["SnipSnapDevelopmentStorePath": embedded]
        ),
        "/tmp/local-dev/items.json"
      )
    }
  }

  func testSwiftDataRejectsAStoreWithRecordsButNoLists() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("snips.store")
    try makeRequestOnlySwiftDataStore(at: storeURL)

    XCTAssertThrowsError(try SwiftDataSnipLibrary(storeURL: storeURL)) { error in
      XCTAssertEqual(error as? SnipLibraryError, .invalidStore)
    }
  }

  func testSwiftDataV4StoreMigrationPreservesLibraryAndRequestHistory() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("snips.store")
    let work = SnipList(
      id: UUID(uuidString: "31313131-3131-3131-3131-313131313131")!,
      name: "Work",
      systemImage: "briefcase",
      position: 1
    )
    let attachment = SnipAttachment(
      id: UUID(uuidString: "32323232-3232-3232-3232-323232323232")!,
      fileName: "note.txt",
      relativePath: "32323232-3232-3232-3232-323232323232/note.txt",
      contentType: "public.plain-text",
      byteCount: 14
    )
    let requestID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let deletedRequestID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!
    let snip = Snip(
      id: UUID(uuidString: "35353535-3535-3535-3535-353535353535")!,
      requestID: requestID,
      createdAt: Date(timeIntervalSince1970: 100),
      content: "V4 text",
      origin: .quickEntry,
      listID: work.id,
      manualPosition: 7,
      attachments: [attachment]
    )
    let storedAttachmentURL = SwiftDataSnipLibrary.attachmentRootURL(forStoreURL: storeURL)
      .appendingPathComponent(attachment.relativePath)
    try FileManager.default.createDirectory(
      at: storedAttachmentURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("V4 attachment".utf8).write(to: storedAttachmentURL)

    do {
      let schema = Schema(versionedSchema: SnipSnapSchemaV4.self)
      let configuration = ModelConfiguration(
        "SnipSnapLocal",
        schema: schema,
        url: storeURL,
        cloudKitDatabase: .none
      )
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let context = ModelContext(container)
      context.autosaveEnabled = false
      context.insert(SnipSnapSchemaV4.StoredListRecord(.inbox))
      context.insert(SnipSnapSchemaV4.StoredListRecord(work))
      context.insert(StoredSnipRecord(snip))
      context.insert(StoredAttachmentRecord(attachment))
      context.insert(
        StoredSnipAttachmentReference(
          snipID: snip.id,
          attachmentID: attachment.id,
          position: 0
        )
      )
      context.insert(StoredRequestRecord(id: requestID))
      context.insert(StoredRequestRecord(id: deletedRequestID))
      try context.save()
    }

    let migrated = try SwiftDataSnipLibrary(storeURL: storeURL)
    let snapshot = await migrated.snapshot(sortedBy: .manual)
    let expected = SnipLibraryTransferSnapshot(
      revision: 0,
      snips: [snip],
      lists: [.inbox, work],
      attachmentData: [:]
    )
    XCTAssertEqual(snapshot.lists, expected.lists)
    XCTAssertEqual(snapshot.snips, expected.snips)
    let reopenedAttachmentURL = try XCTUnwrap(snapshot.attachmentURLs[attachment.id])
    XCTAssertEqual(try Data(contentsOf: reopenedAttachmentURL), Data("V4 attachment".utf8))
    let duplicate = try await migrated.perform(
      .add(
        content: "must stay blocked",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: deletedRequestID,
        now: Date(timeIntervalSince1970: 200)
      ),
      sortedBy: .manual
    )
    XCTAssertEqual(duplicate.outcome, .add(.duplicate))
  }

  func testV4OrderBackfillRetriesBeforeAndAfterItsDurableSave() async throws {
    for crashPoint in LibraryMetadataBackfillPoint.allCases {
      let directory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let storeURL = directory.appendingPathComponent("snips.store")
      let list = SnipList(id: UUID(), name: "Work", systemImage: "briefcase", position: 9)
      let first = Snip(content: "First", origin: .quickEntry, listID: list.id, manualPosition: 7)
      let second = Snip(content: "Second", origin: .quickEntry, listID: list.id, manualPosition: 7)
      try makeV4LibraryStore(at: storeURL, lists: [.inbox, list], snips: [second, first])

      XCTAssertThrowsError(
        try SwiftDataSnipLibrary(
          storeURL: storeURL,
          metadataBackfillHook: { point in
            if point == crashPoint { throw BackfillCrash.injected }
          }
        )
      )

      let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
      let snapshot = await reopened.snapshot(sortedBy: .manual)
      XCTAssertEqual(Set(snapshot.snips.map(\.manualSortKey)).count, 2)
      XCTAssertEqual(
        snapshot.snips.map(\.id),
        [first.id, second.id].sorted { $0.uuidString < $1.uuidString }
      )
      XCTAssertEqual(snapshot.lists.first { $0.id == list.id }?.desiredName, "Work")
    }
  }

  func testTransferPreservesListOrderFullSnipFieldsAndAttachmentBytes() async throws {
    try await withLibrary { _, library in
      let work = SnipList(id: UUID(), name: "Work", systemImage: "briefcase.fill", position: 3)
      let later = SnipList(id: UUID(), name: "Later", systemImage: "clock.fill", position: 9)
      let attachmentID = UUID()
      let bytes = Data([0, 1, 2, 3, 255])
      let attachment = SnipAttachment(
        id: attachmentID,
        fileName: "proof.bin",
        relativePath: "\(attachmentID.uuidString)/proof.bin",
        contentType: "application/octet-stream",
        byteCount: Int64(bytes.count)
      )
      let snip = Snip(
        id: UUID(),
        requestID: UUID(),
        createdAt: Date(timeIntervalSince1970: 10),
        updatedAt: Date(timeIntervalSince1970: 20),
        content: "all fields",
        origin: .agent,
        source: SnipSource(
          applicationName: "",
          agentContext: SnipAgentContext(
            sessionTitle: "Agent provenance",
            branchName: "feature/agent-context"
          )
        ),
        listID: work.id,
        isDone: true,
        manualPosition: 42,
        attachments: [attachment]
      )
      let source = SnipLibraryTransferSnapshot(
        revision: 7,
        snips: [snip],
        lists: [.inbox, work, later],
        attachmentData: [attachmentID: bytes]
      )

      let result = try await library.mergeTransferSnapshot(source, transitionID: UUID())
      let copied = try await library.transferSnapshot(revision: 8)

      XCTAssertEqual(result.approvedSnipIDs, [snip.id])
      XCTAssertEqual(copied.lists, source.lists)
      XCTAssertEqual(copied.snips, source.snips)
      XCTAssertEqual(copied.attachmentData, source.attachmentData)
    }
  }

  func testTransferRejectsAttachmentStableIDConflict() async throws {
    try await withLibrary { _, library in
      let attachmentID = UUID()
      let firstAttachment = SnipAttachment(
        id: attachmentID,
        fileName: "first.bin",
        relativePath: "\(attachmentID.uuidString)/first.bin",
        contentType: "application/octet-stream",
        byteCount: 1
      )
      let first = Snip(
        id: UUID(),
        content: "first",
        origin: .share,
        attachments: [firstAttachment]
      )
      _ = try await library.mergeTransferSnapshot(
        SnipLibraryTransferSnapshot(
          revision: 1,
          snips: [first],
          lists: [.inbox],
          attachmentData: [attachmentID: Data([1])]
        ),
        transitionID: UUID()
      )
      var conflictingAttachment = firstAttachment
      conflictingAttachment.fileName = "other.bin"
      let conflict = Snip(
        id: UUID(),
        content: "conflict",
        origin: .share,
        attachments: [conflictingAttachment]
      )

      await assertThrows(.transferConflict(.attachmentIdentity(attachmentID))) {
        _ = try await library.mergeTransferSnapshot(
          SnipLibraryTransferSnapshot(
            revision: 2,
            snips: [conflict],
            lists: [.inbox],
            attachmentData: [attachmentID: Data([2])]
          ),
          transitionID: UUID()
        )
      }
    }
  }

  func testSelectionKeepsItsWhitespaceWhileQuickEntryIsTrimmed() async throws {
    try await withLibrary { directory, library in
      _ = try await add("  selected line\n", at: 100, origin: .selection, in: library)
      _ = try await add("  quick thought\n", at: 200, in: library)
      let snapshot = try await open(in: directory).checkedSnapshot(sortedBy: .chronological)
      XCTAssertEqual(snapshot.snips.map(\.content), ["quick thought", "  selected line\n"])
    }
  }

  func testBlankEntryIsRejectedAsEmptyContent() async throws {
    try await withLibrary { _, library in
      await assertThrows(.emptyContent) {
        _ = try await self.add("  \n ", at: 100, in: library)
      }
      let snapshot = try await library.checkedSnapshot(sortedBy: .chronological)
      XCTAssertTrue(snapshot.snips.isEmpty)
    }
  }

  func testMergeReplacesSnipsWithOldestFirstContentAndSourceContext() async throws {
    try await withLibrary { directory, library in
      let first = try await add("First thought", at: 100, in: library)
      let second = try await add(
        "Second snippet", at: 200, origin: .selection,
        source: SnipSource(applicationName: "Safari", windowTitle: "Docs", url: "https://example.com/docs"),
        in: library)
      let update = try await library.perform(
        .merge(ids: [second.id, first.id], now: Date(timeIntervalSince1970: 300)), sortedBy: .manual)
      guard case .merged(let merged) = update.outcome else { return XCTFail("Expected merged snip") }
      XCTAssertEqual(
        merged.content,
        "First thought\n\n---\n\nSecond snippet\nSource: Safari — Docs\nURL: https://example.com/docs"
      )
      let reopened = try await open(in: directory).checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(reopened.snips, [merged])
    }
  }

  func testMergeListsAttachmentsNewestSnipFirstAndKeepsTheirFiles() async throws {
    try await withLibrary { directory, library in
      let firstSource = directory.appendingPathComponent("first.md")
      let secondSource = directory.appendingPathComponent("second.md")
      try Data("First".utf8).write(to: firstSource)
      try Data("Second".utf8).write(to: secondSource)
      let first = try await add("First snip", at: 100, attachmentURLs: [firstSource], in: library)
      let second = try await add("Second snip", at: 200, attachmentURLs: [secondSource], in: library)

      let update = try await library.perform(
        .merge(ids: [first.id, second.id], now: Date(timeIntervalSince1970: 300)), sortedBy: .manual)
      guard case .merged(let merged) = update.outcome else { return XCTFail("Expected merged snip") }

      XCTAssertEqual(merged.attachments.map(\.id), second.attachments.map(\.id) + first.attachments.map(\.id))
      _ = try await library.perform(.pruneAttachments(retaining: []), sortedBy: .manual)
      let reopened = try await open(in: directory).checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(
        try merged.attachments.map { try Data(contentsOf: XCTUnwrap(reopened.attachmentURLs[$0.id])) },
        [Data("Second".utf8), Data("First".utf8)]
      )
    }
  }

  func testMergeKeepsTheHighestSelectedManualPlace() async throws {
    // Manual order matches creation order: the merge takes the top selected place.
    try await withLibrary { _, library in
      let first = try await add("First", at: 100, in: library)
      let middle = try await add("Middle", at: 200, in: library)
      let last = try await add("Last", at: 300, in: library)
      _ = try await library.perform(
        .place(ids: [first.id, middle.id, last.id], in: SnipList.inboxID, before: nil, basedOn: .manual),
        sortedBy: .manual)
      let update = try await library.perform(
        .merge(ids: [first.id, last.id], now: Date(timeIntervalSince1970: 400)), sortedBy: .manual)
      guard case .merged(let merged) = update.outcome else { return XCTFail("Expected merged snip") }
      XCTAssertEqual(update.snapshot.snips.map(\.id), [merged.id, middle.id])
    }
    // Manual order differs from creation order: the saved manual place still wins.
    try await withLibrary { _, library in
      let old = try await add("Old", at: 100, in: library)
      let middle = try await add("Middle", at: 200, in: library)
      let new = try await add("New", at: 300, in: library)
      _ = try await library.perform(
        .place(ids: [old.id, new.id, middle.id], in: SnipList.inboxID, before: nil, basedOn: .manual),
        sortedBy: .manual)
      let update = try await library.perform(
        .merge(ids: [new.id, middle.id], now: Date(timeIntervalSince1970: 400)), sortedBy: .manual)
      guard case .merged(let merged) = update.outcome else { return XCTFail("Expected merged snip") }
      XCTAssertEqual(update.snapshot.snips.map(\.id), [old.id, merged.id])
    }
  }

  func testDeletedSnipRestoresWithIdentityAndStateAcrossReopen() async throws {
    try await withLibrary { directory, library in
      let work = try await createList(named: "Work", in: library)
      let added = try await add(
        "Recover me", at: 100, to: work.id, origin: .selection,
        source: SnipSource(applicationName: "Safari", windowTitle: "Docs"), in: library)
      let done = try await library.perform(.setDone(ids: [added.id], done: true), sortedBy: .manual)
      let snip = try XCTUnwrap(done.snapshot.snips.first { $0.id == added.id })
      XCTAssertTrue(snip.isDone)

      let deleted = try await library.perform(.delete(ids: [snip.id]), sortedBy: .manual)
      XCTAssertTrue(deleted.snapshot.snips.isEmpty)
      _ = try await library.perform(.restore(snips: [snip]), sortedBy: .manual)

      let reopened = try await open(in: directory).checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(reopened.snips, [snip])
    }
  }

  func testSnipMoveToAMissingListFailsAndListRenameKeepsMembership() async throws {
    try await withLibrary { directory, library in
      let review = try await createList(named: "Review", in: library)
      let snip = try await add("Keep linked", at: 100, to: review.id, in: library)
      _ = try await library.perform(
        .updateList(id: review.id, name: "Agents", systemImage: "terminal"), sortedBy: .manual)

      let renamed = try await library.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(renamed.snips.map(\.listID), [review.id])
      await assertThrows(.invalidList) {
        _ = try await library.perform(.moveChronologically(ids: [snip.id], to: UUID()), sortedBy: .manual)
      }
      let reopened = try await open(in: directory).checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(reopened, renamed)
      XCTAssertEqual(reopened.lists.map(\.name), ["Inbox", "Agents"])
    }
  }

  func testPlacingABatchBeforeASnipInAnotherListPersistsTheExactOrder() async throws {
    try await withLibrary { directory, library in
      let first = try await add("First", at: 100, in: library)
      let second = try await add("Second", at: 200, in: library)
      let target = try await add("Target", at: 300, in: library)
      let review = try await createList(named: "Review", in: library)
      _ = try await library.perform(.moveChronologically(ids: [target.id], to: review.id), sortedBy: .manual)

      _ = try await library.perform(
        .place(ids: [first.id, second.id], in: review.id, before: target.id, basedOn: .manual),
        sortedBy: .manual)

      let reopened = try await open(in: directory).checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(reopened.snips.filter { $0.listID == review.id }.map(\.id), [first.id, second.id, target.id])
    }
  }

  func testChronologicalMoveKeepsTheEditTokenAndPutsTheBatchAtTheManualTopInCallOrder() async throws {
    try await withLibrary { _, library in
      let review = try await createList(named: "Review", in: library)
      let existing = try await add("Existing", at: 100, in: library)
      _ = try await library.perform(.moveChronologically(ids: [existing.id], to: review.id), sortedBy: .manual)
      let first = try await add("First", at: 200, in: library)
      let second = try await add("Second", at: 300, in: library)

      let moved = try await library.perform(
        .moveChronologically(ids: [first.id, second.id], to: review.id), sortedBy: .manual)

      let manual = moved.snapshot.snips.filter { $0.listID == review.id }
      XCTAssertEqual(manual.map(\.id), [first.id, second.id, existing.id])
      XCTAssertEqual(manual.map(\.updatedAt), [first.updatedAt, second.updatedAt, existing.updatedAt])
    }
  }

  private func withLibrary(
    _ body: (URL, SwiftDataSnipLibrary) async throws -> Void
  ) async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory, open(in: directory))
  }

  private func open(in directory: URL) throws -> SwiftDataSnipLibrary {
    try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
  }

  private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnipLibraryBehaviorTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeRequestOnlySwiftDataStore(at storeURL: URL) throws {
    let schema = Schema(versionedSchema: SnipSnapSchemaV4.self)
    let configuration = ModelConfiguration(
      "SnipSnapLocal",
      schema: schema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    context.autosaveEnabled = false
    context.insert(StoredRequestRecord(id: UUID()))
    try context.save()
  }

  private func makeV4LibraryStore(
    at storeURL: URL,
    lists: [SnipList],
    snips: [Snip]
  ) throws {
    let schema = Schema(versionedSchema: SnipSnapSchemaV4.self)
    let configuration = ModelConfiguration(
      "SnipSnapLocal",
      schema: schema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    context.autosaveEnabled = false
    for list in lists { context.insert(SnipSnapSchemaV4.StoredListRecord(list)) }
    for snip in snips { context.insert(StoredSnipRecord(snip)) }
    try context.save()
  }

  private func createList(named name: String, in library: any SnipLibrary) async throws -> SnipList
  {
    let update = try await library.perform(
      .createList(name: name, systemImage: "briefcase"),
      sortedBy: .chronological
    )
    guard case .listCreated(let list) = update.outcome else {
      throw TestFailure.unexpectedOutcome
    }
    return list
  }

  private func add(
    _ content: String,
    requestID: UUID = UUID(),
    at timestamp: TimeInterval,
    to listID: UUID = SnipList.inboxID,
    origin: SnipOrigin = .quickEntry,
    source: SnipSource? = nil,
    attachmentURLs: [URL] = [],
    in library: any SnipLibrary
  ) async throws -> Snip {
    let update = try await library.perform(
      .add(
        content: content,
        origin: origin,
        source: source,
        listID: listID,
        attachmentURLs: attachmentURLs,
        requestID: requestID,
        now: Date(timeIntervalSince1970: timestamp)
      ),
      sortedBy: .chronological
    )
    guard case .add(.added(let id)) = update.outcome,
      let snip = update.snapshot.snips.first(where: { $0.id == id })
    else {
      throw TestFailure.unexpectedOutcome
    }
    return snip
  }

  private func assertThrows(
    _ expected: SnipLibraryError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, expected)
    }
  }

  private enum TestFailure: Error {
    case unexpectedOutcome
  }

  private enum BackfillCrash: Error {
    case injected
  }
}
