import Foundation
import SnipSnapCore
import SwiftData
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

private enum LegacyListArrival {
  case fetched
  case savedAcknowledgement
}

extension CloudFullSyncPersistenceTests {
  func testLegacyDeferredNoneMutationKeepsLocalDeletionAfterFreshFetch() async throws {
    try await assertLegacyDeferredDeletionSurvivesFreshFetch(
      legacyMutationJSON: #"{"storageVersion":1,"precondition":{"none":{}},"mutation":{"none":{}}}"#
    )
  }

  func testLegacyDeferredAmbiguousAbsenceRequiresReviewWithoutRecreatingOrDeletingSnip() async throws {
    try await assertLegacyDeferredDeletionSurvivesFreshFetch(
      legacyMutationJSON: #"{"storageVersion":1,"precondition":{"requireMissing":{}},"mutation":{"none":{}}}"#,
      expectsReview: true
    )
  }

  func testLegacyAmbiguousAbsentSnipStaysDeferredWhenOnlyItsListIsFetched() async throws {
    try await assertLegacyDeferredDeletionSurvivesFreshFetch(
      legacyMutationJSON: #"{"storageVersion":1,"precondition":{"requireMissing":{}},"mutation":{"none":{}}}"#,
      expectsReview: true,
      listOnlyArrival: .fetched
    )
  }

  func testLegacyAmbiguousAbsentSnipStaysDeferredWhenOnlyItsListSaveIsAcknowledged() async throws {
    try await assertLegacyDeferredDeletionSurvivesFreshFetch(
      legacyMutationJSON: #"{"storageVersion":1,"precondition":{"requireMissing":{}},"mutation":{"none":{}}}"#,
      expectsReview: true,
      listOnlyArrival: .savedAcknowledgement
    )
  }

  func testUnknownDeferredMutationVersionCannotAuthorizeCloudDeletion() async throws {
    try await assertLegacyDeferredDeletionSurvivesFreshFetch(
      legacyMutationJSON: #"{"storageVersion":2,"precondition":{"requireMissing":{}},"mutation":{"none":{}},"wasMaterializedBeforeDeferral":true}"#,
      expectsUnsupportedVersion: true
    )
  }

  private func assertLegacyDeferredDeletionSurvivesFreshFetch(
    legacyMutationJSON: String,
    expectsReview: Bool = false,
    expectsUnsupportedVersion: Bool = false,
    listOnlyArrival: LegacyListArrival? = nil
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullLegacyDeferredDeletion-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)

    let created = try await library.perform(
      .createList(name: "First upload", systemImage: "folder"), sortedBy: .manual
    )
    guard case .listCreated(let list) = created.outcome else { return XCTFail("Expected a list") }
    let added = try await library.perform(
      .add(
        content: "deleted before upgrade", origin: .quickEntry, source: nil,
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
      guard case .saved(let snapshot) = result, snapshot.id == .snip(snipID, in: zone) else {
        return nil
      }
      return snapshot
    }.first)
    _ = try await library.perform(.delete(ids: [snipID]), sortedBy: .manual)
    try await persistence.stage(.sent(sent), outbound: outbound)
    try await persistence.applyStaged(sent.id)
    let beforeUpgrade = try await library.cloudFullStorageSnapshot(
      namespaceKey: namespace.namespaceKey
    )
    XCTAssertTrue(beforeUpgrade.deferredEntities.first { $0.reference.domainID == snipID }?
      .wasMaterializedBeforeDeferral == true)

