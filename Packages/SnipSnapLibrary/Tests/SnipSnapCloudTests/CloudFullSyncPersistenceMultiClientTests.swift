import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

extension CloudFullSyncPersistenceTests {
  func testTwoDurableClientsExchangeFullSnipAndListRecords() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullSyncPersistenceTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let firstLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("first.store"))
    let secondLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("second.store"))
    let created = try await firstLibrary.perform(
      .createList(name: "Work", systemImage: "briefcase"),
      sortedBy: .manual
    )
    guard case .listCreated(let list) = created.outcome else {
      return XCTFail("Expected a list")
    }
    _ = try await firstLibrary.perform(
      .add(
        content: "full record",
        origin: .clipboard,
        source: SnipSource(applicationName: "Notes", windowTitle: "Draft", url: "notes://1"),
        listID: list.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 10)
      ),
      sortedBy: .manual
    )
    let seeded = await firstLibrary.snapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(seeded.snips.first)
    _ = try await firstLibrary.perform(.setDone(ids: [snip.id], done: true), sortedBy: .manual)

    let firstPersistence = CloudFullSyncPersistence(
      library: firstLibrary,
      namespace: namespace,
      dataZone: zone,
      now: { Date(timeIntervalSince1970: 20) }
    )
    try await firstPersistence.approveEnrollment(
      references: [
        CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
        CloudEntityReference(kind: .list, domainID: list.id),
        CloudEntityReference(kind: .snip, domainID: snip.id),
      ]
    )
    let firstCoordinator = CloudFullSyncCoordinator(
      store: firstPersistence,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await firstCoordinator.sync()

    let secondPersistence = CloudFullSyncPersistence(
      library: secondLibrary,
      namespace: namespace,
      dataZone: zone,
      now: { Date(timeIntervalSince1970: 30) }
    )
    let secondCoordinator = CloudFullSyncCoordinator(
      store: secondPersistence,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await secondCoordinator.fetchRemote()

    let received = await secondLibrary.snapshot(sortedBy: .manual)
    let receivedList = try XCTUnwrap(received.lists.first(where: { $0.id == list.id }))
    let receivedSnip = try XCTUnwrap(received.snips.first(where: { $0.id == snip.id }))
    XCTAssertEqual(receivedList.desiredName, "Work")
    XCTAssertEqual(receivedList.systemImage, "briefcase")
    XCTAssertEqual(receivedSnip.content, "full record")
    XCTAssertEqual(receivedSnip.origin, .clipboard)
    XCTAssertEqual(receivedSnip.source?.applicationName, "Notes")
    XCTAssertEqual(receivedSnip.source?.windowTitle, "Draft")
    XCTAssertEqual(receivedSnip.source?.url, "notes://1")
    XCTAssertEqual(receivedSnip.listID, list.id)
    XCTAssertTrue(receivedSnip.isDone)
    XCTAssertEqual(receivedSnip.manualSortKey, snip.manualSortKey)

    let cleared = Snip(
      id: receivedSnip.id,
      requestID: receivedSnip.requestID,
      createdAt: receivedSnip.createdAt,
      updatedAt: Date(timeIntervalSince1970: 40),
      content: "edited",
      origin: receivedSnip.origin,
      source: nil,
      listID: SnipList.inbox.id,
      isDone: false,
      manualSortKey: receivedSnip.manualSortKey
    )
    _ = try await secondLibrary.perform(.replaceAll([cleared]), sortedBy: .manual)
    try await secondCoordinator.sync()
    try await firstCoordinator.fetchRemote()
    let editedSnapshot = await firstLibrary.snapshot(sortedBy: .manual)
    let edited = try XCTUnwrap(editedSnapshot.snips.first(where: { $0.id == snip.id }))
    XCTAssertEqual(edited.content, "edited")
    XCTAssertNil(edited.source)
    XCTAssertEqual(edited.listID, SnipList.inbox.id)
    XCTAssertFalse(edited.isDone)

    _ = try await secondLibrary.perform(.delete(ids: [snip.id]), sortedBy: .manual)
    _ = try await secondLibrary.perform(.deleteList(id: list.id), sortedBy: .manual)
    try await secondCoordinator.sync()
    try await firstCoordinator.fetchRemote()
    let deleted = await firstLibrary.snapshot(sortedBy: .manual)
    XCTAssertFalse(deleted.snips.contains(where: { $0.id == snip.id }))
    XCTAssertFalse(deleted.lists.contains(where: { $0.id == list.id }))
  }

  func testTwoClientsSeedSameDomainIDCreatesDurableFieldConflict() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullSameDomainTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let sharedID = UUID()
    let firstSnip = Snip(id: sharedID, content: "first seed", origin: .quickEntry)
    let secondSnip = Snip(id: sharedID, content: "second seed", origin: .quickEntry)
    let firstLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("first.store"))
    let secondLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("second.store"))
    _ = try await firstLibrary.perform(.replaceAll([firstSnip]), sortedBy: .manual)
    _ = try await secondLibrary.perform(.replaceAll([secondSnip]), sortedBy: .manual)
    let reference = CloudEntityReference(kind: .snip, domainID: sharedID)
    let enrollment: Set<CloudEntityReference> = [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      reference,
    ]
    let firstStore = CloudFullSyncPersistence(
      library: firstLibrary,
      namespace: namespace,
      dataZone: zone
    )
    let secondStore = CloudFullSyncPersistence(
      library: secondLibrary,
      namespace: namespace,
      dataZone: zone
    )
    try await firstStore.approveEnrollment(references: enrollment)
    try await secondStore.approveEnrollment(references: enrollment)
    let first = CloudFullSyncCoordinator(
      store: firstStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    let second = CloudFullSyncCoordinator(
      store: secondStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await first.sendPending()
    try await second.sendPending()

    let secondLocal = await secondLibrary.snapshot(sortedBy: .manual)
    XCTAssertEqual(secondLocal.snips.first(where: { $0.id == sharedID })?.content, "first seed")
    let stored = try await secondLibrary.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    let conflict = try XCTUnwrap(stored.conflicts.first(where: { $0.reference == reference }))
    let payload = try JSONDecoder().decode(CloudSnipConflictPayload.self, from: conflict.payload)
    XCTAssertEqual(payload.local.text, "second seed")
    XCTAssertEqual(payload.server.text, "first seed")
    XCTAssertEqual(payload.fields, [.text, .source, .isDone, .placement])
    let count = await server.acceptedOperationCount(for: CloudRecordID.snip(sharedID, in: zone))
    XCTAssertEqual(count, 1)
  }

  func testTwoClientsSeedSameDomainAndValueAdoptsWithoutConflict() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullSameValueSeedTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let shared = Snip(content: "same seed", origin: .quickEntry)
    let firstLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("first.store"))
    let secondLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("second.store"))
    _ = try await firstLibrary.perform(.replaceAll([shared]), sortedBy: .manual)
    _ = try await secondLibrary.perform(.replaceAll([shared]), sortedBy: .manual)
    let enrollment: Set<CloudEntityReference> = [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: shared.id),
    ]
    let firstStore = CloudFullSyncPersistence(
      library: firstLibrary,
      namespace: namespace,
      dataZone: zone
    )
    let secondStore = CloudFullSyncPersistence(
      library: secondLibrary,
      namespace: namespace,
      dataZone: zone
    )
    try await firstStore.approveEnrollment(references: enrollment)
    try await secondStore.approveEnrollment(references: enrollment)
    let first = CloudFullSyncCoordinator(
      store: firstStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    let second = CloudFullSyncCoordinator(
      store: secondStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await first.sendPending()
    try await second.sendPending()

    let stored = try await secondLibrary.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    let pending = try await secondStore.pendingChanges()
    XCTAssertTrue(stored.conflicts.isEmpty)
    XCTAssertTrue(pending.operations.isEmpty)
    let count = await server.acceptedOperationCount(for: .snip(shared.id, in: zone))
    XCTAssertEqual(count, 1)
  }

  func testThreeDurableClientsResolveEqualListNamesAcrossBatchPartitions() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullThreeClientNames-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let firstLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("first.store"))
    let secondLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("second.store"))
    let thirdLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("third.store"))
    let keys = try SnipOrderKey.rebalanced(count: 2)
    let firstList = SnipList(
      id: UUID(),
      desiredName: "Shared",
      resolvedName: "Shared",
      systemImage: "folder",
      sortKey: keys[0]
    )
    let secondList = SnipList(
      id: UUID(),
      desiredName: "Shared",
      resolvedName: "Shared 2",
      systemImage: "tray",
      sortKey: keys[1]
    )
    let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
    try await writer.start(state: nil)
    let firstDraft = try CloudFullRecordCodec.listDraft(
      firstList,
      updatedAt: .distantPast,
      in: zone
    )
    let secondDraft = try CloudFullRecordCodec.listDraft(
      secondList,
      updatedAt: .distantPast,
      in: zone
    )
    let seeded = try await writer.send(
      CloudOutboundBatch(operations: [.save(secondDraft), .save(firstDraft)])
    )
    try await writer.confirmApplied(seeded.id)
    let firstStore = CloudFullSyncPersistence(
      library: firstLibrary,
      namespace: namespace,
      dataZone: zone
    )
    let first = CloudFullSyncCoordinator(
      store: firstStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await first.fetchRemote()

    let secondStore = CloudFullSyncPersistence(
      library: secondLibrary,
      namespace: namespace,
      dataZone: zone
    )
    let second = CloudFullSyncCoordinator(
      store: secondStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await second.fetchRemote()

    let thirdStore = CloudFullSyncPersistence(
      library: thirdLibrary,
      namespace: namespace,
      dataZone: zone
    )
    var snapshots: [CloudRecordSnapshot] = []
    for id in [firstList.id, secondList.id] {
      let value = await server.fullSnapshot(for: CloudRecordID.list(id, in: zone))
      snapshots.append(try XCTUnwrap(value))
    }
    for snapshot in snapshots.reversed() {
      let batch = CloudFetchedBatch(id: UUID(), items: [.record(snapshot)], engineState: nil)
      try await thirdStore.stage(.fetched(batch))
      try await thirdStore.applyStaged(batch.id)
    }

    let expected = Self.listNames(await firstLibrary.snapshot(sortedBy: .manual), ids: [firstList.id, secondList.id])
    let secondNames = Self.listNames(await secondLibrary.snapshot(sortedBy: .manual), ids: [firstList.id, secondList.id])
    let thirdNames = Self.listNames(await thirdLibrary.snapshot(sortedBy: .manual), ids: [firstList.id, secondList.id])
    XCTAssertEqual(secondNames, expected)
    XCTAssertEqual(thirdNames, expected)
    XCTAssertEqual(Set(expected.map(\.desiredName)), ["Shared"])
    XCTAssertEqual(Set(expected.map(\.name)), ["Shared", "Shared (2)"])
  }

  func testThreeClientsMergeIndependentGroupsSuppressOrderOnlyConflictAndStopOnTextDivergence() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullThreeClientMerge-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let work = SnipList(id: UUID(), name: "Work", systemImage: "briefcase", position: 1)
    let base = Snip(content: "base", origin: .quickEntry)
    let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
    try await writer.start(state: nil)
    let seed = try await writer.send(CloudOutboundBatch(operations: [
      .save(try CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)),
      .save(try CloudFullRecordCodec.listDraft(work, updatedAt: .distantPast, in: zone)),
      .save(try CloudFullRecordCodec.snipDraft(base, in: zone)),
    ]))
    try await writer.confirmApplied(seed.id)

    let firstLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("first.store"))
    let secondLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("second.store"))
    let thirdLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("third.store"))
    let firstStore = CloudFullSyncPersistence(library: firstLibrary, namespace: namespace, dataZone: zone)
    let secondStore = CloudFullSyncPersistence(library: secondLibrary, namespace: namespace, dataZone: zone)
    let thirdStore = CloudFullSyncPersistence(library: thirdLibrary, namespace: namespace, dataZone: zone)
    let first = CloudFullSyncCoordinator(
      store: firstStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    let second = CloudFullSyncCoordinator(
      store: secondStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    let third = CloudFullSyncCoordinator(
      store: thirdStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await first.fetchRemote()
    try await second.fetchRemote()
    try await third.fetchRemote()
    let firstBaseSnapshot = await firstLibrary.snapshot(sortedBy: .manual)
    let secondBaseSnapshot = await secondLibrary.snapshot(sortedBy: .manual)
    let thirdBaseSnapshot = await thirdLibrary.snapshot(sortedBy: .manual)
    let firstBase = try XCTUnwrap(firstBaseSnapshot.snips.first)
    let secondBase = try XCTUnwrap(secondBaseSnapshot.snips.first)
    let thirdBase = try XCTUnwrap(thirdBaseSnapshot.snips.first)

    _ = try await firstLibrary.perform(
      .replaceAll([Self.copy(firstBase, content: "text edit")]),
      sortedBy: .manual
    )
    _ = try await secondLibrary.perform(
      .replaceAll([Self.copy(
        secondBase,
        source: SnipSource(applicationName: "Notes", windowTitle: "Draft"),
        isDone: true
      )]),
      sortedBy: .manual
    )
    _ = try await thirdLibrary.perform(
      .replaceAll([Self.copy(
        thirdBase,
        listID: work.id,
        orderKey: SnipOrderKey(rawDigits: [96])
      )]),
      sortedBy: .manual
    )
    try await first.sendPending()
    try await second.sendPending()
    try await second.sendPending()
    try await third.sendPending()
    try await third.sendPending()
    try await first.fetchRemote()
    try await second.fetchRemote()

    for library in [firstLibrary, secondLibrary, thirdLibrary] {
      let snapshot = await library.snapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(snapshot.snips.first(where: { $0.id == base.id }))
      XCTAssertEqual(snip.content, "text edit")
      XCTAssertEqual(snip.source?.applicationName, "Notes")
      XCTAssertTrue(snip.isDone)
      XCTAssertEqual(snip.listID, work.id)
      XCTAssertEqual(snip.manualSortKey, SnipOrderKey(rawDigits: [96]))
      let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
      XCTAssertTrue(stored.conflicts.isEmpty)
    }

    let firstFinalSnapshot = await firstLibrary.snapshot(sortedBy: .manual)
    let secondFinalSnapshot = await secondLibrary.snapshot(sortedBy: .manual)
    let firstFinal = try XCTUnwrap(firstFinalSnapshot.snips.first)
    let secondFinal = try XCTUnwrap(secondFinalSnapshot.snips.first)
    _ = try await firstLibrary.perform(
      .replaceAll([Self.copy(firstFinal, orderKey: SnipOrderKey(rawDigits: [80]))]),
      sortedBy: .manual
    )
    _ = try await secondLibrary.perform(
      .replaceAll([Self.copy(secondFinal, orderKey: SnipOrderKey(rawDigits: [112]))]),
      sortedBy: .manual
    )
    try await first.sendPending()
    try await second.sendPending()
    let afterOrder = try await secondLibrary.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    XCTAssertTrue(afterOrder.conflicts.isEmpty)
    let secondAfterOrder = await secondLibrary.snapshot(sortedBy: .manual)
    XCTAssertEqual(secondAfterOrder.snips.first?.manualSortKey, SnipOrderKey(rawDigits: [80]))

    try await third.fetchRemote()
    let secondForTextSnapshot = await secondLibrary.snapshot(sortedBy: .manual)
    let thirdForTextSnapshot = await thirdLibrary.snapshot(sortedBy: .manual)
    let secondForText = try XCTUnwrap(secondForTextSnapshot.snips.first)
    let thirdForText = try XCTUnwrap(thirdForTextSnapshot.snips.first)
    _ = try await secondLibrary.perform(
      .replaceAll([Self.copy(secondForText, content: "second text")]),
      sortedBy: .manual
    )
    _ = try await thirdLibrary.perform(
      .replaceAll([Self.copy(thirdForText, content: "third text")]),
      sortedBy: .manual
    )
    try await second.sendPending()
    try await third.sendPending()
    let thirdStored = try await thirdLibrary.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    let textConflict = try XCTUnwrap(thirdStored.conflicts.last)
    let payload = try JSONDecoder().decode(CloudSnipConflictPayload.self, from: textConflict.payload)
    XCTAssertEqual(payload.fields, [.text])
    let thirdAfterConflict = await thirdLibrary.snapshot(sortedBy: .manual)
    XCTAssertEqual(thirdAfterConflict.snips.first?.content, "second text")
    let blocked = try await thirdStore.pendingChanges()
    XCTAssertTrue(blocked.operations.isEmpty)
  }

}

