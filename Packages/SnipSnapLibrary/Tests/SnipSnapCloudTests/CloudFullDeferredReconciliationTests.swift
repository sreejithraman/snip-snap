import Foundation
import SnipSnapCore
import SwiftData
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

private enum DeferredLocalChange { case unchanged, edit, done, move, delete }
private enum DeferredArrival { case fetched, saved, stagedBeforeEdit, laterRecord }
private enum DeferredFetchFailure { case prior, sameBatch }
private enum LegacyStagedPlan { case listOnly, listAcknowledgement, staleEngine, staleNamespace, staleAccepted }

extension CloudFullSyncPersistenceTests {
  func testDeferredListArrivalCannotReleaseUnpreparedArchivedIntent() async throws {
    try await assertDeferredArrival(change: .unchanged, unpreparedArchive: true)
  }

  func testRestartReplansLegacyStagedListOnlyRelease() async throws {
    try await assertDeferredArrival(change: .edit, arrival: .stagedBeforeEdit, legacyStagedPlan: .listOnly)
  }

  func testLegacyStagedReleaseCannotBypassEngineStateCAS() async throws {
    try await assertDeferredArrival(change: .edit, arrival: .stagedBeforeEdit, legacyStagedPlan: .staleEngine)
  }

  func testLegacyStagedReleaseCannotBypassNamespaceRevisionCAS() async throws {
    try await assertDeferredArrival(change: .edit, arrival: .stagedBeforeEdit, legacyStagedPlan: .staleNamespace)
  }

  func testLegacyStagedReleaseCannotBypassAcceptedRecordCAS() async throws {
    try await assertDeferredArrival(change: .edit, arrival: .stagedBeforeEdit, legacyStagedPlan: .staleAccepted)
  }

  func testRestartReplansLegacyStagedListAcknowledgement() async throws {
    try await assertDeferredArrival(change: .edit, arrival: .stagedBeforeEdit,
      legacyStagedPlan: .listAcknowledgement)
  }

  func testDeferredListArrivalKeepsNewerEditBehindUnpreparedArchive() async throws {
    try await assertDeferredArrival(change: .edit, unpreparedArchive: true)
  }

  func testDeferredListArrivalKeepsLocalDeletionBehindUnpreparedArchive() async throws {
    try await assertDeferredArrival(change: .delete, unpreparedArchive: true)
  }

  func testDeferredListAcknowledgementCannotReleaseUnpreparedArchivedIntent() async throws {
    try await assertDeferredArrival(change: .edit, arrival: .saved, unpreparedArchive: true)
  }

  func testRestartKeepsStagedDependencyReleaseBehindUnpreparedArchive() async throws {
    try await assertDeferredArrival(change: .edit, arrival: .stagedBeforeEdit, unpreparedArchive: true)
  }

  func testDeferredListOnlyArrivalReconcilesNewerLocalEdit() async throws {
    try await assertDeferredArrival(change: .edit)
  }

  func testDeferredListSaveAcknowledgementReconcilesNewerLocalEdit() async throws {
    try await assertDeferredArrival(change: .edit, arrival: .saved)
  }

  func testManualRetryAfterRestartReplansStagedDependencyArrival() async throws {
    try await assertDeferredArrival(change: .edit, arrival: .stagedBeforeEdit)
  }

  func testDeferredListArrivalPreservesPendingRemoteTextAndNewerLocalDone() async throws {
    try await assertDeferredArrival(change: .done)
  }

  func testDeferredListArrivalPreservesNewerLocalMove() async throws {
    try await assertDeferredArrival(change: .move)
  }

  func testDeferredListArrivalDoesNotResurrectLocallyDeletedSnip() async throws {
    try await assertDeferredArrival(change: .delete)
  }

  func testNewRemoteUpdateWhileDeferredKeepsEarlierPendingFieldsAndLocalEdit() async throws {
    try await assertDeferredArrival(change: .done, arrival: .laterRecord)
  }

  func testDeferredListArrivalPreservesUnknownOriginAndFutureFields() async throws {
    try await assertDeferredArrival(change: .edit, futureOrigin: true)
  }

  func testDeferredListArrivalAfterFailedSnipFetchReconcilesWithoutClearingItsBarrier() async throws {
    try await assertDeferredArrival(change: .edit, fetchFailure: .prior)
  }

  func testDeferredListArrivalWithSameBatchSnipFailureKeepsItsSendingBarrier() async throws {
    try await assertDeferredArrival(change: .edit, fetchFailure: .sameBatch)
  }

  func testDeferredListAcknowledgementAfterFailedFetchKeepsItsSendingBarrier() async throws {
    try await assertDeferredArrival(change: .edit, arrival: .saved, fetchFailure: .prior)
  }