    // Simulate a pre-upgrade row: old builds saved these Codable enum cases without
    // the later materialization field. A new library instance reads the persisted row.
    let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
    let configuration = ModelConfiguration(
      "SnipSnapLocal", schema: schema, url: storeURL, cloudKitDatabase: .none
    )
    let container = try ModelContainer(
      for: schema,
      migrationPlan: SnipSnapSchemaMigrationPlan.self,
      configurations: [configuration]
    )
    let context = ModelContext(container)
    let row = try XCTUnwrap(
      try context.fetch(FetchDescriptor<StoredCloudEntityRecord>()).first {
        $0.namespaceKey == namespace.namespaceKey.rawValue && $0.kind == "snip"
          && $0.domainID == snipID
      }
    )
    XCTAssertTrue(row.isDeferred)
    row.deferredMutationData = Data(legacyMutationJSON.utf8)
    try context.save()

    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
    let reopened = CloudFullSyncPersistence(
      library: reopenedLibrary, namespace: namespace, dataZone: zone
    )
    var completionLibrary = reopenedLibrary
    var completionPersistence = reopened
    if expectsUnsupportedVersion {
      do {
        _ = try await reopened.pendingChanges()
        XCTFail("An unknown deferred format must not authorize any outbound operation")
      } catch CloudFullStorageError.invalidBatchReplay {
        // Fail closed before interpreting unknown materialization provenance.
      }
      let local = await reopenedLibrary.snapshot(sortedBy: .manual)
      XCTAssertFalse(local.snips.contains { $0.id == snipID })
      let checkedContext = ModelContext(container)
      let checkedRow = try XCTUnwrap(
        try checkedContext.fetch(FetchDescriptor<StoredCloudEntityRecord>()).first {
          $0.namespaceKey == namespace.namespaceKey.rawValue && $0.kind == "snip"
            && $0.domainID == snipID
        }
      )
      XCTAssertEqual(checkedRow.deferredMutationData, Data(legacyMutationJSON.utf8))
      return
    }
    if let listOnlyArrival {
      let beforeList = try await reopenedLibrary.cloudFullStorageSnapshot(
        namespaceKey: namespace.namespaceKey
      )
      XCTAssertTrue(beforeList.deferredEntities.contains {
        $0.reference.domainID == snipID && $0.hasUnresolvedLegacyAbsence
      })
      let retry = try await reopened.pendingChanges()
      let listRecordID = CloudRecordID.list(list.id, in: zone)
      let listOperations = retry.operations.filter { $0.id == listRecordID }
      XCTAssertEqual(listOperations.count, 1)
      XCTAssertFalse(retry.operations.contains { $0.id == saved.id })
      let listOutbound = CloudOutboundBatch(operations: listOperations)
      let listSent = try await server.send(listOutbound, failures: [:])
      switch listOnlyArrival {
      case .fetched:
        let listSnapshot = try XCTUnwrap(listSent.items.compactMap { result -> CloudRecordSnapshot? in
          guard case .saved(let snapshot) = result else { return nil }
          return snapshot
        }.first)
        let listFetched = CloudFetchedBatch(
          id: UUID(), items: [.record(listSnapshot)], engineState: nil
        )
        try await reopened.stage(.fetched(listFetched))
        try await reopened.applyStaged(listFetched.id)
      case .savedAcknowledgement:
        try await reopened.stage(.sent(listSent), outbound: listOutbound)
        try await reopened.applyStaged(listSent.id)
      }

      let afterList = try await reopenedLibrary.cloudFullStorageSnapshot(
        namespaceKey: namespace.namespaceKey
      )
      XCTAssertTrue(afterList.deferredEntities.contains {
        $0.reference.domainID == snipID && $0.hasUnresolvedLegacyAbsence
      }, "A list-only arrival must preserve the unresolved absence for the snip")
      let afterListLocal = await reopenedLibrary.snapshot(sortedBy: .manual)
      XCTAssertFalse(afterListLocal.snips.contains { $0.id == snipID })
      let afterListPending = try await reopened.pendingChanges()
      XCTAssertFalse(afterListPending.operations.contains { $0.id == saved.id })
      if case .issue(.appDataIssue) = try await reopened.syncStatus() {
        // The ambiguous absence still needs conflict attention.
      } else {
        XCTFail("The ambiguous absence must keep conflict attention after a list-only arrival")
      }

      let restartedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
      let restarted = CloudFullSyncPersistence(
        library: restartedLibrary, namespace: namespace, dataZone: zone
      )
      let afterRestart = try await restartedLibrary.cloudFullStorageSnapshot(
        namespaceKey: namespace.namespaceKey
      )
      XCTAssertTrue(afterRestart.deferredEntities.contains {
        $0.reference.domainID == snipID && $0.hasUnresolvedLegacyAbsence
      })
      let afterRestartPending = try await restarted.pendingChanges()
      XCTAssertFalse(afterRestartPending.operations.contains { $0.id == saved.id })
      if case .issue(.appDataIssue) = try await restarted.syncStatus() {
        // The persisted marker must survive a fresh process.
      } else {
        XCTFail("Restart must retain conflict attention for the ambiguous absence")
      }
      completionLibrary = restartedLibrary
      completionPersistence = restarted
    }
    let complete = CloudFetchedBatch(
      id: UUID(), items: [.record(saved)], zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace, serialization: Data("complete".utf8), requiresInitialFetch: false
      ), isInitialFetch: true
    )
    try await completionPersistence.stage(.fetched(complete))
    try await completionPersistence.applyStaged(complete.id)

    let local = await completionLibrary.snapshot(sortedBy: .manual)
    XCTAssertFalse(local.snips.contains { $0.id == snipID })
    let pending = try await completionPersistence.pendingChanges()
    if expectsReview {
      XCTAssertFalse(pending.operations.contains { $0.id == saved.id })
      guard case .issue(.appDataIssue) = try await completionPersistence.syncStatus() else {
        return XCTFail("An ambiguous old absence needs review, not an automatic cloud deletion")
      }
      return
    }
    XCTAssertTrue(pending.operations.contains { operation in
      guard case .delete(let id, _) = operation else { return false }
      return id == saved.id
    }, "The saved shadow must be deleted, not uploaded again")
    XCTAssertFalse(pending.operations.contains { operation in
      guard case .save(let draft) = operation else { return false }
      return draft.id == saved.id
    })
  }
}
