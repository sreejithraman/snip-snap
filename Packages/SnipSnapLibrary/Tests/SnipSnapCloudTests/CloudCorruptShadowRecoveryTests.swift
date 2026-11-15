import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData
import XCTest
@testable import SnipSnapCloud
@testable import SnipSnapPersistence

final class CloudCorruptShadowRecoveryTests: XCTestCase {
  func testCorruptShadowRowsKeepTheirStoredKeysAndFieldsThroughEachStage() async throws {
    for kind: CloudEntityKind in [.snip, .list] {
      let fixture = try await Fixture()
      defer { fixture.remove() }
      let snapshot = try await fixture.stored()
      let accepted = try XCTUnwrap(snapshot.readyEntities.first { $0.reference.kind == kind })
      let kindName = kind == .snip ? "snip" : "list"
      let domainID = accepted.reference.domainID.uuidString.lowercased()
      let digest = SHA256.hash(data: accepted.shadowData).prefix(8)
        .map { String(format: "%02x", $0) }.joined()
      let archiveKey = "corrupt-shadow-\(kindName)-\(domainID)-\(digest)"
      let namespaceKey = fixture.namespace.namespaceKey.rawValue
      func expectRows(_ keys: [String], _ stage: String) throws {
        let rows = try fixture.quarantineRows()
        let label = "\(kindName) \(stage)"
        XCTAssertEqual(rows.map(\.id), keys.map { "\(namespaceKey)|quarantine|\($0)" }.sorted(), label)
        for row in rows {
          XCTAssertEqual(row.namespaceKey, namespaceKey, label)
          XCTAssertEqual(row.kind, kindName, label)
          XCTAssertEqual(row.domainID, accepted.reference.domainID, label)
          XCTAssertEqual(row.zoneName, "SnipSnap", label)
          XCTAssertEqual(row.ownerName, "owner", label)
          XCTAssertEqual(row.recordName, "\(kind == .snip ? "s-" : "l-")\(domainID)", label)
          XCTAssertEqual(row.format, "legacyBindingV1", label)
          XCTAssertEqual(row.payload, accepted.shadowData, label)
        }
      }

      try await fixture.library.quarantineCorruptCloudEntities(
        namespaceKey: fixture.namespace.namespaceKey, values: [accepted])
      try expectRows([archiveKey], "archive")
      try await prepareFreshEngine(fixture.store)
      try expectRows([archiveKey, "recovering-\(archiveKey)"], "recovery attempt")
      try await fixture.coordinator.prepareManualRetry()
      try await fixture.coordinator.fetchRemote()
      try expectRows(["resolved-\(archiveKey)"], "resolution marker")
    }
  }

  func testArchiveKeyOfFixedShadowBytesStaysStable() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let goldenBytes = Data("snip-snap corrupt shadow golden".utf8)
    let context = try fixture.context()
    let record = try XCTUnwrap(try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
      .first { $0.kind == CloudEntityKind.snip.rawValue })
    let domainID = record.domainID.uuidString.lowercased()
    record.shadowData = goldenBytes
    try context.save()
    let snapshot = try await fixture.stored()
    let accepted = try XCTUnwrap(snapshot.readyEntities.first { $0.reference.kind == .snip })

    try await fixture.library.quarantineCorruptCloudEntities(
      namespaceKey: fixture.namespace.namespaceKey, values: [accepted])

