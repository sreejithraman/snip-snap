import Foundation
import SnipSnapCore
import SwiftData
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

extension CloudFullSyncPersistenceTests {
  func testManualRetryRequestsFreshFetchForDeferredGraph() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDeferredRetryTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let orphan = Snip(content: "needs full retry", origin: .quickEntry, listID: UUID())
    let snapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(orphan, in: zone))
    )
    let batch = CloudFetchedBatch(
      id: UUID(),
      items: [.record(snapshot)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace,
        serialization: Data("incremental".utf8),
        requiresInitialFetch: false
      )
    )
    try await persistence.stage(.fetched(batch))
    try await persistence.applyStaged(batch.id)

    let needsFreshFetch = try await persistence.prepareManualRetry()
    XCTAssertTrue(needsFreshFetch)
  }

  func testCleanRetryRepairsChangedDeferredOrphanAndReplaysBeforeSend() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDeferredGraphRepairTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let missingListID = UUID()
    let original = Snip(content: "original", origin: .quickEntry, listID: missingListID)
    let originalSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(original, in: zone))
    )
    let incomplete = CloudFetchedBatch(
      id: UUID(),
      items: [.record(originalSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(incomplete))
    try await persistence.applyStaged(incomplete.id)

    let changed = Snip(
      id: original.id,
      requestID: original.requestID,
      createdAt: original.createdAt,
      updatedAt: Date(timeIntervalSince1970: 10),
      content: "changed remotely",
      origin: original.origin,
      source: original.source,
      listID: missingListID,
      isDone: original.isDone,
      pinnedAt: original.pinnedAt,
      manualSortKey: original.manualSortKey
    )
    let changedSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(changed, in: zone))
    )
    for revision in ["complete-1", "complete-2"] {
      let complete = CloudFetchedBatch(
        id: UUID(),
        items: [.record(changedSnapshot)],
        zoneEvents: [.fetched(zone)],
        engineState: CloudEngineStateEnvelope(
          namespace: namespace,
          serialization: Data(revision.utf8),
          requiresInitialFetch: false
        ),
        isInitialFetch: true
      )
      try await persistence.stage(.fetched(complete))
      try await persistence.applyStaged(complete.id)
    }

    let local = await library.snapshot(sortedBy: .manual)
    let repaired = try XCTUnwrap(local.snips.first(where: { $0.id == original.id }))
    XCTAssertEqual(repaired.content, "changed remotely")
    XCTAssertEqual(repaired.listID, SnipList.inbox.id)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertTrue(stored.deferredEntities.isEmpty)
    let pending = try await persistence.pendingChanges()
    XCTAssertTrue(pending.operations.contains {
      $0.id == changedSnapshot.id
    })
  }

  func testCleanFetchDeletingListUsesExistingPlacementRecovery() async throws {
    try await assertDeletingListPreservesMergedSnip(remoteMissingList: false)
  }

  func testCleanFetchDeletingOldListRepairsDifferentMissingServerList() async throws {
    try await assertDeletingListPreservesMergedSnip(remoteMissingList: true)
  }

  func testDeferredListArrivalWithOldListDeletionPreservesMergedSnip() async throws {
    try await assertDeletingListPreservesMergedSnip(
      remoteMissingList: true, dependencyArrivesLater: true
    )
  }

  func testDeferredListArrivalAfterSeparateOldListDeletionPreservesMergedSnip() async throws {
    try await assertDeletingListPreservesMergedSnip(
      remoteMissingList: true, dependencyArrivesLater: true, deleteOldListFirst: true
    )
  }

  private func assertDeletingListPreservesMergedSnip(
    remoteMissingList: Bool,
    dependencyArrivesLater: Bool = false,
    deleteOldListFirst: Bool = false
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDeletedListGraphRepairTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let list = SnipList(id: UUID(), name: "Deleted", systemImage: "trash", position: 1)
    let snip = Snip(content: "survives list deletion", origin: .quickEntry, listID: list.id)
    let listSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
      )
    )
    let snipSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    )
    let seed = CloudFetchedBatch(
      id: UUID(),
      items: [.record(listSnapshot), .record(snipSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(seed))
    try await persistence.applyStaged(seed.id)

    _ = try await library.perform(.setDone(ids: [snip.id], done: true), sortedBy: .manual)
    let edited = Snip(
      id: snip.id,
      requestID: snip.requestID,
      createdAt: snip.createdAt,
      updatedAt: Date(timeIntervalSince1970: 10),
      content: "edited remotely during list deletion",
      origin: snip.origin,
      listID: remoteMissingList ? UUID() : snip.listID,
      manualSortKey: snip.manualSortKey
    )
    let editedSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(edited, in: zone))
    )

    var deletionItems: [CloudFetchItemResult] = [.deleted(listSnapshot.id), .record(editedSnapshot)]
    if dependencyArrivesLater {
      let movedBatch = CloudFetchedBatch(id: UUID(), items: [.record(editedSnapshot)], engineState: nil)
      try await persistence.stage(.fetched(movedBatch))
      try await persistence.applyStaged(movedBatch.id)
      let destination = SnipList(id: edited.listID, name: "Arrived later", systemImage: "folder", position: 2)
      let destinationSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(destination, updatedAt: .distantPast, in: zone)
      ))
      deletionItems = [.deleted(listSnapshot.id), .record(destinationSnapshot)]
      if deleteOldListFirst {
        let firstDeletion = CloudFetchedBatch(
          id: UUID(), items: [.deleted(listSnapshot.id)], engineState: nil
        )
        try await persistence.stage(.fetched(firstDeletion))
        try await persistence.applyStaged(firstDeletion.id)
        deletionItems = [.record(destinationSnapshot)]
      }
    }

    let deletion = CloudFetchedBatch(
      id: UUID(),
      items: deletionItems,
      zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace,
        serialization: Data("complete".utf8),
        requiresInitialFetch: false
      ),
      isInitialFetch: !dependencyArrivesLater
    )
    try await persistence.stage(.fetched(deletion))
    try await persistence.applyStaged(deletion.id)

    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertFalse(local.lists.contains { $0.id == list.id })
    let repaired = try XCTUnwrap(local.snips.first(where: { $0.id == snip.id }))
    XCTAssertEqual(repaired.listID, dependencyArrivesLater ? edited.listID : SnipList.inbox.id)
    XCTAssertEqual(repaired.content, edited.content)
    XCTAssertTrue(repaired.isDone)
    let pending = try await persistence.pendingChanges()
    let operation = try XCTUnwrap(pending.operations.first { $0.id == snipSnapshot.id })
    guard case .save(let draft) = operation else { return XCTFail("Expected placement correction") }
    let queued = try CloudFullRecordCodec.snip(from: CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: draft)
    ))
    XCTAssertEqual(try CloudFullSyncPersistence.snipFields(queued).text, edited.content)
  }

  func testCleanRetryUsesFreshLocalPreconditionForDeferredMove() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDeferredEditRepairTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let list = SnipList(id: UUID(), name: "Local", systemImage: "folder", position: 1)
    let snip = Snip(content: "before edit", origin: .quickEntry, listID: list.id)
    let listSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
    ))
    let snipSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    )
    let seed = CloudFetchedBatch(
      id: UUID(),
      items: [.record(listSnapshot), .record(snipSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(seed))
    try await persistence.applyStaged(seed.id)

    let missingListID = UUID()
    let moved = Snip(
      id: snip.id,
      requestID: snip.requestID,
      createdAt: snip.createdAt,
      updatedAt: Date(timeIntervalSince1970: 10),
      content: snip.content,
      origin: snip.origin,
      source: snip.source,
      listID: missingListID,
      isDone: snip.isDone,
      pinnedAt: snip.pinnedAt,
      manualSortKey: snip.manualSortKey
    )
    let movedSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(moved, in: zone))
    )
    let incremental = CloudFetchedBatch(
      id: UUID(),
      items: [.record(movedSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(incremental))
    try await persistence.applyStaged(incremental.id)
    let beforeEdit = await library.snapshot(sortedBy: .manual)
    let current = try XCTUnwrap(beforeEdit.snips.first(where: { $0.id == snip.id }))
    _ = try await library.perform(
      .update(
        id: current.id,
        content: "edited while deferred",
        attachmentURLs: nil,
        expectedUpdatedAt: current.updatedAt,
        now: Date(timeIntervalSince1970: 20)
      ),
      sortedBy: .manual
    )

    let complete = CloudFetchedBatch(
      id: UUID(),
      items: [.record(listSnapshot), .record(movedSnapshot)],
      zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace,
        serialization: Data("complete".utf8),
        requiresInitialFetch: false
      ),
      isInitialFetch: true
    )
    try await persistence.stage(.fetched(complete))
    try await persistence.applyStaged(complete.id)

    let local = await library.snapshot(sortedBy: .manual)
    let repaired = try XCTUnwrap(local.snips.first(where: { $0.id == snip.id }))
    XCTAssertEqual(repaired.content, "edited while deferred")
    XCTAssertEqual(repaired.listID, list.id)
  }

  func testCleanRetryQueuesLocalDeletionOfPreviouslyMaterializedDeferredSnip() async throws {
    try await assertCleanRetryPreservesDeletion(deleteBeforeDeferral: false)
  }

  func testCleanRetryPreservesDeletionConflictMadeBeforeDeferral() async throws {
    try await assertCleanRetryPreservesDeletion(deleteBeforeDeferral: true)
  }

  private func assertCleanRetryPreservesDeletion(deleteBeforeDeferral: Bool) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDeferredDeleteRepairTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let list = SnipList(id: UUID(), name: "Visible", systemImage: "folder", position: 1)
    let snip = Snip(content: "delete while deferred", origin: .quickEntry, listID: list.id)
    let listSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
    ))
    let originalSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    )
    let seed = CloudFetchedBatch(
      id: UUID(),
      items: [.record(listSnapshot), .record(originalSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(seed))
    try await persistence.applyStaged(seed.id)

    let missingListID = UUID()
    let moved = Snip(
      id: snip.id,
      requestID: snip.requestID,
      createdAt: snip.createdAt,
      updatedAt: Date(timeIntervalSince1970: 10),
      content: snip.content,
      origin: snip.origin,
      source: snip.source,
      listID: missingListID,
      isDone: snip.isDone,
      pinnedAt: snip.pinnedAt,
      manualSortKey: snip.manualSortKey
    )
    let movedSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(moved, in: zone))
    )
    let incremental = CloudFetchedBatch(
      id: UUID(),
      items: [.record(movedSnapshot)],
      engineState: nil
    )
    if deleteBeforeDeferral {
      _ = try await library.perform(.delete(ids: [snip.id]), sortedBy: .manual)
    }
    try await persistence.stage(.fetched(incremental))
    try await persistence.applyStaged(incremental.id)
    if !deleteBeforeDeferral {
      _ = try await library.perform(.delete(ids: [snip.id]), sortedBy: .manual)
    }

    let complete = CloudFetchedBatch(
      id: UUID(),
      items: [.record(listSnapshot), .record(movedSnapshot)],
      zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace,
        serialization: Data("complete".utf8),
        requiresInitialFetch: false
      ),
      isInitialFetch: true
    )
    try await persistence.stage(.fetched(complete))
    try await persistence.applyStaged(complete.id)

    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertFalse(local.snips.contains { $0.id == snip.id })
    if deleteBeforeDeferral {
      // A remote move after a local deletion requires the existing delete-conflict flow.
      let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
      XCTAssertTrue(stored.deferredEntities.first { $0.reference.domainID == snip.id }?
        .wasMaterializedBeforeDeferral == true)
      XCTAssertTrue(stored.conflicts.contains { $0.reference.domainID == snip.id })
      return
    }
    let pending = try await persistence.pendingChanges()
    XCTAssertTrue(pending.operations.contains { operation in
      if case .delete(let id, _) = operation { return id == movedSnapshot.id }
      return false
    })
  }

  func testCleanFetchDoesNotTrustPreviouslyAcceptedMissingList() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullStaleAcceptedListTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let list = SnipList(id: UUID(), name: "Gone remotely", systemImage: "folder", position: 1)
    let listSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
    ))
    let seed = CloudFetchedBatch(id: UUID(), items: [.record(listSnapshot)], engineState: nil)
    try await persistence.stage(.fetched(seed))
    try await persistence.applyStaged(seed.id)
    _ = try await library.perform(.deleteList(id: list.id), sortedBy: .manual)

    let orphan = Snip(content: "stale accepted list", origin: .quickEntry, listID: list.id)
    let orphanSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(orphan, in: zone))
    )
    let complete = CloudFetchedBatch(
      id: UUID(),
      items: [.record(orphanSnapshot)],
      zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace,
        serialization: Data("complete".utf8),
        requiresInitialFetch: false
      ),
      isInitialFetch: true
    )
    try await persistence.stage(.fetched(complete))
    try await persistence.applyStaged(complete.id)

    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(local.snips.first(where: { $0.id == orphan.id })?.listID, SnipList.inbox.id)
  }

  func testCleanFetchRepairsNewSnipWhoseListIsDeletedInSameBatch() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullNewSnipDeletedListTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let list = SnipList(id: UUID(), name: "Deleted", systemImage: "trash", position: 1)
    let listSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
    ))
    let seed = CloudFetchedBatch(id: UUID(), items: [.record(listSnapshot)], engineState: nil)
    try await persistence.stage(.fetched(seed))
    try await persistence.applyStaged(seed.id)

    let orphan = Snip(content: "new orphan", origin: .quickEntry, listID: list.id)
    let orphanSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(orphan, in: zone))
    )
    let complete = CloudFetchedBatch(
      id: UUID(),
      items: [.deleted(listSnapshot.id), .record(orphanSnapshot)],
      zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace,
        serialization: Data("complete".utf8),
        requiresInitialFetch: false
      ),
      isInitialFetch: true
    )
    try await persistence.stage(.fetched(complete))
    try await persistence.applyStaged(complete.id)

    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertFalse(local.lists.contains { $0.id == list.id })
    XCTAssertEqual(local.snips.first(where: { $0.id == orphan.id })?.listID, SnipList.inbox.id)
  }

  func testDeletingRepairedSnipReplacesQueuedCorrectionWithDelete() async throws {
    try await assertDeletingRepairedSnip(acknowledgeCorrection: false)
  }

  func testDeletingRepairedSnipAfterCorrectionAcknowledgementQueuesDelete() async throws {
    try await assertDeletingRepairedSnip(acknowledgeCorrection: true)
  }

  func testCorrectionAcknowledgementPreservesMoveToNewLocalListDuringSend() async throws {
    try await assertDeletingRepairedSnip(acknowledgeCorrection: true, moveDuringSend: true)
  }

  func testStagedCorrectionAcknowledgementPreservesLaterMoveToNewLocalList() async throws {
    try await assertDeletingRepairedSnip(
      acknowledgeCorrection: true, moveDuringSend: true, moveAfterStaging: true
    )
  }

  private func assertDeletingRepairedSnip(
    acknowledgeCorrection: Bool,
    moveDuringSend: Bool = false,
    moveAfterStaging: Bool = false
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullRepairedDeleteTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let orphan = Snip(content: "delete repaired", origin: .quickEntry, listID: UUID())
    let orphanSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(orphan, in: zone))
    )
    let complete = CloudFetchedBatch(
      id: UUID(),
      items: [.record(orphanSnapshot)],
      zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace,
        serialization: Data("complete".utf8),
        requiresInitialFetch: false
      ),
      isInitialFetch: true
    )
    try await persistence.stage(.fetched(complete))
    try await persistence.applyStaged(complete.id)
    let correction = try await persistence.pendingChanges()
    XCTAssertTrue(correction.operations.contains { $0.id == orphanSnapshot.id })

    if acknowledgeCorrection {
      let operation = try XCTUnwrap(correction.operations.first { $0.id == orphanSnapshot.id })
      guard case .save(let draft) = operation else { return XCTFail("Expected correction save") }
      let saved = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))
      let sent = CloudSentBatch(id: UUID(), items: [.saved(saved)], engineState: nil)
      if moveAfterStaging {
        try await persistence.stage(.sent(sent), outbound: CloudOutboundBatch(operations: [operation]))
      }
      var movedListID: UUID?
      if moveDuringSend {
        let created = try await library.perform(
          .createList(name: "Created during send", systemImage: "folder"), sortedBy: .manual
        )
        guard case .listCreated(let list) = created.outcome else {
          return XCTFail("Expected a new list")
        }
        movedListID = list.id
        _ = try await library.perform(
          .moveChronologically(ids: [orphan.id], to: list.id), sortedBy: .manual
        )
      }
      if !moveAfterStaging {
        try await persistence.stage(.sent(sent), outbound: CloudOutboundBatch(operations: [operation]))
      }
      try await persistence.applyStaged(sent.id)
      if let movedListID {
        let local = await library.snapshot(sortedBy: .manual)
        XCTAssertEqual(local.snips.first { $0.id == orphan.id }?.listID, movedListID)
        let pending = try await persistence.pendingChanges()
        XCTAssertTrue(pending.operations.contains { $0.id == orphanSnapshot.id })
        XCTAssertTrue(pending.operations.contains { $0.id == .list(movedListID, in: zone) })
      }
    }

    _ = try await library.perform(.delete(ids: [orphan.id]), sortedBy: .manual)
    let deletion = try await persistence.pendingChanges()
    XCTAssertTrue(deletion.operations.contains { operation in
      if case .delete(let id, _) = operation { return id == orphanSnapshot.id }
      return false
    })
  }

  func testCleanFetchRepairsMissingRemoteListEvenWhenLocalListRemains() async throws {
    try await assertCleanFetchRepairsMissingRemoteList()
  }

  func testInitialFetchCompletionRepairsReadySnipWhoseCachedListIsAbsent() async throws {
    try await assertCleanFetchRepairsMissingRemoteList(snipArrivesEarlier: true)
  }

  private func assertCleanFetchRepairsMissingRemoteList(snipArrivesEarlier: Bool = false) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullLocallyPresentMissingListTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let list = SnipList(id: UUID(), name: "Absent remotely", systemImage: "folder", position: 1)
    let snip = Snip(content: "repair the remote placement", origin: .quickEntry, listID: list.id)
    let listSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
    ))
    let snipSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.snipDraft(snip, in: zone)
    ))
    let seed = CloudFetchedBatch(
      id: UUID(), items: [.record(listSnapshot), .record(snipSnapshot)], engineState: nil
    )
    try await persistence.stage(.fetched(seed))
    try await persistence.applyStaged(seed.id)
    if snipArrivesEarlier {
      let earlier = CloudFetchedBatch(
        id: UUID(), items: [.record(snipSnapshot)], engineState: nil, isInitialFetch: true
      )
      try await persistence.stage(.fetched(earlier))
      try await persistence.applyStaged(earlier.id)
    }
    let complete = CloudFetchedBatch(
      id: UUID(), items: snipArrivesEarlier ? [] : [.record(snipSnapshot)], zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace, serialization: Data("complete".utf8), requiresInitialFetch: false
      ), isInitialFetch: true
    )
    try await persistence.stage(.fetched(complete))
    try await persistence.applyStaged(complete.id)
    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertTrue(local.lists.contains { $0.id == list.id })
    XCTAssertEqual(local.snips.first { $0.id == snip.id }?.listID, SnipList.inbox.id)
    let pending = try await persistence.pendingChanges()
    XCTAssertTrue(pending.operations.contains { $0.id == snipSnapshot.id })
    let listOperation = try XCTUnwrap(pending.operations.first { $0.id == listSnapshot.id })
    guard case .save(let draft) = listOperation else { return XCTFail("Expected list recreation") }
    XCTAssertNil(draft.base)
    let server = FakeCloudServer()
    let result = try await server.send(CloudOutboundBatch(operations: [listOperation]), failures: [:])
    guard case .saved = result.items.first else { return XCTFail("Expected recreated cloud list") }
    let recreated = await server.fullSnapshot(for: listSnapshot.id)
    XCTAssertNotNil(recreated)
  }

  func testInitialFetchCompletionRetainsRecordsFromEarlierBatchesAfterRestart() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullChunkedInventoryTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let list = SnipList(id: UUID(), name: "Earlier batch", systemImage: "folder", position: 1)
    let snip = Snip(content: "keep earlier records", origin: .quickEntry, listID: list.id)
    let listSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
    ))
    let snipSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.snipDraft(snip, in: zone)
    ))
    try await persistence.saveEngineState(CloudEngineStateEnvelope(
      namespace: namespace, serialization: Data("started".utf8), requiresInitialFetch: true
    ))
    let earlier = CloudFetchedBatch(
      id: UUID(), items: [.record(listSnapshot), .record(snipSnapshot)], engineState: nil,
      isInitialFetch: true
    )
    try await persistence.stage(.fetched(earlier))
    try await persistence.applyStaged(earlier.id)
    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
    let restarted = CloudFullSyncPersistence(library: reopened, namespace: namespace, dataZone: zone)
    try await restarted.saveEngineState(CloudEngineStateEnvelope(
      namespace: namespace, serialization: Data("checkpoint".utf8), requiresInitialFetch: true
    ))
    let complete = CloudFetchedBatch(
      id: UUID(), items: [.record(snipSnapshot)], zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace, serialization: Data("complete".utf8), requiresInitialFetch: false
      ), isInitialFetch: true
    )
    try await restarted.stage(.fetched(complete))
    try await restarted.applyStaged(complete.id)
    let local = await reopened.snapshot(sortedBy: .manual)
    XCTAssertEqual(local.snips.first { $0.id == snip.id }?.listID, list.id)
    let accepted = try await reopened.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertTrue(accepted.readyEntities.contains { $0.reference.domainID == list.id })
    let pending = try await restarted.pendingChanges()
    XCTAssertFalse(pending.operations.contains { $0.id == listSnapshot.id || $0.id == snipSnapshot.id })
  }

  func testInitialFetchCompletionRepairsOrphanFromEarlierBatch() async throws {
    try await assertInitialFetchRepairsEarlierOrphan()
  }

  func testFailedInitialFetchNeedsFreshRetryBeforeOrphanRepair() async throws {
    try await assertInitialFetchRepairsEarlierOrphan(earlierFailure: true)
  }

  func testLegacyResumedInitialFetchNeedsFreshRetryBeforeOrphanRepair() async throws {
    try await assertInitialFetchRepairsEarlierOrphan(legacyState: true)
  }

  private func assertInitialFetchRepairsEarlierOrphan(
    earlierFailure: Bool = false,
    legacyState: Bool = false
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullChunkedOrphanTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let snip = Snip(content: "orphan in earlier batch", origin: .quickEntry, listID: UUID())
    let snapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.snipDraft(snip, in: zone)
    ))
    if legacyState {
      try await library.saveCloudEngineState(
        namespaceKey: namespace.namespaceKey,
        envelopeData: JSONEncoder().encode(CloudEngineStateEnvelope(
          namespace: namespace, serialization: Data("legacy-resumed".utf8), requiresInitialFetch: true
        ))
      )
    }
    let earlier = CloudFetchedBatch(
      id: UUID(), items: [.record(snapshot)] + (earlierFailure ? [.failed(nil, .networkUnavailable)] : []),
      engineState: nil, isInitialFetch: true
    )
    try await persistence.stage(.fetched(earlier))
    try await persistence.applyStaged(earlier.id)
    let incomplete = await library.snapshot(sortedBy: .manual)
    XCTAssertFalse(incomplete.snips.contains { $0.id == snip.id })
    let complete = CloudFetchedBatch(
      id: UUID(), items: [], zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace, serialization: Data("complete".utf8), requiresInitialFetch: false
      ), isInitialFetch: true
    )
    try await persistence.stage(.fetched(complete))
    try await persistence.applyStaged(complete.id)
    if earlierFailure || legacyState {
      let withheld = await library.snapshot(sortedBy: .manual)
      XCTAssertFalse(withheld.snips.contains { $0.id == snip.id })
      let needsReset = try await persistence.prepareManualRetry()
      XCTAssertTrue(needsReset)
      try await persistence.clearEngineState()
      let fresh = CloudFetchedBatch(
        id: UUID(), items: [.record(snapshot)], zoneEvents: [.fetched(zone)],
        engineState: complete.engineState, isInitialFetch: true
      )
      try await persistence.stage(.fetched(fresh))
      try await persistence.applyStaged(fresh.id)
    }
    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(local.snips.first { $0.id == snip.id }?.listID, SnipList.inbox.id)
    XCTAssertEqual(local.snips.first { $0.id == snip.id }?.content, "orphan in earlier batch")
    let pending = try await persistence.pendingChanges()
    XCTAssertTrue(pending.operations.contains { $0.id == snapshot.id })
  }

  func testCleanEmptyFetchRetiresAbsentDeferredSnipAndAllowsSetup() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullAbsentDeferredSnipTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let orphan = Snip(content: "deleted before retry", origin: .quickEntry, listID: UUID())
    let snapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.snipDraft(orphan, in: zone)
    ))
    let readySnip = Snip(content: "also deleted before token reset", origin: .quickEntry)
    let readySnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.snipDraft(readySnip, in: zone)
    ))
    let incomplete = CloudFetchedBatch(
      id: UUID(), items: [.record(snapshot), .record(readySnapshot)], engineState: nil
    )
    try await persistence.stage(.fetched(incomplete))
    try await persistence.applyStaged(incomplete.id)
    let stillIncomplete = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
    try await persistence.stage(.fetched(stillIncomplete))
    try await persistence.applyStaged(stillIncomplete.id)
    let waiting = try await persistence.isReenableReady()
    XCTAssertFalse(waiting)

    let complete = CloudFetchedBatch(
      id: UUID(), items: [], zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace, serialization: Data("complete".utf8), requiresInitialFetch: false
      ), isInitialFetch: true
    )
    try await persistence.stage(.fetched(complete))
    try await persistence.applyStaged(complete.id)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertTrue(stored.deferredEntities.isEmpty)
    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertFalse(local.snips.contains { $0.id == readySnip.id })
    XCTAssertFalse(stored.readyEntities.contains { $0.reference.domainID == readySnip.id })
    let ready = try await persistence.isReenableReady()
    XCTAssertTrue(ready)
    let pending = try await persistence.pendingChanges()
    XCTAssertFalse(pending.operations.contains { $0.id == snapshot.id })
  }

  func testCleanRetryPreservesMoveToNewLocalList() async throws {
    try await assertCleanRetryPreservesLocalList(acceptedReplacement: false)
  }

  func testFirstSnipSaveAcknowledgementPreservesDeletionWhenListSaveFails() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullFirstSaveDeletionTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let created = try await library.perform(
      .createList(name: "First upload", systemImage: "folder"), sortedBy: .manual
    )
    guard case .listCreated(let list) = created.outcome else { return XCTFail("Expected a list") }
    let added = try await library.perform(
      .add(
        content: "deleted during first upload", origin: .quickEntry, source: nil,
        listID: list.id, attachmentURLs: [], requestID: UUID(), now: .distantPast
      ), sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else { return XCTFail("Expected a snip") }
    try await persistence.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: list.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let outbound = try await persistence.pendingChanges()
    let server = FakeCloudServer()
    let sent = try await server.send(outbound, failures: [.list(list.id, in: zone): .retryable])
    let saved = try XCTUnwrap(sent.items.compactMap { result -> CloudRecordSnapshot? in
      guard case .saved(let snapshot) = result, snapshot.id == .snip(snipID, in: zone) else { return nil }
      return snapshot
    }.first)
    _ = try await library.perform(.delete(ids: [snipID]), sortedBy: .manual)
    try await persistence.stage(.sent(sent), outbound: outbound)
    try await persistence.applyStaged(sent.id)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertTrue(stored.deferredEntities.first { $0.reference.domainID == snipID }?
      .wasMaterializedBeforeDeferral == true)

    let complete = CloudFetchedBatch(
      id: UUID(), items: [.record(saved)], zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace, serialization: Data("complete".utf8), requiresInitialFetch: false
      ), isInitialFetch: true
    )
    try await persistence.stage(.fetched(complete))
    try await persistence.applyStaged(complete.id)
    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertFalse(local.snips.contains { $0.id == snipID })
    let pending = try await persistence.pendingChanges()
    let deletion = try XCTUnwrap(pending.operations.first { operation in
      guard case .delete(let id, _) = operation else { return false }
      return id == saved.id
    })
    let deleteBatch = CloudOutboundBatch(operations: [deletion])
    let deleted = try await server.send(deleteBatch, failures: [:])
    try await persistence.stage(.sent(deleted), outbound: deleteBatch)
    try await persistence.applyStaged(deleted.id)
    let remote = await server.fullSnapshot(for: saved.id)
    XCTAssertNil(remote)
  }

  func testCleanRetryRecreatesPreviouslyAcceptedButRemotelyMissingReplacementList() async throws {
    try await assertCleanRetryPreservesLocalList(acceptedReplacement: true)
  }

  func testConcurrentRemoteOrphanMovePreservesSurvivingLocalPlacementAndConflict() async throws {
    try await assertCleanRetryPreservesLocalList(acceptedReplacement: false, concurrentRemoteMove: true)
  }

  private func assertCleanRetryPreservesLocalList(
    acceptedReplacement: Bool,
    concurrentRemoteMove: Bool = false
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDeferredLocalListTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let oldList = SnipList(id: UUID(), name: "Old", systemImage: "folder", position: 1)
    let snip = Snip(content: "move locally", origin: .quickEntry, listID: oldList.id)
    let oldListSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.listDraft(oldList, updatedAt: .distantPast, in: zone)
    ))
    let snipSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    )
    let seed = CloudFetchedBatch(
      id: UUID(),
      items: [.record(oldListSnapshot), .record(snipSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(seed))
    try await persistence.applyStaged(seed.id)

    let moved = Snip(
      id: snip.id,
      requestID: snip.requestID,
      createdAt: snip.createdAt,
      updatedAt: Date(timeIntervalSince1970: 10),
      content: snip.content,
      origin: snip.origin,
      source: snip.source,
      listID: UUID(),
      isDone: snip.isDone,
      pinnedAt: snip.pinnedAt,
      manualSortKey: snip.manualSortKey
    )
    let movedSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(moved, in: zone))
    )
    let incremental = CloudFetchedBatch(
      id: UUID(),
      items: [.record(movedSnapshot)],
      engineState: nil
    )
    if !concurrentRemoteMove {
      try await persistence.stage(.fetched(incremental))
      try await persistence.applyStaged(incremental.id)
    }
    let created = try await library.perform(
      .createList(name: "New local", systemImage: "star"),
      sortedBy: .manual
    )
    guard case .listCreated(let newList) = created.outcome else {
      return XCTFail("Expected a created list")
    }
    if acceptedReplacement {
      let listSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(newList, updatedAt: .distantPast, in: zone)
      ))
      let listBatch = CloudFetchedBatch(id: UUID(), items: [.record(listSnapshot)], engineState: nil)
      try await persistence.stage(.fetched(listBatch))
      try await persistence.applyStaged(listBatch.id)
    }
    _ = try await library.perform(
      .moveChronologically(ids: [snip.id], to: newList.id),
      sortedBy: .manual
    )

    let complete = CloudFetchedBatch(
      id: UUID(),
      items: [.record(oldListSnapshot), .record(movedSnapshot)],
      zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace,
        serialization: Data("complete".utf8),
        requiresInitialFetch: false
      ),
      isInitialFetch: true
    )
    try await persistence.stage(.fetched(complete))
    try await persistence.applyStaged(complete.id)

    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(local.snips.first(where: { $0.id == snip.id })?.listID, newList.id)
    let pending = try await persistence.pendingChanges()
    if concurrentRemoteMove {
      let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
      XCTAssertTrue(stored.conflicts.contains { $0.reference.domainID == snip.id })
      XCTAssertFalse(pending.operations.contains { $0.id == movedSnapshot.id })
    } else {
      XCTAssertTrue(pending.operations.contains { $0.id == movedSnapshot.id })
    }
    let listOperation = try XCTUnwrap(pending.operations.first { $0.id == .list(newList.id, in: zone) })
    guard case .save(let draft) = listOperation else { return XCTFail("Expected local list upload") }
    XCTAssertNil(draft.base)
  }

}