  func testManualRetryRecoversStagedListArrivalDespiteEarlierFailedSnipFetch() async throws {
    try await assertDeferredArrival(change: .edit, arrival: .stagedBeforeEdit, fetchFailure: .prior)
  }

  func testDeferredNewRemoteUpdatePreservesUnknownOriginAndFutureFields() async throws {
    try await assertDeferredArrival(change: .done, arrival: .laterRecord, futureOrigin: true)
  }

  private func assertDeferredArrival(
    change: DeferredLocalChange, arrival: DeferredArrival = .fetched, futureOrigin: Bool = false,
    fetchFailure: DeferredFetchFailure? = nil, unpreparedArchive: Bool = false,
    legacyStagedPlan: LegacyStagedPlan? = nil
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDeferredReconciliation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let originalList = SnipList(id: UUID(), name: "Original", systemImage: "folder", position: 1)
    let destination: SnipList
    if arrival == .saved || legacyStagedPlan == .listAcknowledgement {
      let created = try await library.perform(
        .createList(name: "Awaiting first acknowledgement", systemImage: "folder"), sortedBy: .manual
      )
      guard case .listCreated(let list) = created.outcome else { return XCTFail("Expected a list") }
      destination = list
    } else {
      destination = SnipList(id: UUID(), name: "Arrives later", systemImage: "folder", position: 2)
    }
    let snip = Snip(content: "original text", origin: .quickEntry, listID: originalList.id)
    let initial = CloudFetchedBatch(
      id: UUID(), items: [
        .record(try deferredListSnapshot(originalList, in: zone)),
        .record(try deferredSnipSnapshot(snip, in: zone, futureOrigin: futureOrigin)),
      ], engineState: nil
    )
    try await persistence.stage(.fetched(initial))
    try await persistence.applyStaged(initial.id)
    let moved = Self.copy(
      snip, content: change == .done ? "pending remote text" : nil, listID: destination.id
    )
    let move = CloudFetchedBatch(
      id: UUID(), items: [.record(try deferredSnipSnapshot(moved, in: zone, futureOrigin: futureOrigin))],
      engineState: nil
    )
    try await persistence.stage(.fetched(move))
    try await persistence.applyStaged(move.id)
    if unpreparedArchive {
      // Fault setup matches the supported coexistence of a prepared accepted
      // base and a newer archive revision; assertions use the public sync seam.
      let archived = try deferredSnipSnapshot(Self.copy(moved, content: "new unprepared revision"), in: zone)
      let reference = CloudEntityReference(kind: .snip, domainID: snip.id)
      let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
      let configuration = ModelConfiguration("SnipSnapLocal", schema: schema,
        url: root.appendingPathComponent("store"), cloudKitDatabase: .none)
      let context = ModelContext(try ModelContainer(for: schema,
        migrationPlan: SnipSnapSchemaMigrationPlan.self, configurations: [configuration]))
      context.insert(StoredCloudMappingQuarantine(namespaceKey: namespace.namespaceKey.rawValue,
        value: CloudQuarantineInput(
          key: CloudStoredQuarantine.corruptShadowKey(reference: reference, payload: archived.shadow.data),
          reference: reference, identity: CloudFullSyncPersistence.storageIdentity(archived.id),
          payload: archived.shadow.data
        )))
      try context.save()
    }
    if fetchFailure == .prior {
      let failure = CloudFetchedBatch(
        id: UUID(), items: [.failed(.snip(snip.id, in: zone), .networkUnavailable)], engineState: nil
      )
      try await persistence.stage(.fetched(failure))
      try await persistence.applyStaged(failure.id)
    }
    let waiting = await library.snapshot(sortedBy: .manual)
    let current = try XCTUnwrap(waiting.snips.first { $0.id == snip.id })
    XCTAssertEqual(current.listID, originalList.id)
    let listSnapshot = try deferredListSnapshot(destination, in: zone)
    let fetched = CloudFetchedBatch(
      id: UUID(), items: [.record(listSnapshot)] + (fetchFailure == .sameBatch
        ? [.failed(.snip(snip.id, in: zone), .networkUnavailable)] : []), engineState: nil
    )
    if arrival == .stagedBeforeEdit {
      if legacyStagedPlan == .listAcknowledgement {
        let outbound = CloudOutboundBatch(operations: [.save(try CloudFullRecordCodec.listDraft(
          destination, updatedAt: .distantPast, in: zone
        ))])
        try await persistence.stage(.sent(CloudSentBatch(
          id: fetched.id, items: [.saved(listSnapshot)], engineState: nil
        )), outbound: outbound)
      } else {
        try await persistence.stage(.fetched(fetched))
      }
      if let legacyStagedPlan {
        // Older planners staged only the arriving list, relying on storage to
        // release its snips. Retain the original raw batch and all CAS evidence.
        let plans = try await persistence.stagedBatches()
        let plan = try XCTUnwrap(plans.first { $0.batchID == fetched.id })
        let legacy = CloudFullBatchCommit(
          namespaceKey: plan.namespaceKey, batchID: plan.batchID,
          expectedEngineState: plan.expectedEngineState, nextEngineState: plan.nextEngineState,
          nextEnrollment: plan.nextEnrollment, expectedNamespaceRevision: plan.expectedNamespaceRevision,
          nextNamespaceState: plan.nextNamespaceState, rawBatchData: plan.rawBatchData,
          outboundBindings: plan.outboundBindings, recoveryInputs: plan.recoveryInputs,
          recoveryChanges: plan.recoveryChanges, recoveryReviews: plan.recoveryReviews,
          graphRepairs: plan.graphRepairs, settledDeleteIdentities: plan.settledDeleteIdentities,
          attachmentTransitions: plan.attachmentTransitions,
          items: plan.items.filter { $0.accepted.reference.kind == .list }
        )
        let encoded = try JSONEncoder().encode(legacy)
        var oldPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldPayload.removeValue(forKey: "hasPlannedDeferredReleases")
        if legacyStagedPlan == .staleEngine {
          oldPayload["expectedEngineState"] = Data("different engine".utf8).base64EncodedString()
        }
        if legacyStagedPlan == .staleNamespace {
          oldPayload["expectedNamespaceRevision"] = 999
        }
        if legacyStagedPlan == .staleAccepted {
          var items = try XCTUnwrap(oldPayload["items"] as? [[String: Any]])
          items[0]["expectedLocalRevision"] = 999
          oldPayload["items"] = items
        }
        try await library.replaceStagedCloudFullBatch(JSONDecoder().decode(CloudFullBatchCommit.self,
          from: JSONSerialization.data(withJSONObject: oldPayload)))
      }
    }
    switch change {
    case .unchanged: break
    case .edit:
      _ = try await library.perform(
        .update(id: snip.id, content: "newer local text", attachmentURLs: nil,
          expectedUpdatedAt: current.updatedAt, now: Date(timeIntervalSince1970: 20)),
        sortedBy: .manual
      )
    case .done:
      _ = try await library.perform(.setDone(ids: [snip.id], done: true), sortedBy: .manual)
    case .move:
      _ = try await library.perform(.moveChronologically(ids: [snip.id], to: SnipList.inbox.id), sortedBy: .manual)
    case .delete:
      _ = try await library.perform(.delete(ids: [snip.id]), sortedBy: .manual)
    }

    var completionLibrary = library
    var completionPersistence = persistence
    switch arrival {
    case .laterRecord:
      let updated = Self.copy(moved, source: SnipSource(applicationName: "Another device"))
      let update = CloudFetchedBatch(
        id: UUID(), items: [.record(try deferredSnipSnapshot(updated, in: zone, futureOrigin: futureOrigin))],
        engineState: nil
      )
      try await persistence.stage(.fetched(update))
      try await persistence.applyStaged(update.id)
      try await persistence.stage(.fetched(fetched))
      try await persistence.applyStaged(fetched.id)
    case .fetched:
      try await persistence.stage(.fetched(fetched))
      try await persistence.applyStaged(fetched.id)
    case .saved:
      let outbound = CloudOutboundBatch(operations: [.save(try CloudFullRecordCodec.listDraft(
        destination, updatedAt: .distantPast, in: zone
      ))])
      let sent = CloudSentBatch(id: UUID(), items: [.saved(listSnapshot)], engineState: nil)
      try await persistence.stage(.sent(sent), outbound: outbound)
      try await persistence.applyStaged(sent.id)
    case .stagedBeforeEdit:
      completionLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
      completionPersistence = CloudFullSyncPersistence(
        library: completionLibrary, namespace: namespace, dataZone: zone
      )
      let coordinator = CloudFullSyncCoordinator(
        store: completionPersistence,
        transport: FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
      )
      if legacyStagedPlan == .staleEngine || legacyStagedPlan == .staleNamespace
        || legacyStagedPlan == .staleAccepted
      {
        do {
          try await coordinator.prepareManualRetry()
          XCTFail("An old staged plan must not bypass its original CAS")
        } catch let error as CloudFullStorageError {
          let expected: CloudFullStorageError = switch legacyStagedPlan {
          case .staleEngine: .engineStateMismatch
          case .staleNamespace: .namespaceStateMismatch
          default: .staleAcceptedEntity
          }
          XCTAssertEqual(error, expected)
        }
        let unchanged = await completionLibrary.snapshot(sortedBy: .manual)
        XCTAssertEqual(unchanged.snips.first { $0.id == snip.id }?.listID, originalList.id)
        let staged = try await completionPersistence.stagedBatches()
        XCTAssertEqual(staged.map(\.batchID), [fetched.id])
        return
      }
      try await coordinator.prepareManualRetry()
    }

    let local = await completionLibrary.snapshot(sortedBy: .manual)
    let stored = try await completionLibrary.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    if unpreparedArchive {
      XCTAssertTrue(stored.deferredEntities.contains { $0.reference.domainID == snip.id })
      let retained = local.snips.first { $0.id == snip.id }
      if change == .delete {
        XCTAssertNil(retained)
      } else {
        XCTAssertEqual(retained?.content, change == .edit ? "newer local text" : "original text")
        XCTAssertEqual(retained?.listID, originalList.id)
      }
      let pending = try await completionPersistence.pendingChanges()
      XCTAssertFalse(pending.operations.contains { $0.id == .snip(snip.id, in: zone) })
      let staged = try await completionPersistence.stagedBatches()
      XCTAssertTrue(staged.isEmpty)
      return
    }
    XCTAssertFalse(stored.deferredEntities.contains { $0.reference.domainID == snip.id })
    let staged = try await completionPersistence.stagedBatches()
    XCTAssertTrue(staged.isEmpty)
    var pending = try await completionPersistence.pendingChanges()
    if change == .delete {
      XCTAssertFalse(local.snips.contains { $0.id == snip.id })
      XCTAssertTrue(pending.operations.contains {
        guard case .delete(let id, _) = $0 else { return false }
        return id == .snip(snip.id, in: zone)
      })
      return
    }
    let reconciled = try XCTUnwrap(local.snips.first { $0.id == snip.id })
    let expectedText = change == .edit ? "newer local text" : moved.content
    XCTAssertEqual(reconciled.content, expectedText)
    let expectedListID = change == .move ? SnipList.inbox.id : destination.id
    XCTAssertEqual(reconciled.listID, expectedListID)
    XCTAssertEqual(reconciled.isDone, change == .done)
    if arrival == .laterRecord { XCTAssertEqual(reconciled.source?.applicationName, "Another device") }
    XCTAssertFalse(stored.conflicts.contains { $0.reference.domainID == snip.id })
    if fetchFailure != nil {
      let recovery = try await completionLibrary.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
      XCTAssertEqual(try CloudFullSyncPersistence.failedFetchRecordIDs(recovery), [.snip(snip.id, in: zone)])
      XCTAssertFalse(pending.operations.contains { $0.id == .snip(snip.id, in: zone) })
      let successfulRead = CloudFetchedBatch(
        id: UUID(), items: [.record(try deferredSnipSnapshot(moved, in: zone))], engineState: nil
      )
      try await completionPersistence.stage(.fetched(successfulRead))
      try await completionPersistence.applyStaged(successfulRead.id)
      let recovered = try await completionLibrary.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
      XCTAssertTrue(try CloudFullSyncPersistence.failedFetchRecordIDs(recovered).isEmpty)
      pending = try await completionPersistence.pendingChanges()
    }
    let operation = try XCTUnwrap(pending.operations.first { $0.id == .snip(snip.id, in: zone) })
    guard case .save(let draft) = operation else { return XCTFail("Expected the reconciled edit") }
    let queuedSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: draft)
    )
    if futureOrigin {
      XCTAssertEqual(queuedSnapshot.schemaVersion, 9)
      XCTAssertEqual(queuedSnapshot.encryptedFields["origin"], .string("future-origin"))
      XCTAssertEqual(queuedSnapshot.encryptedFields["futureField"], .string("keep me"))
    }
    let queued = try CloudFullRecordCodec.snip(from: queuedSnapshot)
    let fields = try CloudFullSyncPersistence.snipFields(queued)
    XCTAssertEqual(fields.text, expectedText)
    XCTAssertEqual(fields.placement.listID, expectedListID)
    XCTAssertEqual(fields.isDone, change == .done)
  }

  private func deferredListSnapshot(_ list: SnipList, in zone: CloudZoneID) throws -> CloudRecordSnapshot {
    try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
    ))
  }

  private func deferredSnipSnapshot(
    _ snip: Snip, in zone: CloudZoneID, futureOrigin: Bool = false
  ) throws -> CloudRecordSnapshot {
    let original = try CloudFullRecordCodec.snipDraft(snip, in: zone)
    var fields = original.encryptedFields
    if futureOrigin {
      fields["origin"] = .string("future-origin")
      fields["futureField"] = .string("keep me")
    }
    return try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: CloudRecordDraft(
      id: original.id, recordType: original.recordType, schemaVersion: futureOrigin ? 9 : original.schemaVersion,
      routingFields: original.routingFields, encryptedFields: fields,
      removedEncryptedFields: original.removedEncryptedFields
    )))
  }
}