    let rows = try fixture.quarantineRows()
    XCTAssertEqual(rows.map(\.id), [
      "\(fixture.namespace.namespaceKey.rawValue)|quarantine|corrupt-shadow-snip-\(domainID)-18bf38994062a72c",
    ])
    XCTAssertEqual(rows.map(\.payload), [goldenBytes])
  }

  func testEachRecoveryStageKeepsItsBlocksAndAttentionAcrossReopen() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let archived = try await fixture.quarantineAcceptedRecord()
    let recordID = CloudFullSyncPersistence.recordID(archived.identity)

    var reopened = try fixture.reopenedStore()
    try await expectRecoveryReads(reopened, recordID: recordID,
      blocked: true, attention: true, resetNeeded: true, "archive")
    let archivedState = try await reopened.loadEngineState()
    XCTAssertNil(archivedState)
    try await prepareFreshEngine(reopened)

    reopened = try fixture.reopenedStore()
    let prepared = try await fixture.stored()
    XCTAssertEqual(Set(prepared.quarantines.map(\.key)), [archived.key, "recovering-\(archived.key)"])
    XCTAssertTrue(prepared.readyEntities.contains { $0.reference == archived.reference })
    try await expectRecoveryReads(reopened, recordID: recordID,
      blocked: true, attention: true, resetNeeded: true, "recovery attempt")
    // Preparing again binds nothing new and restores nothing twice.
    try await prepareFreshEngine(reopened)
    let repeated = try await fixture.stored()
    XCTAssertEqual(repeated.quarantines, prepared.quarantines)
    XCTAssertEqual(repeated.readyEntities, prepared.readyEntities)

    // A restart resumes the full fetch from a fresh engine.
    let restarted = CloudFullSyncCoordinator(store: reopened,
      transport: FakeCloudRecordTransport(server: fixture.server, namespace: fixture.namespace))
    try await restarted.fetchRemote()
    reopened = try fixture.reopenedStore()
    let resolved = try await fixture.stored()
    XCTAssertEqual(resolved.quarantines.map(\.key), ["resolved-\(archived.key)"])
    try await expectRecoveryReads(reopened, recordID: recordID,
      blocked: false, attention: false, resetNeeded: false, "resolution marker")
    let resolvedState = try await reopened.loadEngineState()
    XCTAssertNotNil(resolvedState)
  }

  func testFailedSaveBeforeEachRecoveryStageKeepsThePriorStage() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let crash = ResolutionWriteFailure()
    let library = try SwiftDataSnipLibrary(storeURL: fixture.url,
      afterMutationBeforeSave: { try crash.hit() })
    let store = CloudFullSyncPersistence(library: library, namespace: fixture.namespace, dataZone: fixture.zone)
    let original = try await fixture.stored()
    let accepted = try XCTUnwrap(original.readyEntities.first { $0.reference.kind == .snip })

    crash.failOnWrite(1)
    await XCTAssertThrowsErrorAsync {
      try await library.quarantineCorruptCloudEntities(
        namespaceKey: fixture.namespace.namespaceKey, values: [accepted])
    }
    let afterArchiveFailure = try await fixture.stored()
    XCTAssertEqual(afterArchiveFailure, original)

    try await library.quarantineCorruptCloudEntities(
      namespaceKey: fixture.namespace.namespaceKey, values: [accepted])
    let archived = try await fixture.stored()
    let archive = try XCTUnwrap(archived.quarantines.first)
    crash.failOnWrite(1)
    await XCTAssertThrowsErrorAsync { try await prepareFreshEngine(store) }
    let afterAttemptFailure = try await fixture.stored()
    XCTAssertEqual(afterAttemptFailure, archived)

    try await prepareFreshEngine(fixture.reopenedStore())
    let prepared = try await fixture.stored()
    XCTAssertEqual(Set(prepared.quarantines.map(\.key)), [archive.key, "recovering-\(archive.key)"])
    XCTAssertTrue(prepared.readyEntities.contains { $0.reference == accepted.reference })
  }

  func testOrphanAttemptAndUnrelatedQuarantineNeedAttentionWithoutBlockingOrRecovery() async throws {
    for row in ["orphan attempt", "unrelated quarantine"] {
      let fixture = try await Fixture()
      defer { fixture.remove() }
      let archived = try await fixture.quarantineAcceptedRecord()
      let identity = archived.identity
      let key = row == "orphan attempt"
        ? "recovering-\(archived.key)"
        : "legacy|\(identity.ownerName)|\(identity.zoneName)|\(identity.recordName)"
      let context = try fixture.context()
      for archive in try context.fetch(FetchDescriptor<StoredCloudMappingQuarantine>()) {
        context.delete(archive)
      }
      context.insert(StoredCloudMappingQuarantine(namespaceKey: fixture.namespace.namespaceKey.rawValue,
        value: CloudQuarantineInput(key: key, reference: archived.reference,
          identity: identity, payload: archived.payload)))
      try context.save()
      let before = try await fixture.stored()

      try await expectRecoveryReads(fixture.store, recordID: CloudFullSyncPersistence.recordID(identity),
        blocked: false, attention: true, resetNeeded: false, row)
      let state = try await fixture.store.loadEngineState()
      try await fixture.applyCleanCompletion()

      let after = try await fixture.stored()
      XCTAssertNotNil(state, row)
      XCTAssertEqual(before.quarantines.map(\.key), [key], row)
      XCTAssertEqual(after.quarantines, before.quarantines, row)
    }
  }

  func testMismatchedRecoveryAttemptKeepsItsArchiveUnpreparedAndStopsPreparation() async throws {
    for failure in ["payload", "identity", "reference", "format"] {
      let fixture = try await Fixture()
      defer { fixture.remove() }
      let archived = try await fixture.quarantineAcceptedRecord()
      let context = try fixture.context()
      let attempt = StoredCloudMappingQuarantine(namespaceKey: fixture.namespace.namespaceKey.rawValue,
        value: CloudQuarantineInput(key: "recovering-\(archived.key)", reference: archived.reference,
          identity: archived.identity, payload: archived.payload))
      switch failure {
      case "payload": attempt.payload = Data("changed attempt".utf8)
      case "identity": attempt.recordName += "-other"
      case "reference": attempt.domainID = UUID()
      case "format": attempt.format = CloudConflictFormat.snipMergeV1.rawValue
      default: XCTFail("Unknown test case")
      }
      context.insert(attempt)
      try context.save()
      let before = try await fixture.stored()

      try await expectRecoveryReads(fixture.store, recordID: CloudFullSyncPersistence.recordID(archived.identity),
        blocked: true, attention: true, resetNeeded: true, failure)
      // Binding the archive's own attempt collides with the changed row.
      await XCTAssertThrowsErrorAsync { try await prepareFreshEngine(fixture.store) }
      try await fixture.applyCleanCompletion()

      let after = try await fixture.stored()
      XCTAssertEqual(Set(before.quarantines.map(\.key)), [archived.key, "recovering-\(archived.key)"], failure)
      XCTAssertEqual(after.quarantines, before.quarantines, failure)
      XCTAssertFalse(after.readyEntities.contains { $0.reference == archived.reference }, failure)
    }
  }

  /// SM27-L2-R1 (fails at base). Staged recovery reads the engine state, and that read prepares
  /// recovery again, which restarts the initial-fetch inventory while the engine keeps its
  /// place. The completing batch then treats the record the fetch already delivered as absent
  /// and deletes the local snip, although the server still has it.
  func testRecoveredStagedBatchDuringTheRecoveryFetchKeepsRecordsTheFetchAlreadyDelivered() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let archived = try await fixture.quarantineAcceptedRecord()
    let recordID = CloudFullSyncPersistence.recordID(archived.identity)
    let serverValue = await fixture.server.fullSnapshot(for: recordID)
    let serverRecord = try XCTUnwrap(serverValue)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: fixture.store, transport: transport)
    try await coordinator.prepareManualRetry()
    try await coordinator.prepareAutomaticSync()
    let partial = CloudEngineStateEnvelope(namespace: fixture.namespace,
      serialization: Data("partial".utf8), requiresInitialFetch: true)

    let delivered = CloudFetchedBatch(id: UUID(), items: [.record(serverRecord)],
      engineState: partial, isInitialFetch: true)
    await transport.enqueue(.batch(CloudPendingBatch(batch: .fetched(delivered), outbound: nil)))
    try await coordinator.processAutomaticChanges()
    // Staging alone stands in for an apply that failed after its stage commit.
    let interrupted = CloudFetchedBatch(id: UUID(), items: [], engineState: partial, isInitialFetch: true)
    try await fixture.store.stage(.fetched(interrupted))
    await transport.enqueue(.batch(CloudPendingBatch(batch: .fetched(interrupted), outbound: nil)))
    try await coordinator.processAutomaticChanges()
    let completed = CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.fetched(fixture.zone)],
      engineState: CloudEngineStateEnvelope(namespace: fixture.namespace,
        serialization: Data("complete".utf8), requiresInitialFetch: false),
      isInitialFetch: true)
    await transport.enqueue(.batch(CloudPendingBatch(batch: .fetched(completed), outbound: nil)))
    try await coordinator.processAutomaticChanges()

    let remote = await fixture.server.fullSnapshot(for: recordID)
    let hasLocal = try await fixture.hasLocal(archived.reference)
    let stored = try await fixture.stored()
    XCTAssertNotNil(remote)
    XCTAssertTrue(hasLocal)
    XCTAssertTrue(stored.readyEntities.contains { $0.reference == archived.reference })
  }

  func testFetchedLegacyListKeepsCanonicalSnipPlacementThroughCleanCompletion() async throws {
    for listInEarlierBatch in [false, true] {
      let fixture = try await Fixture()
      defer { fixture.remove() }
      let list = SnipList(id: UUID(), name: "Legacy list", systemImage: "folder", position: 1)
      let canonical = try CloudFullRecordCodec.listDraft(list,
        updatedAt: .distantPast, in: fixture.zone)
      let legacy = CloudRecordDraft(
        id: CloudRecordID(zone: fixture.zone, name: list.id.uuidString.lowercased()),
        recordType: canonical.recordType,
        schemaVersion: canonical.schemaVersion,
        routingFields: canonical.routingFields,
        encryptedFields: canonical.encryptedFields,
        removedEncryptedFields: canonical.removedEncryptedFields
      )
      let listSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: legacy))
      let snip = Snip(content: "keep legacy list placement", origin: .quickEntry, listID: list.id)
      let snipSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.snipDraft(snip, in: fixture.zone)))
      try await fixture.store.clearEngineState()
      if listInEarlierBatch {
        let first = CloudFetchedBatch(id: UUID(),
          items: [.record(listSnapshot), .record(snipSnapshot)],
          engineState: CloudEngineStateEnvelope(namespace: fixture.namespace,
            serialization: Data("first".utf8), requiresInitialFetch: true), isInitialFetch: true)
        try await fixture.store.stage(.fetched(first))
        try await fixture.store.applyStaged(first.id)
      }
      let completed = CloudFetchedBatch(id: UUID(),
        items: listInEarlierBatch ? [] : [.record(listSnapshot), .record(snipSnapshot)],
        zoneEvents: [.fetched(fixture.zone)],
        engineState: CloudEngineStateEnvelope(namespace: fixture.namespace,
          serialization: Data("complete".utf8), requiresInitialFetch: false), isInitialFetch: true)
      try await fixture.store.stage(.fetched(completed))
      try await fixture.store.applyStaged(completed.id)

      let local = try await fixture.library.checkedSnapshot(sortedBy: .manual)
      XCTAssertFalse(local.snips.contains { $0.id == snip.id }, "list in earlier batch: \(listInEarlierBatch)")
      let stored = try await fixture.stored()
      XCTAssertEqual(stored.namespaceState.initialFetchInventory?.canProveAbsence, true,
        "list in earlier batch: \(listInEarlierBatch)")
      XCTAssertTrue(stored.deferredEntities.contains {
        $0.reference == CloudEntityReference(kind: .snip, domainID: snip.id)
      }, "list in earlier batch: \(listInEarlierBatch)")
      XCTAssertTrue(stored.quarantines.contains {
        $0.identity.recordName == legacy.id.name
      }, "list in earlier batch: \(listInEarlierBatch)")
      let pending = try await fixture.store.pendingChanges()
      XCTAssertFalse(pending.operations.contains { $0.id == snipSnapshot.id },
        "list in earlier batch: \(listInEarlierBatch)")
    }
  }

  func testNewUnpreparedSnipArchiveDoesNotRetirePreparedBaseOnCleanAbsence() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let original = try await fixture.quarantineAcceptedRecord()
    _ = try await fixture.store.loadEngineState()
    let prepared = try await fixture.stored()
    XCTAssertTrue(prepared.readyEntities.contains { $0.reference == original.reference })
    let before = try await fixture.library.checkedSnapshot(sortedBy: .manual)
    let localSnip = try XCTUnwrap(before.snips.first { $0.id == original.reference.domainID })

    let newerDraft = CloudRecordDraft.text(id: CloudFullSyncPersistence.recordID(original.identity),
      snipID: original.reference.domainID, text: "newer unprepared archive")
    let newerPayload = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: newerDraft)).shadow.data
    let newerKey = CloudStoredQuarantine.corruptShadowKey(
      reference: original.reference, payload: newerPayload)
    let context = try fixture.context()
    context.insert(StoredCloudMappingQuarantine(namespaceKey: fixture.namespace.namespaceKey.rawValue,
      value: CloudQuarantineInput(key: newerKey, reference: original.reference,
        identity: original.identity, payload: newerPayload)))
    try context.save()

    try await fixture.applyCleanCompletion()
    let after = try await fixture.library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(after.snips.first { $0.id == localSnip.id }, localSnip)
    let stored = try await fixture.stored()
    XCTAssertTrue(stored.readyEntities.contains { $0.reference == original.reference })
    XCTAssertTrue(stored.quarantines.contains { $0.key == newerKey && $0.payload == newerPayload })
  }

  func testFetchedUnpreparedListDoesNotRepairItsSnipIntoInbox() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let first = try await fixture.removeLocalAndArchive(.list)
    let revisedList = SnipList(id: first.reference.domainID, name: "Another archived base",
      systemImage: "folder", position: 1)
    let revisedDraft = try CloudFullRecordCodec.listDraft(revisedList,
      updatedAt: .distantPast, in: fixture.zone)
    let secondPayload = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: revisedDraft)).shadow.data
    let secondKey = CloudStoredQuarantine.corruptShadowKey(
      reference: first.reference, payload: secondPayload)
    let context = try fixture.context()
    context.insert(StoredCloudMappingQuarantine(namespaceKey: fixture.namespace.namespaceKey.rawValue,
      value: CloudQuarantineInput(key: secondKey, reference: first.reference,
        identity: first.identity, payload: secondPayload)))
    try context.save()

    let snip = Snip(content: "keep this list placement", origin: .quickEntry,
      listID: first.reference.domainID)
    _ = try await fixture.server.send(CloudOutboundBatch(operations: [
      .save(try CloudFullRecordCodec.snipDraft(snip, in: fixture.zone)),
    ]), failures: [:])
    try await fixture.coordinator.prepareManualRetry()
    try await fixture.coordinator.fetchRemote()

    let local = try await fixture.library.checkedSnapshot(sortedBy: .manual)
    XCTAssertFalse(local.lists.contains { $0.id == first.reference.domainID })
    XCTAssertFalse(local.snips.contains { $0.id == snip.id })
    let stored = try await fixture.stored()
    XCTAssertTrue(stored.deferredEntities.contains {
      $0.reference == CloudEntityReference(kind: .snip, domainID: snip.id)
    })
    XCTAssertEqual(Set(stored.quarantines.map(\.key)), [first.key, secondKey])
    let pending = try await fixture.store.pendingChanges()
    XCTAssertFalse(pending.operations.contains { $0.id == .snip(snip.id, in: fixture.zone) })
  }

  func testSeveralArchivedBasesWithoutAcceptedStateCannotResurrectMissingLocalItem() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let first = try await fixture.removeLocalAndArchive(.snip)
    let draft = CloudRecordDraft.text(id: CloudFullSyncPersistence.recordID(first.identity),
      snipID: first.reference.domainID, text: "another old base")
    let payload = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft)).shadow.data
    let secondKey = CloudStoredQuarantine.corruptShadowKey(reference: first.reference, payload: payload)
    let context = try fixture.context()
    context.insert(StoredCloudMappingQuarantine(namespaceKey: fixture.namespace.namespaceKey.rawValue,
      value: CloudQuarantineInput(key: secondKey, reference: first.reference,
        identity: first.identity, payload: payload)))
    try context.save()
    try await fixture.coordinator.prepareManualRetry()
    try await fixture.coordinator.fetchRemote()
    let stored = try await fixture.stored()
    XCTAssertEqual(Set(stored.quarantines.map(\.key)), [first.key, secondKey])
    XCTAssertFalse(stored.readyEntities.contains { $0.reference == first.reference })
    let hasLocal = try await fixture.hasLocal(first.reference)
    XCTAssertFalse(hasLocal)
    let pending = try await fixture.store.pendingChanges()
    XCTAssertFalse(pending.operations.contains { $0.id == CloudFullSyncPersistence.recordID(first.identity) })
    let issue = try await fixture.store.unresolvedSyncIssue()
    XCTAssertEqual(issue, .appDataIssue)
  }

  func testMissingLocalSnipAndListStayDeletedAfterUnchangedServerRefetch() async throws {
    for kind: CloudEntityKind in [.snip, .list] {
      let fixture = try await Fixture()
      defer { fixture.remove() }
      let archive = try await fixture.removeLocalAndArchive(kind)
      try await fixture.coordinator.prepareManualRetry()
      _ = try await fixture.store.loadEngineState()
      let restored = try await fixture.stored()
      XCTAssertTrue(restored.readyEntities.contains { $0.reference == archive.reference })
      let hasRestoredLocal = try await fixture.hasLocal(archive.reference)
      XCTAssertFalse(hasRestoredLocal)
      let blocked = try await fixture.store.pendingChanges()
      XCTAssertFalse(blocked.operations.contains { $0.id == CloudFullSyncPersistence.recordID(archive.identity) })
      try await fixture.coordinator.fetchRemote()
      let hasFetchedLocal = try await fixture.hasLocal(archive.reference)
      XCTAssertFalse(hasFetchedLocal)
      try await fixture.coordinator.sendPendingUntilSettled()
      let remote = await fixture.server.fullSnapshot(for: CloudFullSyncPersistence.recordID(archive.identity))
      XCTAssertNil(remote)
      let finished = try await fixture.stored()
      XCTAssertEqual(finished.quarantines.map(\.payload), [archive.payload])
      XCTAssertTrue(finished.conflicts.isEmpty)
    }
  }

  func testMissingLocalSnipAndListKeepChangedServerInADeleteConflict() async throws {
    for kind: CloudEntityKind in [.snip, .list] {
      let fixture = try await Fixture()
      defer { fixture.remove() }
      let archive = try await fixture.removeLocalAndArchive(kind)
      try await fixture.changeServer(archive)
      try await fixture.coordinator.prepareManualRetry()
      try await fixture.coordinator.fetchRemote()
      let hasLocal = try await fixture.hasLocal(archive.reference)
      XCTAssertFalse(hasLocal)
      let stored = try await fixture.stored()
      XCTAssertEqual(stored.conflicts.map(\.reference), [archive.reference])
      XCTAssertEqual(stored.quarantines.map(\.key), [archive.corruptShadowResolutionMarker.key])
      let pending = try await fixture.store.pendingChanges()
      XCTAssertFalse(pending.operations.contains { $0.id == CloudFullSyncPersistence.recordID(archive.identity) })
      let ledger = try await fixture.stored().pendingDeletes
      XCTAssertFalse(ledger.contains { $0.reference == archive.reference })
      try await fixture.coordinator.sendPendingUntilSettled()
      let remote = await fixture.server.fullSnapshot(for: CloudFullSyncPersistence.recordID(archive.identity))
      XCTAssertNotNil(remote)
      let issue = try await fixture.store.unresolvedSyncIssue()
      XCTAssertEqual(issue, .appDataIssue)
    }
  }

  func testExplicitPendingDeletesSurviveQuarantineAndChangedServerFetch() async throws {
    for kind: CloudEntityKind in [.snip, .list] {
      let fixture = try await Fixture()
      defer { fixture.remove() }
      let archive = try await fixture.removeLocalAndArchive(kind, explicitDelete: true)
      let before = try await fixture.stored()
      XCTAssertEqual(before.pendingDeletes.map(\.reference), [archive.reference])
      try await fixture.changeServer(archive)
      try await fixture.coordinator.prepareManualRetry()
      try await fixture.coordinator.fetchRemote()
      try await fixture.coordinator.sendPendingUntilSettled()
      let remote = await fixture.server.fullSnapshot(for: CloudFullSyncPersistence.recordID(archive.identity))
      XCTAssertNil(remote)
    }
  }

  func testInitialFetchAbsenceRemovesRestoredAcceptedBaseWithoutResurrection() async throws {
    for kind: CloudEntityKind in [.snip, .list] {
      let fixture = try await Fixture()
      defer { fixture.remove() }
      let archive = try await fixture.removeLocalAndArchive(kind)
      try await fixture.changeServer(archive, delete: true)
      _ = try await fixture.store.loadEngineState()
      // A fresh CloudKit fetch may report absence without an old deletion event.
      try await fixture.applyCleanCompletion()
      let stored = try await fixture.stored()
      XCTAssertFalse(stored.readyEntities.contains { $0.reference == archive.reference })
      let hasLocal = try await fixture.hasLocal(archive.reference)
      XCTAssertFalse(hasLocal)
      XCTAssertEqual(stored.quarantines.map(\.key), [archive.corruptShadowResolutionMarker.key])
    }
  }

  func testLocalRecreationDuringRecoveryApplyReplansFromTheArchivedBase() async throws {
    for kind: CloudEntityKind in [.snip, .list] {
      let fixture = try await Fixture()
      defer { fixture.remove() }
      let archive = try await fixture.removeLocalAndArchive(kind)
      _ = try await fixture.store.loadEngineState()
      let reader = FakeCloudRecordTransport(server: fixture.server, namespace: fixture.namespace)
      try await reader.start(state: nil)
      let fetched = try await reader.fetch(scope: .all)
      try await fixture.store.stage(.fetched(fetched))
      switch kind {
      case .snip:
        _ = try await fixture.library.perform(.restore(snips: [Snip(id: archive.reference.domainID,
          content: "recreated locally", origin: .quickEntry)]), sortedBy: .manual)
      case .list:
        _ = try await fixture.library.perform(.restoreList(SnipList(id: archive.reference.domainID,
          name: "recreated locally", systemImage: "folder", position: 2)), sortedBy: .manual)
      }
      try await fixture.store.applyStaged(fetched.id)
      let hasLocal = try await fixture.hasLocal(archive.reference)
      XCTAssertTrue(hasLocal)
      let pending = try await fixture.store.pendingChanges()
      XCTAssertFalse(pending.operations.contains {
        if case .delete(let id, _) = $0 { return id == CloudFullSyncPersistence.recordID(archive.identity) }
        return false
      })
    }
  }

  func testNewArchiveDuringInitialFetchHasNoRecoveryProof() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let first = try await fixture.quarantineAcceptedRecord()
    _ = try await fixture.store.loadEngineState()
    let before = try await fixture.stored()
    _ = try await fixture.store.loadEngineState()
    let repeated = try await fixture.stored()
    XCTAssertEqual(repeated.readyEntities, before.readyEntities)
    XCTAssertEqual(repeated.quarantines, before.quarantines)
    let reader = FakeCloudRecordTransport(server: fixture.server, namespace: fixture.namespace)
    try await reader.start(state: nil)
    let fetched = try await reader.fetch(scope: .all)
    let draft = CloudRecordDraft.text(id: CloudFullSyncPersistence.recordID(first.identity),
      snipID: first.reference.domainID, text: "later archive")
    let payload = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft)).shadow.data
    let laterKey = CloudStoredQuarantine.corruptShadowKey(reference: first.reference, payload: payload)
    let context = try fixture.context()
    context.insert(StoredCloudMappingQuarantine(namespaceKey: fixture.namespace.namespaceKey.rawValue,
      value: CloudQuarantineInput(key: laterKey, reference: first.reference,
        identity: first.identity, payload: payload)))
    try context.save()
    try await fixture.store.stage(.fetched(fetched))
    try await fixture.store.applyStaged(fetched.id)
    let recovered = try await fixture.stored()
    XCTAssertEqual(Set(recovered.quarantines.map(\.key)), [first.corruptShadowResolutionMarker.key, laterKey])
    let issue = try await fixture.store.unresolvedSyncIssue()
    XCTAssertEqual(issue, .appDataIssue)
  }

  func testRecoverySurvivesRestartAfterEngineReset() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let archived = try await fixture.quarantineAcceptedRecord()
    try await fixture.coordinator.prepareManualRetry()
    let library = try SwiftDataSnipLibrary(storeURL: fixture.url)
    let store = CloudFullSyncPersistence(library: library, namespace: fixture.namespace, dataZone: fixture.zone)
    let coordinator = CloudFullSyncCoordinator(store: store,
      transport: FakeCloudRecordTransport(server: fixture.server, namespace: fixture.namespace))
    try await coordinator.fetchRemote()
    let recovered = try await library.cloudFullStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
    XCTAssertEqual(recovered.quarantines.map(\.key), [archived.corruptShadowResolutionMarker.key])
    XCTAssertEqual(recovered.quarantines.map(\.payload), [archived.payload])
    XCTAssertTrue(recovered.readyEntities.contains { $0.reference == archived.reference })
  }

  func testCrashAfterFetchCommitLeavesArchiveForAnotherFullFetch() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let archived = try await fixture.quarantineAcceptedRecord()
    try await fixture.coordinator.prepareManualRetry()
    let crash = ResolutionWriteFailure()
    let library = try SwiftDataSnipLibrary(storeURL: fixture.url,
      afterMutationBeforeSave: { try crash.hit() })
    let store = CloudFullSyncPersistence(library: library, namespace: fixture.namespace, dataZone: fixture.zone)
    let reader = FakeCloudRecordTransport(server: fixture.server, namespace: fixture.namespace)
    _ = try await store.loadEngineState()
    try await reader.start(state: nil)
    let fetched = try await reader.fetch(scope: .all)
    XCTAssertTrue(fetched.isInitialFetch)
    try await store.stage(.fetched(fetched))
    // Commit the fetched content and token, then fail the archive move before its save.
    crash.failOnWrite(2)
    await XCTAssertThrowsErrorAsync { try await store.applyStaged(fetched.id) }
    let afterCrash = try await library.cloudFullStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
    XCTAssertEqual(Set(afterCrash.quarantines.map(\.key)), [archived.key, archived.corruptShadowRecoveryMarker.key])
    XCTAssertTrue(afterCrash.readyEntities.contains { $0.reference == archived.reference })
    let savedToken = try await library.cloudTextSyncSnapshot(namespaceKey: fixture.namespace.namespaceKey).engineState
    XCTAssertFalse(try JSONDecoder().decode(CloudEngineStateEnvelope.self,
      from: XCTUnwrap(savedToken)).requiresInitialFetch)

    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: fixture.url)
    let reopened = CloudFullSyncPersistence(library: reopenedLibrary,
      namespace: fixture.namespace, dataZone: fixture.zone)
    let state = try await reopened.loadEngineState()
    XCTAssertNil(state)
    let coordinator = CloudFullSyncCoordinator(store: reopened,
      transport: FakeCloudRecordTransport(server: fixture.server, namespace: fixture.namespace))
    try await coordinator.fetchRemote()
    let recovered = try await reopenedLibrary.cloudFullStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
    XCTAssertEqual(recovered.quarantines.map(\.key), [archived.corruptShadowResolutionMarker.key])
    XCTAssertEqual(recovered.quarantines.map(\.payload), [archived.payload])
    let issue = try await reopened.unresolvedSyncIssue()
    XCTAssertNil(issue)
  }

  func testDowngradeRequarantineOfSameRevisionNeedsAnotherRecoveryAfterUpgrade() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let archived = try await fixture.quarantineAcceptedRecord()
    try await fixture.coordinator.prepareManualRetry()
    try await fixture.coordinator.fetchRemote()
    let firstRecovery = try await fixture.stored()
    let accepted = try XCTUnwrap(firstRecovery.readyEntities.first { $0.reference == archived.reference })
    XCTAssertEqual(accepted.shadowData, archived.payload)

    // Build 69 uses this same quarantine write when it rejects the accepted shadow again.
    try await fixture.library.quarantineCorruptCloudEntities(
      namespaceKey: fixture.namespace.namespaceKey, values: [accepted])
    let quarantinedAgain = try await fixture.stored()
    XCTAssertEqual(Set(quarantinedAgain.quarantines.map(\.key)),
      [archived.key, archived.corruptShadowResolutionMarker.key])
    let library = try SwiftDataSnipLibrary(storeURL: fixture.url)
    let upgraded = CloudFullSyncPersistence(library: library, namespace: fixture.namespace, dataZone: fixture.zone)
    let issue = try await upgraded.unresolvedSyncIssue()
    let state = try await upgraded.loadEngineState()
    let needsReset = try await upgraded.prepareManualRetry()
    XCTAssertEqual(issue, .appDataIssue)
    XCTAssertNil(state)
    XCTAssertTrue(needsReset)
    let coordinator = CloudFullSyncCoordinator(store: upgraded,
      transport: FakeCloudRecordTransport(server: fixture.server, namespace: fixture.namespace))
    try await coordinator.fetchRemote()
    let recovered = try await library.cloudFullStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
    XCTAssertEqual(recovered.quarantines, firstRecovery.quarantines)
    XCTAssertTrue(recovered.readyEntities.contains { $0.reference == archived.reference })
    let recoveredIssue = try await upgraded.unresolvedSyncIssue()
    XCTAssertNil(recoveredIssue)
  }

  func testRetryRecoversCanonicalListAndSnipArchivesTogether() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let accepted = try await fixture.stored().readyEntities
    XCTAssertEqual(Set(accepted.map(\.reference.kind)), [.list, .snip])
    try await fixture.library.quarantineCorruptCloudEntities(
      namespaceKey: fixture.namespace.namespaceKey, values: accepted)
    try await fixture.coordinator.prepareManualRetry()
    try await fixture.coordinator.fetchRemote()
    let recovered = try await fixture.stored()
    XCTAssertEqual(recovered.quarantines.count, accepted.count)
    XCTAssertEqual(recovered.quarantines.filter { $0.key.hasPrefix("resolved-") }.count, accepted.count)
    XCTAssertTrue(recovered.quarantines.allSatisfy { $0.format == .legacyBindingV1 })
    XCTAssertEqual(Set(recovered.quarantines.map(\.payload)), Set(accepted.map(\.shadowData)))
  }

  func testAcceptedRecordKeepsOpaqueSystemFieldsWithoutQuarantiningValidRawArchive() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let token = Data("opaque stored CAS token".utf8)
    let context = try fixture.context()
    let record = try XCTUnwrap(try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
      .first { $0.kind == CloudEntityKind.snip.rawValue })
    record.systemFields = token
    try context.save()
    let snapshot = try await fixture.stored()
    let accepted = try XCTUnwrap(snapshot.readyEntities.first { $0.reference.kind == .snip })
    let decoded = try CloudFullSyncPersistence.snipRecord(accepted)
    XCTAssertEqual(decoded.shadow.systemFields, token)
    XCTAssertEqual(decoded.domainID, record.domainID)
    _ = try await fixture.store.pendingChanges()
    let planned = try await fixture.stored()
    XCTAssertTrue(planned.quarantines.isEmpty)
    XCTAssertEqual(planned.readyEntities.first { $0.reference.kind == .snip }?.systemFields, token)
  }

  func testRetryRefetchesUnchangedRecordsAndKeepsResolvedArchivesAcrossReopenAndLaterChanges() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let archived = try await fixture.quarantineAcceptedRecord()
    let issue = try await fixture.store.unresolvedSyncIssue()
    XCTAssertEqual(issue, .appDataIssue)

    // An incremental fetch cannot restore a record that has not changed on the server.
    try await fixture.coordinator.fetchRemote()
    let beforeRetry = try await fixture.stored()
    XCTAssertFalse(beforeRetry.readyEntities.contains { $0.reference == archived.reference })
    XCTAssertEqual(beforeRetry.quarantines, [archived])
    try await fixture.coordinator.prepareManualRetry()
    let resetState = try await fixture.store.loadEngineState()
    XCTAssertNil(resetState)
    let prepared = try await fixture.stored()
    XCTAssertEqual(Set(prepared.quarantines.map(\.key)), [archived.key, archived.corruptShadowRecoveryMarker.key])
    try await fixture.coordinator.fetchRemote()
    let recovered = try await fixture.stored()
    XCTAssertTrue(recovered.readyEntities.contains { $0.reference == archived.reference })
    XCTAssertEqual(recovered.quarantines.count, 1)
    XCTAssertNil(recovered.quarantines.first { $0.key == archived.key })
    XCTAssertEqual(recovered.quarantines.first { $0.key == archived.corruptShadowResolutionMarker.key }?.payload,
      archived.payload)

    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: fixture.url)
    let reopened = CloudFullSyncPersistence(library: reopenedLibrary,
      namespace: fixture.namespace, dataZone: fixture.zone)
    let reopenedIssue = try await reopened.unresolvedSyncIssue()
    let status = try await reopened.statusEvidence()
    let enrollment = try await reopened.enrollmentEvidence()
    let resetNeeded = try await reopened.prepareManualRetry()
    XCTAssertNil(reopenedIssue)
    XCTAssertFalse(status.needsAttention)
    XCTAssertFalse(enrollment.needsAttention)
    XCTAssertFalse(resetNeeded)

    let local = await fixture.library.snapshot(sortedBy: .manual)
    let old = try XCTUnwrap(local.snips.first)
    _ = try await fixture.library.perform(.update(id: old.id, content: "later edit",
      attachmentURLs: nil, expectedUpdatedAt: old.updatedAt,
      now: old.updatedAt.addingTimeInterval(10)), sortedBy: .manual)
    try await fixture.coordinator.sendPendingUntilSettled()
    let laterIssue = try await fixture.store.unresolvedSyncIssue()
    XCTAssertNil(laterIssue)
    let afterEdit = try await fixture.stored()
    XCTAssertEqual(afterEdit.quarantines.first?.payload, archived.payload)

    XCTAssertEqual(afterEdit.quarantines, recovered.quarantines)
  }

  func testOnlyCleanCompletedInitialFetchAfterResetCanResolveArchives() async throws {
    for proof in ["incremental", "checkpoint", "send", "incomplete", "missing zone", "failed"] {
      let fixture = try await Fixture()
      defer { fixture.remove() }
      let archived = try await fixture.quarantineAcceptedRecord()
      let needsReset = try await fixture.store.prepareManualRetry()
      XCTAssertTrue(needsReset)
      try await fixture.store.clearEngineState()
      let completeState = CloudEngineStateEnvelope(namespace: fixture.namespace,
        serialization: Data(), requiresInitialFetch: false)
      if proof == "checkpoint" {
        try await fixture.store.saveEngineState(completeState)
      } else if proof == "send" {
        let sent = CloudSentBatch(id: UUID(), items: [], engineState: completeState)
        try await fixture.store.stage(.sent(sent), outbound: CloudOutboundBatch(operations: []))
        try await fixture.store.applyStaged(sent.id)
      } else {
        let fetched = CloudFetchedBatch(id: UUID(),
          items: proof == "failed" ? [.failed(.snip(archived.reference.domainID, in: fixture.zone), .invalidRecord)] : [],
          zoneEvents: proof == "missing zone" ? [] : [.fetched(fixture.zone)],
          engineState: proof == "incomplete" ? CloudEngineStateEnvelope(
            namespace: fixture.namespace, serialization: Data(), requiresInitialFetch: true) : completeState,
          isInitialFetch: proof != "incremental")
        try await fixture.store.stage(.fetched(fetched))
        try await fixture.store.applyStaged(fetched.id)
      }
      let incomplete = try await fixture.stored()
      XCTAssertEqual(incomplete.quarantines, [archived], proof)
      if proof == "failed" {
        // Once that initial fetch fails, a later successful fetch needs a new reset.
        try await fixture.applyCleanCompletion(isInitialFetch: false)
        let afterFailure = try await fixture.stored()
        XCTAssertEqual(afterFailure.quarantines, [archived])
      }
    }
  }

  func testMalformedOrMismatchedArchivesStayUnresolvedEvenWithAResolutionMarker() async throws {
    for failure in ["bytes", "key", "identity", "reference", "zone", "legacy name", "kind"] {
      for resolved in [false, true] {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let archived = try await fixture.quarantineAcceptedRecord()
        let context = try fixture.context()
        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<StoredCloudMappingQuarantine>()).first)
        if resolved {
          context.insert(StoredCloudMappingQuarantine(namespaceKey: fixture.namespace.namespaceKey.rawValue,
            value: archived.corruptShadowResolutionMarker))
        }
        switch failure {
        case "bytes": record.payload = Data("not an archive".utf8)
        case "key": record.id += "-wrong"
        case "identity": record.recordName = "s-\(UUID().uuidString.lowercased())"
        case "reference": record.domainID = UUID()
        case "zone": record.zoneName = "other-zone"
        case "kind": record.kind = CloudEntityKind.list.rawValue
        case "legacy name":
          let legacyDraft = CloudRecordDraft.text(id: CloudRecordID(zone: fixture.zone,
            name: archived.reference.domainID.uuidString.lowercased()),
            snipID: archived.reference.domainID, text: "legacy")
          record.payload = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: legacyDraft)).shadow.data
          record.recordName = legacyDraft.id.name
        default: XCTFail("Unknown test case")
        }
        if failure != "key" {
          let reference = CloudEntityReference(kind: CloudEntityKind(rawValue: record.kind)!, domainID: record.domainID)
          record.id = StoredCloudMappingQuarantine.key(namespaceKey: fixture.namespace.namespaceKey.rawValue,
            key: CloudStoredQuarantine.corruptShadowKey(reference: reference, payload: record.payload))
        }
        try context.save()
        let resetNeeded = try await fixture.store.prepareManualRetry()
        XCTAssertFalse(resetNeeded, "\(failure), resolved: \(resolved)")
        try await fixture.store.clearEngineState()
        try await fixture.applyCleanCompletion()
        let issue = try await fixture.store.unresolvedSyncIssue()
        let status = try await fixture.store.statusEvidence()
        XCTAssertEqual(issue, .appDataIssue, "\(failure), resolved: \(resolved)")
        XCTAssertTrue(status.needsAttention)
      }
    }
  }

  func testResolutionRejectsAnArchiveChangedSinceRetryAndKeepsAllBytes() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let archived = try await fixture.quarantineAcceptedRecord()
    _ = try await fixture.store.prepareManualRetry()
    try await fixture.store.clearEngineState()
    let replacement = Data("changed while fetching".utf8)
    let context = try fixture.context()
    let record = try XCTUnwrap(try context.fetch(FetchDescriptor<StoredCloudMappingQuarantine>()).first)
    record.payload = replacement
    try context.save()

    await XCTAssertThrowsErrorAsync {
      try await fixture.library.resolveCorruptCloudShadows(
        namespaceKey: fixture.namespace.namespaceKey, expected: [archived])
    }
    let stored = try await fixture.stored()
    XCTAssertEqual(stored.quarantines.count, 1)
    XCTAssertEqual(stored.quarantines.first?.format, .legacyBindingV1)
    XCTAssertEqual(stored.quarantines.first?.payload, replacement)
    XCTAssertNotEqual(stored.quarantines.first?.payload, archived.payload)
  }

  func testNewArchiveRevisionRemainsUnresolvedAfterEarlierRevisionResolved() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let original = try await fixture.quarantineAcceptedRecord()
    try await fixture.coordinator.prepareManualRetry()
    try await fixture.coordinator.fetchRemote()
    let context = try fixture.context()
    let accepted = try XCTUnwrap(try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
      .first { $0.domainID == original.reference.domainID })
    let draft = CloudRecordDraft.text(id: .snip(original.reference.domainID, in: fixture.zone),
      snipID: original.reference.domainID, text: "another archived revision")
    accepted.shadowData = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft)).shadow.data
    accepted.systemFields = Data("broken system fields".utf8)
    try context.save()
    let changedSnapshot = try await fixture.stored()
    let changed = try XCTUnwrap(changedSnapshot.readyEntities.first { $0.reference == original.reference })
    try await fixture.library.quarantineCorruptCloudEntities(
      namespaceKey: fixture.namespace.namespaceKey, values: [changed])
    let stored = try await fixture.stored()
    XCTAssertEqual(stored.quarantines.count, 2)
    XCTAssertEqual(stored.quarantines.filter { $0.key.hasPrefix("resolved-") }.map(\.payload), [original.payload])
    let unresolved = await fixture.store.unresolvedCorruptShadows(stored.quarantines)
    XCTAssertEqual(unresolved.map(\.payload), [changed.shadowData])
    let issue = try await fixture.store.unresolvedSyncIssue()
    let resetNeeded = try await fixture.store.prepareManualRetry()
    XCTAssertEqual(issue, .appDataIssue)
    XCTAssertTrue(resetNeeded)
  }

  func testResolutionMarkersUseFormatsUnderstoodByPreviousReaders() async throws {
    enum PreviousConflictFormat: String, Codable {
      case snipMergeV1, listMergeV1, legacyBindingV1
    }
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let original = try await fixture.quarantineAcceptedRecord()
    try await fixture.coordinator.prepareManualRetry()
    try await fixture.coordinator.fetchRemote()

    let context = try fixture.context()
    let quarantines = try context.fetch(FetchDescriptor<StoredCloudMappingQuarantine>())
    let conflicts = try context.fetch(FetchDescriptor<StoredCloudFullConflict>())
    XCTAssertEqual(quarantines.count, 1)
    for format in quarantines.map(\.format) + conflicts.map(\.format) {
      XCTAssertNotNil(PreviousConflictFormat(rawValue: format))
      XCTAssertNoThrow(try JSONDecoder().decode(PreviousConflictFormat.self,
        from: JSONEncoder().encode(format)))
    }
    let marker = try XCTUnwrap(quarantines.first {
      $0.id == StoredCloudMappingQuarantine.key(namespaceKey: fixture.namespace.namespaceKey.rawValue,
        key: original.corruptShadowResolutionMarker.key)
    })
    XCTAssertEqual(marker.format, PreviousConflictFormat.legacyBindingV1.rawValue)
    XCTAssertEqual(marker.payload, original.payload)
  }

  func testChangedResolutionMarkersRemainUnresolved() async throws {
    for failure in ["payload", "identity", "reference", "key", "format"] {
      let fixture = try await Fixture()
      defer { fixture.remove() }
      let original = try await fixture.quarantineAcceptedRecord()
      try await fixture.coordinator.prepareManualRetry()
      try await fixture.coordinator.fetchRemote()
      let context = try fixture.context()
      let rows = try context.fetch(FetchDescriptor<StoredCloudMappingQuarantine>())
      let marker = try XCTUnwrap(rows.first { $0.id.hasSuffix(original.corruptShadowResolutionMarker.key) })
      switch failure {
      case "payload": marker.payload = Data("changed proof".utf8)
      case "identity": marker.recordName += "-wrong"
      case "reference": marker.domainID = UUID()
      case "key": marker.id += "-wrong"
      case "format": marker.format = CloudConflictFormat.snipMergeV1.rawValue
      default: XCTFail("Unknown test case")
      }
      try context.save()
      let issue = try await fixture.store.unresolvedSyncIssue()
      let status = try await fixture.store.statusEvidence()
      XCTAssertEqual(issue, .appDataIssue, failure)
      XCTAssertTrue(status.needsAttention, failure)
    }
  }
}

