import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

extension CloudFullSyncPersistenceTests {
  func testMoveIntoDeletedListConvergesToInboxForFetchFirstAndSendFirst() async throws {
    for fetchFirst in [true, false] {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudDeletedListMove-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let namespace = makeNamespace()
      let zone = try XCTUnwrap(namespace.zones.first)
      let server = FakeCloudServer()
      let deletingLibrary = try SwiftDataSnipLibrary(
        storeURL: root.appendingPathComponent("deleting.store")
      )
      let editingLibrary = try SwiftDataSnipLibrary(
        storeURL: root.appendingPathComponent("editing.store")
      )
      let created = try await deletingLibrary.perform(
        .createList(name: "Soon Deleted", systemImage: "trash"),
        sortedBy: .manual
      )
      guard case .listCreated(let list) = created.outcome else {
        return XCTFail("Expected a List")
      }
      let survivingCreated = try await deletingLibrary.perform(
        .createList(name: "Still Here", systemImage: "archivebox"),
        sortedBy: .manual
      )
      guard case .listCreated(let survivingList) = survivingCreated.outcome else {
        return XCTFail("Expected a surviving List")
      }
      let added = try await deletingLibrary.perform(
        .add(
          content: "keep me",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inbox.id,
          attachmentURLs: [],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 1)
        ),
        sortedBy: .manual
      )
      guard case .add(.added(let snipID)) = added.outcome else {
        return XCTFail("Expected a Snip")
      }
      let deletingStore = CloudFullSyncPersistence(
        library: deletingLibrary,
        namespace: namespace,
        dataZone: zone
      )
      try await deletingStore.approveEnrollment(references: [
        CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
        CloudEntityReference(kind: .list, domainID: list.id),
        CloudEntityReference(kind: .list, domainID: survivingList.id),
        CloudEntityReference(kind: .snip, domainID: snipID),
      ])
      let deletingClient = CloudFullSyncCoordinator(
        store: deletingStore,
        transport: FakeCloudRecordTransport(server: server, namespace: namespace)
      )
      let editingStore = CloudFullSyncPersistence(
        library: editingLibrary,
        namespace: namespace,
        dataZone: zone
      )
      let editingClient = CloudFullSyncCoordinator(
        store: editingStore,
        transport: FakeCloudRecordTransport(server: server, namespace: namespace)
      )
      try await deletingClient.sync()
      try await editingClient.fetchRemote()
      _ = try await editingLibrary.perform(
        .place(ids: [snipID], in: list.id, before: nil, basedOn: .manual),
        sortedBy: .manual
      )
      _ = try await deletingLibrary.perform(.deleteList(id: list.id), sortedBy: .manual)
      try await deletingClient.sendPending()

      if fetchFirst {
        try await editingClient.fetchRemote()
      } else {
        try await editingClient.sendPending()
        try await editingClient.fetchRemote()
      }

      let local = await editingLibrary.snapshot(sortedBy: .manual)
      XCTAssertFalse(local.lists.contains { $0.id == list.id })
      XCTAssertEqual(local.snips.first(where: { $0.id == snipID })?.listID, SnipList.inbox.id)
      let recovery = try await editingLibrary.cloudFullRecoveryEvents(
        namespaceKey: namespace.canonicalKey
      )
      let evidence = try await editingStore.enrollmentEvidence()
      XCTAssertEqual(recovery.filter { $0.kind == .deletedListPlacement }.count, 1)
      XCTAssertTrue(evidence.needsAttention)

      let expectedListID: UUID
      if fetchFirst {
        expectedListID = SnipList.inbox.id
      } else {
        _ = try await editingLibrary.perform(
          .place(ids: [snipID], in: survivingList.id, before: nil, basedOn: .manual),
          sortedBy: .manual
        )
        expectedListID = survivingList.id
      }

      let reopenedLibrary = try SwiftDataSnipLibrary(
        storeURL: root.appendingPathComponent("editing.store")
      )
      let reopenedStore = CloudFullSyncPersistence(
        library: reopenedLibrary,
        namespace: namespace,
        dataZone: zone
      )
      let reopened = CloudFullSyncCoordinator(
        store: reopenedStore,
        transport: FakeCloudRecordTransport(server: server, namespace: namespace)
      )
      try await reopened.sendPending()
      try await deletingClient.fetchRemote()

      let converged = await deletingLibrary.snapshot(sortedBy: .manual)
      XCTAssertFalse(converged.lists.contains { $0.id == list.id })
      XCTAssertEqual(
        converged.snips.first(where: { $0.id == snipID })?.listID,
        expectedListID
      )
      let serverList = await server.fullSnapshot(for: .list(list.id, in: zone))
      let serverSnipValue = await server.fullSnapshot(for: .snip(snipID, in: zone))
      let serverSnip = try XCTUnwrap(serverSnipValue)
      let typedSnip = try CloudFullRecordCodec.snip(from: serverSnip)
      guard case .value(let placement) = typedSnip.placement else {
        return XCTFail("Expected synced placement")
      }
      XCTAssertNil(serverList)
      XCTAssertEqual(placement.listID, expectedListID)
    }
  }

  func testOfflineEditOfDeletedSnipRecoversForFetchFirstAndSendFirst() async throws {
    for fetchFirst in [true, false] {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudDeleteRecovery-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let namespace = makeNamespace()
      let zone = try XCTUnwrap(namespace.zones.first)
      let server = FakeCloudServer()
      let deletingLibrary = try SwiftDataSnipLibrary(
        storeURL: root.appendingPathComponent("deleting.store")
      )
      let editingLibrary = try SwiftDataSnipLibrary(
        storeURL: root.appendingPathComponent("editing.store")
      )
      let added = try await deletingLibrary.perform(
        .add(
          content: "base",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inbox.id,
          attachmentURLs: [],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 1)
        ),
        sortedBy: .manual
      )
      guard case .add(.added(let originalID)) = added.outcome else {
        return XCTFail("Expected a Snip")
      }
      let deletingStore = CloudFullSyncPersistence(
        library: deletingLibrary,
        namespace: namespace,
        dataZone: zone
      )
      try await deletingStore.approveEnrollment(references: [
        CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
        CloudEntityReference(kind: .snip, domainID: originalID),
      ])
      let deletingClient = CloudFullSyncCoordinator(
        store: deletingStore,
        transport: FakeCloudRecordTransport(server: server, namespace: namespace)
      )
      let editingStore = CloudFullSyncPersistence(
        library: editingLibrary,
        namespace: namespace,
        dataZone: zone
      )
      let editingClient = CloudFullSyncCoordinator(
        store: editingStore,
        transport: FakeCloudRecordTransport(server: server, namespace: namespace)
      )
      try await deletingClient.sync()
      try await editingClient.fetchRemote()
      let receivedSnapshot = await editingLibrary.snapshot(sortedBy: .manual)
      let received = try XCTUnwrap(receivedSnapshot.snips.first)
      _ = try await editingLibrary.perform(
        .update(
          id: originalID,
          content: fetchFirst ? "fetch-first edit" : "send-first edit",
          attachmentURLs: nil,
          expectedUpdatedAt: received.updatedAt,
          now: Date(timeIntervalSince1970: 2)
        ),
        sortedBy: .manual
      )
      _ = try await deletingLibrary.perform(.delete(ids: [originalID]), sortedBy: .manual)
      try await deletingClient.sendPending()

      if fetchFirst {
        try await editingClient.fetchRemote()
      } else {
        try await editingClient.sendPending()
      }

      let recoveredSnapshot = await editingLibrary.snapshot(sortedBy: .manual)
      XCTAssertFalse(recoveredSnapshot.snips.contains { $0.id == originalID })
      let recovered = try XCTUnwrap(recoveredSnapshot.snips.first)
      XCTAssertNotEqual(recovered.id, originalID)
      XCTAssertEqual(
        recovered.content,
        fetchFirst ? "fetch-first edit" : "send-first edit"
      )
      XCTAssertEqual(recovered.listID, SnipList.inbox.id)
      let review = try await editingLibrary.recoverySnapshot(
        in: SnipRecoveryScope(namespace.canonicalKey)
      )
      XCTAssertEqual(review.promotedSnips.map(\.id), [recovered.id])
      XCTAssertEqual(review.promotedSnips.map(\.currentSnipID), [originalID])

      try await editingClient.sendPending()
      try await deletingClient.fetchRemote()
      let converged = await deletingLibrary.snapshot(sortedBy: .manual)
      XCTAssertFalse(converged.snips.contains { $0.id == originalID })
      XCTAssertEqual(converged.snips.first?.id, recovered.id)
      XCTAssertEqual(converged.snips.first?.content, recovered.content)
      let deletedServerValue = await server.fullSnapshot(for: .snip(originalID, in: zone))
      let recoveredServerValue = await server.fullSnapshot(for: .snip(recovered.id, in: zone))
      XCTAssertNil(deletedServerValue)
      XCTAssertNotNil(recoveredServerValue)
    }
  }

  func testConfirmedImportConvergesAcrossClients() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullImportTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("backup.json"))
    let imported = Snip(
      content: "from backup",
      origin: .quickEntry
    )
    _ = try await source.perform(.restore(snips: [imported]), sortedBy: .manual)
    let firstLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("first.store"))
    let secondLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("second.store"))
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
    let inbox: Set<CloudEntityReference> = [
      CloudEntityReference(kind: .list, domainID: SnipList.inboxID)
    ]
    try await firstStore.approveEnrollment(references: inbox)
    try await secondStore.approveEnrollment(references: inbox)
    let first = CloudFullSyncCoordinator(
      store: firstStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    let second = CloudFullSyncCoordinator(
      store: secondStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await first.sync()
    try await second.fetchRemote()

    let preview = try await SnipLibraryImport.preview(source: source, target: firstLibrary)
    let actions = DirectSnipLibraryUserActions(library: firstLibrary)
    _ = try await actions.applyImport(preview, sortedBy: .manual)
    try await first.sendPending()
    try await second.fetchRemote()

    for library in [firstLibrary, secondLibrary] {
      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.snips.map(\.content), ["from backup"])
    }

  }

  func testClosedAppShareReplayEntersTheExistingFullSyncPathExactlyOnce() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullShareSync-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sharedRoot = root.appendingPathComponent("Shared", isDirectory: true)
    let firstStoreURL = ShareImportStore.storeURL(in: sharedRoot)
    let secondStoreURL = root.appendingPathComponent("second.store")
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()

    do {
      let library = try SwiftDataSnipLibrary(storeURL: firstStoreURL)
      let persistence = CloudFullSyncPersistence(
        library: library,
        namespace: namespace,
        dataZone: zone
      )
      try await persistence.approveEnrollment(
        references: [CloudEntityReference(kind: .list, domainID: SnipList.inbox.id)]
      )
      let coordinator = CloudFullSyncCoordinator(
        store: persistence,
        transport: FakeCloudRecordTransport(server: server, namespace: namespace)
      )
      try await coordinator.sync()
    }

    let requestID = UUID()
    let intake = ShareImportStore(sharedRootURL: sharedRoot)
    _ = try await intake.save(
      ShareImportRequest(
        content: "Saved while closed",
        destinationListID: SnipList.inbox.id,
        requestID: requestID,
        createdAt: Date(timeIntervalSince1970: 45)
      )
    )

    let importedLibrary = try SwiftDataSnipLibrary(storeURL: firstStoreURL)
    let interrupted = ShareImportStore(
      sharedRootURL: sharedRoot,
      afterPendingSaveBeforeCleanup: { throw ShareSyncCrash.afterLocalSave }
    )
    let interruptedResult = await interrupted.importPending(into: importedLibrary)
    XCTAssertEqual(interruptedResult, ShareImportSummary(imported: 0, failed: 1))
    let savedLocally = await importedLibrary.snapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(savedLocally.snips.first(where: { $0.requestID == requestID }))

    let firstPersistence = CloudFullSyncPersistence(
      library: importedLibrary,
      namespace: namespace,
      dataZone: zone
    )
    let firstRead = try await firstPersistence.pendingChanges()
    let repeatedRead = try await firstPersistence.pendingChanges()
    XCTAssertEqual(firstRead.operations, repeatedRead.operations)
    XCTAssertEqual(
      firstRead.operations.map(\.id),
      [CloudRecordID.snip(snip.id, in: zone)]
    )

    let firstCoordinator = CloudFullSyncCoordinator(
      store: firstPersistence,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await firstCoordinator.sync()

    let relaunchedLibrary = try SwiftDataSnipLibrary(storeURL: firstStoreURL)
    let replay = await ShareImportStore(sharedRootURL: sharedRoot)
      .importPending(into: relaunchedLibrary)
    XCTAssertEqual(replay, ShareImportSummary(imported: 1, failed: 0))
    let relaunchedPersistence = CloudFullSyncPersistence(
      library: relaunchedLibrary,
      namespace: namespace,
      dataZone: zone
    )
    let afterAcceptance = try await relaunchedPersistence.pendingChanges()
    XCTAssertTrue(afterAcceptance.operations.isEmpty)

    let secondLibrary = try SwiftDataSnipLibrary(storeURL: secondStoreURL)
    let secondCoordinator = CloudFullSyncCoordinator(
      store: CloudFullSyncPersistence(
        library: secondLibrary,
        namespace: namespace,
        dataZone: zone
      ),
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await secondCoordinator.fetchRemote()
    let received = await secondLibrary.snapshot(sortedBy: .manual)
    XCTAssertEqual(received.snips.map(\.requestID), [requestID])
    XCTAssertEqual(received.snips.map(\.content), ["Saved while closed"])
    let acceptedCount = await server.acceptedOperationCount(for: .snip(snip.id, in: zone))
    XCTAssertEqual(acceptedCount, 1)
  }

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
    let recovery = try await secondLibrary.recoverySnapshot(
      in: SnipRecoveryScope(namespace.canonicalKey)
    )
    let recovered = try XCTUnwrap(recovery.pendingSnips.first)
    XCTAssertEqual(recovered.currentSnipID, sharedID)
    XCTAssertEqual(recovered.recovered.content, "second seed")
    XCTAssertEqual(recovered.conflictingFields, [.text, .source, .done, .placement])
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

  func testActiveFetchPreservesRecoveredListEditWithoutMovingSnips() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullRecoveredListTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let firstLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("first.store"))
    let secondLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("second.store"))
    let created = try await firstLibrary.perform(
      .createList(name: "Base", systemImage: "folder"),
      sortedBy: .manual
    )
    guard case .listCreated(let list) = created.outcome else {
      return XCTFail("Expected a list")
    }
    let added = try await firstLibrary.perform(
      .add(
        content: "stays put",
        origin: .quickEntry,
        source: nil,
        listID: list.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a Snip")
    }
    let seeded = await firstLibrary.snapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(seeded.snips.first(where: { $0.id == snipID }))
    let enrollment: Set<CloudEntityReference> = [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .list, domainID: list.id),
      CloudEntityReference(kind: .snip, domainID: snip.id),
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
    let first = CloudFullSyncCoordinator(
      store: firstStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    let second = CloudFullSyncCoordinator(
      store: secondStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await first.sync()
    try await second.fetchRemote()

    _ = try await firstLibrary.perform(
      .updateList(id: list.id, name: "Server", systemImage: "cloud"),
      sortedBy: .manual
    )
    _ = try await secondLibrary.perform(
      .updateList(id: list.id, name: "Recovered", systemImage: "star"),
      sortedBy: .manual
    )
    try await first.sendPending()
    try await second.fetchRemote()

    let recovery = try await secondLibrary.recoverySnapshot(
      in: SnipRecoveryScope(namespace.canonicalKey)
    )
    let recovered = try XCTUnwrap(recovery.pendingLists.first)
    XCTAssertEqual(recovered.currentListID, list.id)
    XCTAssertEqual(recovered.recovered.desiredName, "Recovered")
    XCTAssertEqual(recovered.recovered.systemImage, "star")
    XCTAssertEqual(recovered.conflictingFields, [.name, .icon])
    let current = await secondLibrary.snapshot(sortedBy: .manual)
    XCTAssertEqual(current.lists.first(where: { $0.id == list.id })?.desiredName, "Server")
    XCTAssertEqual(current.lists.first(where: { $0.id == list.id })?.systemImage, "cloud")
    XCTAssertEqual(current.snips.first(where: { $0.id == snip.id })?.listID, list.id)
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
    let recovery = try await thirdLibrary.recoverySnapshot(
      in: SnipRecoveryScope(namespace.canonicalKey)
    )
    XCTAssertEqual(recovery.pendingSnips.map(\.currentSnipID), [base.id])
    XCTAssertEqual(recovery.pendingSnips.map(\.recovered.content), ["third text"])
    XCTAssertEqual(recovery.pendingSnips.map(\.conflictingFields), [[.text]])
    let thirdAfterConflict = await thirdLibrary.snapshot(sortedBy: .manual)
    XCTAssertEqual(thirdAfterConflict.snips.first?.content, "second text")
    let blocked = try await thirdStore.pendingChanges()
    XCTAssertTrue(blocked.operations.isEmpty)
  }

}

private enum ShareSyncCrash: Error {
  case afterLocalSave
}