/// The store calls a fresh engine start makes: read the engine state, then reset app evidence.
private func prepareFreshEngine(_ store: CloudFullSyncPersistence) async throws {
  _ = try await store.loadEngineState()
  try await store.prepareInitialFetch()
}

private func expectRecoveryReads(
  _ store: CloudFullSyncPersistence,
  recordID: CloudRecordID,
  blocked: Bool,
  attention: Bool,
  resetNeeded: Bool,
  _ stage: String,
  file: StaticString = #filePath,
  line: UInt = #line
) async throws {
  let admission = try await store.outboundAdmission()
  let issue = try await store.unresolvedSyncIssue()
  let status = try await store.statusEvidence()
  let reset = try await store.prepareManualRetry()
  XCTAssertEqual(admission.blockedRecordIDs.contains(recordID), blocked, "\(stage): blocked",
    file: file, line: line)
  XCTAssertEqual(issue, attention ? SyncedContentSyncIssue.appDataIssue : nil, "\(stage): issue",
    file: file, line: line)
  XCTAssertEqual(status.needsAttention, attention, "\(stage): attention", file: file, line: line)
  XCTAssertEqual(reset, resetNeeded, "\(stage): reset", file: file, line: line)
}

/// A stored quarantine row's columns, copied while its context is alive.
private struct QuarantineRow: Equatable {
  let id: String
  let namespaceKey: String
  let kind: String
  let domainID: UUID
  let zoneName: String
  let ownerName: String
  let recordName: String
  let format: String
  let payload: Data
}

private final class ResolutionWriteFailure: @unchecked Sendable {
  enum Failure: Error { case injected }
  private let lock = NSLock()
  private var remaining: Int?

  func failOnWrite(_ count: Int) { lock.withLock { remaining = count } }

  func hit() throws {
    try lock.withLock {
      guard let remaining else { return }
      self.remaining = remaining - 1
      if remaining == 1 { throw Failure.injected }
    }
  }
}

private struct Fixture {
  let root: URL
  let url: URL
  let namespace: CloudSyncNamespace
  let zone: CloudZoneID
  let library: SwiftDataSnipLibrary
  let store: CloudFullSyncPersistence
  let coordinator: CloudFullSyncCoordinator
  let server: FakeCloudServer

  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("CorruptShadowRecovery-\(UUID())")
    url = root.appendingPathComponent("store")
    zone = CloudZoneID(name: "SnipSnap", ownerName: "owner")
    namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [zone])
    library = try SwiftDataSnipLibrary(storeURL: url)
    store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    server = FakeCloudServer()
    let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
    try await writer.start(state: nil)
    let seeded = try await writer.send(CloudOutboundBatch(operations: [
      .save(try CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)),
      .save(try CloudFullRecordCodec.snipDraft(Snip(content: "remote text", origin: .quickEntry), in: zone)),
    ], zonesToSave: [zone]))
    try await writer.confirmApplied(seeded.id)
    let reader = FakeCloudRecordTransport(server: server, namespace: namespace)
    coordinator = CloudFullSyncCoordinator(store: store, transport: reader)
    try await coordinator.fetchRemote()
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func context() throws -> ModelContext {
    let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
    let configuration = ModelConfiguration("SnipSnapLocal", schema: schema, url: url, cloudKitDatabase: .none)
    return ModelContext(try ModelContainer(for: schema,
      migrationPlan: SnipSnapSchemaMigrationPlan.self, configurations: [configuration]))
  }

  func stored() async throws -> CloudFullStorageSnapshot {
    try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
  }

  func reopenedStore() throws -> CloudFullSyncPersistence {
    CloudFullSyncPersistence(library: try SwiftDataSnipLibrary(storeURL: url),
      namespace: namespace, dataZone: zone)
  }

  func quarantineRows() throws -> [QuarantineRow] {
    let context = try self.context()
    return try context.fetch(FetchDescriptor<StoredCloudMappingQuarantine>()).map {
      QuarantineRow(id: $0.id, namespaceKey: $0.namespaceKey, kind: $0.kind, domainID: $0.domainID,
        zoneName: $0.zoneName, ownerName: $0.ownerName, recordName: $0.recordName,
        format: $0.format, payload: $0.payload)
    }.sorted { $0.id < $1.id }
  }

  func quarantineAcceptedRecord() async throws -> CloudStoredQuarantine {
    let snapshot = try await stored()
    let record = try XCTUnwrap(snapshot.readyEntities.first { $0.reference.kind == .snip })
    try await library.quarantineCorruptCloudEntities(namespaceKey: namespace.namespaceKey, values: [record])
    let archived = try await stored()
    return try XCTUnwrap(archived.quarantines.first)
  }

  func removeLocalAndArchive(_ kind: CloudEntityKind, explicitDelete: Bool = false) async throws -> CloudStoredQuarantine {
    let reference: CloudEntityReference
    if kind == .list {
      let list = SnipList(id: UUID(), name: "Archive target", systemImage: "folder", position: 1)
      _ = try await server.send(CloudOutboundBatch(operations: [
        .save(try CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)),
      ]), failures: [:])
      try await coordinator.fetchRemote()
      reference = CloudEntityReference(kind: .list, domainID: list.id)
    } else {
      let snapshot = try await stored()
      reference = try XCTUnwrap(snapshot.readyEntities.first { $0.reference.kind == .snip }).reference
    }
    let snapshot = try await stored()
    let accepted = try XCTUnwrap(snapshot.readyEntities.first { $0.reference == reference })
    let command: SnipLibraryCommand = kind == .snip ? .delete(ids: [reference.domainID]) : .deleteList(id: reference.domainID)
    _ = try await library.perform(command, sortedBy: .manual)
    if explicitDelete {
      try await library.stageCloudPendingDeletes(namespaceKey: namespace.namespaceKey,
        values: [CloudPendingDelete(reference: reference, identity: accepted.identity)])
    }
    try await library.quarantineCorruptCloudEntities(namespaceKey: namespace.namespaceKey, values: [accepted])
    let archived = try await stored()
    return try XCTUnwrap(archived.quarantines.first { $0.reference == reference })
  }

  func changeServer(_ archive: CloudStoredQuarantine, delete: Bool = false) async throws {
    let id = CloudFullSyncPersistence.recordID(archive.identity)
    let value = await server.fullSnapshot(for: id)
    let current = try XCTUnwrap(value)
    let operation: CloudOutboundOperation
    if delete {
      operation = .delete(id, base: current.shadow)
    } else {
      var fields = current.encryptedFields
      fields[archive.reference.kind == .snip ? "text" : "desiredName"] = .string("changed remotely")
      operation = .save(CloudRecordDraft(id: id, recordType: current.recordType,
        schemaVersion: current.schemaVersion, routingFields: current.routingFields,
        encryptedFields: fields, base: current.shadow))
    }
    _ = try await server.send(CloudOutboundBatch(operations: [operation]), failures: [:])
  }

  func hasLocal(_ reference: CloudEntityReference) async throws -> Bool {
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    switch reference.kind {
    case .snip: return local.snips.contains { $0.id == reference.domainID }
    case .list: return local.lists.contains { $0.id == reference.domainID }
    }
  }

  func applyCleanCompletion(isInitialFetch: Bool = true) async throws {
    let fetched = CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(namespace: namespace,
        serialization: Data(), requiresInitialFetch: false), isInitialFetch: isInitialFetch)
    try await store.stage(.fetched(fetched))
    try await store.applyStaged(fetched.id)
  }
}
