import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

extension CloudFullSyncPersistenceTests {
  func testRemoteDeleteWithAttachmentsKeepsLocalBytesAndCreatesDurableConflict() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullAttachmentDeleteTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let attachmentURL = root.appendingPathComponent("source.txt")
    let attachmentBytes = Data("keep attachment bytes".utf8)
    try attachmentBytes.write(to: attachmentURL)
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "attached",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [attachmentURL],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let before = try await library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(before.snips.first(where: { $0.id == snipID }))
    let storedAttachmentURL = try XCTUnwrap(before.attachmentURLs[snip.attachments[0].id])
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let serverSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    )
    let seed = CloudFetchedBatch(
      id: UUID(),
      items: [.record(serverSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(seed))
    try await persistence.applyStaged(seed.id)
    let deletion = CloudFetchedBatch(
      id: UUID(),
      items: [.deleted(serverSnapshot.id)],
      engineState: nil
    )

    try await persistence.stage(.fetched(deletion))
    try await persistence.applyStaged(deletion.id)

    let after = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(after.snips.first(where: { $0.id == snipID })?.attachments, snip.attachments)
    XCTAssertEqual(try Data(contentsOf: storedAttachmentURL), attachmentBytes)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    XCTAssertFalse(stored.readyEntities.contains(where: { $0.reference.domainID == snipID }))
    XCTAssertEqual(stored.conflicts.map(\.reference), [
      CloudEntityReference(kind: .snip, domainID: snipID)
    ])
    let pending = try await persistence.pendingChanges()
    XCTAssertFalse(pending.operations.contains(where: { $0.id == serverSnapshot.id }))
  }

  func testEmptyFetchAtomicallyAdvancesTypedNamespaceAndEngineRevision() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullEmptyFetchTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let engine = CloudEngineStateEnvelope(namespace: namespace, serialization: Data([1, 2, 3]))
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let batch = CloudFetchedBatch(
      id: UUID(),
      items: [],
      zoneEvents: [.fetched(zone)],
      engineState: engine
    )

    try await persistence.stage(.fetched(batch))
    try await persistence.applyStaged(batch.id)

    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    XCTAssertEqual(stored.namespaceState.phase, .remoteChecked)
    XCTAssertEqual(stored.namespaceState.revision, 1)
    let loadedEngine = try await persistence.loadEngineState()
    let staged = try await persistence.stagedBatches()
    XCTAssertEqual(loadedEngine, engine)
    XCTAssertTrue(staged.isEmpty)
  }

  func testStagedFetchReplansAfterLocalEditAndKeepsTheRawBatchAcrossReopen() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullReplanTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let snip = Snip(content: "base", origin: .quickEntry)
    let inbox = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)
      )
    )
    let base = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    )
    let seed = CloudFetchedBatch(
      id: UUID(),
      items: [.record(inbox), .record(base)],
      engineState: nil
    )
    try await persistence.stage(.fetched(seed))
    try await persistence.applyStaged(seed.id)

    let accepted = try CloudFullRecordCodec.snip(from: base)
    let remoteValue = Snip(
      id: snip.id,
      requestID: snip.requestID,
      createdAt: snip.createdAt,
      updatedAt: Date(timeIntervalSince1970: 10),
      content: "remote text",
      origin: snip.origin,
      source: snip.source,
      listID: snip.listID,
      isDone: snip.isDone,
      manualSortKey: snip.manualSortKey
    )
    let remote = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.snipDraft(remoteValue, accepted: accepted)
      )
    )
    let update = CloudFetchedBatch(id: UUID(), items: [.record(remote)], engineState: nil)
    try await persistence.stage(.fetched(update))
    let beforeLocalEdit = await library.snapshot(sortedBy: .manual)
    let current = try XCTUnwrap(beforeLocalEdit.snips.first(where: { $0.id == snip.id }))
    _ = try await library.perform(.setDone(ids: [current.id], done: true), sortedBy: .manual)

    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let reopened = CloudFullSyncPersistence(
      library: reopenedLibrary,
      namespace: namespace,
      dataZone: zone
    )
    try await reopened.applyStaged(update.id)

    let merged = await reopenedLibrary.snapshot(sortedBy: .manual)
    let value = try XCTUnwrap(merged.snips.first(where: { $0.id == snip.id }))
    XCTAssertEqual(value.content, "remote text")
    XCTAssertTrue(value.isDone)
    let stagedAfterApply = try await reopened.stagedBatches()
    XCTAssertTrue(stagedAfterApply.isEmpty)
  }

  func testFetchFailuresProduceTypedRetryAndTerminalEvidence() async throws {
    for (failure, retryable, needsAttention) in [
      (CloudOperationFailure.retryable, true, false),
      (.quotaExceeded, false, true),
    ] {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudFullEvidenceTests-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let namespace = makeNamespace()
      let zone = try XCTUnwrap(namespace.zones.first)
      let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
      let persistence = CloudFullSyncPersistence(
        library: library,
        namespace: namespace,
        dataZone: zone
      )
      let batch = CloudFetchedBatch(
        id: UUID(),
        items: [.failed(nil, failure)],
        engineState: nil
      )
      try await persistence.stage(.fetched(batch))
      try await persistence.applyStaged(batch.id)

      let evidence = try await persistence.enrollmentEvidence()
      XCTAssertEqual(evidence.hasRetryableRecordFailures, retryable)
      XCTAssertEqual(evidence.needsAttention, needsAttention)
      XCTAssertEqual(evidence.retryableEventKeys.isEmpty, !retryable)
    }
  }

  func testMissingZoneOnlyArmsCreationAfterApprovalAndBlocksKnownNamespace() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullMissingZoneTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let newLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("new.store"))
    let fresh = CloudFullSyncPersistence(
      library: newLibrary,
      namespace: namespace,
      dataZone: zone
    )
    let missing = CloudFetchedBatch(
      id: UUID(),
      items: [],
      zoneEvents: [.failed(zone, .zoneMissing)],
      engineState: nil
    )
    try await fresh.stage(.fetched(missing))
    try await fresh.applyStaged(missing.id)
    var stored = try await newLibrary.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    XCTAssertEqual(stored.namespaceState.phase, .remoteCheckedMissingZone)
    XCTAssertFalse(stored.namespaceState.zoneCreationPending)
    var pending = try await fresh.pendingChanges()
    XCTAssertTrue(pending.zonesToSave.isEmpty)

    try await fresh.approveEnrollment(
      references: [CloudEntityReference(kind: .list, domainID: SnipList.inbox.id)]
    )
    stored = try await newLibrary.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    XCTAssertEqual(stored.namespaceState.phase, .seeding)
    XCTAssertTrue(stored.namespaceState.zoneCreationPending)
    pending = try await fresh.pendingChanges()
    XCTAssertEqual(pending.zonesToSave, [zone])

    let knownLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("known.store"))
    let known = CloudFullSyncPersistence(
      library: knownLibrary,
      namespace: namespace,
      dataZone: zone
    )
    let inbox = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)
      )
    )
    let seed = CloudFetchedBatch(id: UUID(), items: [.record(inbox)], engineState: nil)
    try await known.stage(.fetched(seed))
    try await known.applyStaged(seed.id)
    let knownMissing = CloudFetchedBatch(
      id: UUID(),
      items: [],
      zoneEvents: [.failed(zone, .zoneMissing)],
      engineState: nil
    )
    try await known.stage(.fetched(knownMissing))
    try await known.applyStaged(knownMissing.id)
    let knownStored = try await knownLibrary.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    XCTAssertEqual(knownStored.namespaceState.phase, .blocked)
    let knownEvidence = try await known.enrollmentEvidence()
    let knownPending = try await known.pendingChanges()
    XCTAssertTrue(knownEvidence.needsAttention)
    XCTAssertTrue(knownPending.zonesToSave.isEmpty)
  }

  func testCommittedRawBatchCanReplayAfterCrashBeforeReturn() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullCommitReplayTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let crash = OneShotFullApplyCrash()
    let first = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone,
      afterCommitHook: { try await crash.hit() }
    )
    let inbox = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)
      )
    )
    let batch = CloudFetchedBatch(id: UUID(), items: [.record(inbox)], engineState: nil)
    try await first.stage(.fetched(batch))
    await XCTAssertThrowsErrorAsync { try await first.applyStaged(batch.id) }

    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let reopened = CloudFullSyncPersistence(
      library: reopenedLibrary,
      namespace: namespace,
      dataZone: zone
    )
    try await reopened.stage(.fetched(batch))
    try await reopened.applyStaged(batch.id)
    let stored = try await reopenedLibrary.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    XCTAssertEqual(stored.namespaceState.revision, 1)
    let reopenedStaged = try await reopened.stagedBatches()
    XCTAssertTrue(reopenedStaged.isEmpty)
  }

  func testFullStagingIgnoresLegacyTextWorkForTheSameNamespace() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullLegacyIsolationTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let legacy = SwiftDataCloudTextPersistence(
      library: library,
      namespace: namespace,
      textZone: zone
    )
    let legacyBatch = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
    try await legacy.stage(.fetched(legacyBatch))
    let full = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )

    let legacyStaged = try await legacy.stagedBatches()
    let fullStaged = try await full.stagedBatches()
    XCTAssertEqual(legacyStaged.map(\.id), [legacyBatch.id])
    XCTAssertTrue(fullStaged.isEmpty)
  }

  func testFetchedSnipBeforeListDuplicateAndReorderedBatchesConverge() async throws {
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let list = SnipList(id: UUID(), name: "Later", systemImage: "clock", position: 1)
    let snip = Snip(
      id: UUID(),
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 1),
      content: "arrived first",
      origin: .share,
      listID: list.id,
      manualSortKey: try XCTUnwrap(SnipOrderKey.rebalanced(count: 1).first)
    )
    let listSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(
          list,
          updatedAt: Date(timeIntervalSince1970: 2),
          in: zone
        )
      )
    )
    let snipSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    )

    for records in [
      [snipSnapshot, listSnapshot, snipSnapshot],
      [listSnapshot, snipSnapshot, listSnapshot],
    ] {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudFullOrderTests-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
      let persistence = CloudFullSyncPersistence(
        library: library,
        namespace: namespace,
        dataZone: zone
      )
      let batch = CloudFetchedBatch(
        id: UUID(),
        items: records.map(CloudFetchItemResult.record),
        engineState: nil
      )
      try await persistence.stage(.fetched(batch))
      try await persistence.applyStaged(batch.id)
      let local = await library.snapshot(sortedBy: .manual)
      XCTAssertEqual(local.snips.first(where: { $0.id == snip.id })?.listID, list.id)
      XCTAssertEqual(local.lists.first(where: { $0.id == list.id })?.desiredName, "Later")
    }
  }

  func testDeferredSnipBecomesEnrolledWhenItsListArrivesAndCanUploadAnEdit() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDeferredEnrollmentTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let list = SnipList(id: UUID(), name: "Later", systemImage: "clock", position: 1)
    let snip = Snip(content: "before list", origin: .quickEntry, listID: list.id)
    let snipSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    )
    let listSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
      )
    )
    let snipBatch = CloudFetchedBatch(
      id: UUID(),
      items: [.record(snipSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(snipBatch))
    try await persistence.applyStaged(snipBatch.id)
    var stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    XCTAssertTrue(stored.deferredEntities.contains(where: { $0.reference.domainID == snip.id }))
    XCTAssertFalse(stored.enrolledEntities.contains(
      CloudEntityReference(kind: .snip, domainID: snip.id)
    ))

    let listBatch = CloudFetchedBatch(
      id: UUID(),
      items: [.record(listSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(listBatch))
    try await persistence.applyStaged(listBatch.id)
    stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    XCTAssertTrue(stored.readyEntities.contains(where: { $0.reference.domainID == snip.id }))
    XCTAssertTrue(stored.enrolledEntities.contains(
      CloudEntityReference(kind: .snip, domainID: snip.id)
    ))

    let local = await library.snapshot(sortedBy: .manual)
    let current = try XCTUnwrap(local.snips.first(where: { $0.id == snip.id }))
    _ = try await library.perform(
      .update(
        id: current.id,
        content: "edited after release",
        attachmentURLs: nil,
        expectedUpdatedAt: current.updatedAt,
        now: Date(timeIntervalSince1970: 10)
      ),
      sortedBy: .manual
    )
    let pending = try await persistence.pendingChanges()
    XCTAssertTrue(pending.operations.contains(where: { $0.id == snipSnapshot.id }))
  }

  func testRemoteMoveWaitsForItsListWithoutUploadingTheOldPlacement() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDeferredMoveTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let oldList = SnipList(id: UUID(), name: "Old", systemImage: "1.circle", position: 1)
    let newList = SnipList(id: UUID(), name: "New", systemImage: "2.circle", position: 2)
    let snip = Snip(content: "move me", origin: .quickEntry, listID: oldList.id)
    let oldListSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(oldList, updatedAt: .distantPast, in: zone)
      )
    )
    let inboxSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)
      )
    )
    let snipSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    )
    let seed = CloudFetchedBatch(
      id: UUID(),
      items: [.record(inboxSnapshot), .record(oldListSnapshot), .record(snipSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(seed))
    try await persistence.applyStaged(seed.id)

    let accepted = try CloudFullRecordCodec.snip(from: snipSnapshot)
    let moved = Snip(
      id: snip.id,
      requestID: snip.requestID,
      createdAt: snip.createdAt,
      updatedAt: Date(timeIntervalSince1970: 10),
      content: snip.content,
      origin: snip.origin,
      source: snip.source,
      listID: newList.id,
      isDone: snip.isDone,
      manualSortKey: snip.manualSortKey
    )
    let movedSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.snipDraft(moved, accepted: accepted)
      )
    )
    let movedBatch = CloudFetchedBatch(
      id: UUID(),
      items: [.record(movedSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(movedBatch))
    try await persistence.applyStaged(movedBatch.id)
    let waiting = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(waiting.snips.first(where: { $0.id == snip.id })?.listID, oldList.id)
    let waitingPending = try await persistence.pendingChanges()
    XCTAssertTrue(waitingPending.operations.isEmpty)
    var stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    XCTAssertTrue(stored.deferredEntities.contains(where: { $0.reference.domainID == snip.id }))
    XCTAssertFalse(stored.enrolledEntities.contains(
      CloudEntityReference(kind: .snip, domainID: snip.id)
    ))

    let newListSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(newList, updatedAt: .distantPast, in: zone)
      )
    )
    let listBatch = CloudFetchedBatch(
      id: UUID(),
      items: [.record(newListSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(listBatch))
    try await persistence.applyStaged(listBatch.id)
    let released = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(released.snips.first(where: { $0.id == snip.id })?.listID, newList.id)
    stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    XCTAssertTrue(stored.enrolledEntities.contains(
      CloudEntityReference(kind: .snip, domainID: snip.id)
    ))
  }

  func testLegacyRecordNameIsQuarantinedWithoutChangingLocalLibrary() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullLegacyTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let snip = Snip(content: "legacy", origin: .quickEntry)
    let canonical = try CloudFullRecordCodec.snipDraft(snip, in: zone)
    let legacy = CloudRecordDraft(
      id: CloudRecordID(zone: zone, name: snip.id.uuidString.lowercased()),
      recordType: canonical.recordType,
      schemaVersion: canonical.schemaVersion,
      routingFields: canonical.routingFields,
      encryptedFields: canonical.encryptedFields,
      removedEncryptedFields: canonical.removedEncryptedFields
    )
    let snapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: legacy))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let batch = CloudFetchedBatch(id: UUID(), items: [.record(snapshot)], engineState: nil)
    try await persistence.stage(.fetched(batch))
    try await persistence.applyStaged(batch.id)

    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertTrue(local.snips.isEmpty)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    XCTAssertTrue(stored.readyEntities.isEmpty)
    XCTAssertEqual(stored.quarantines.count, 1)
    XCTAssertEqual(stored.quarantines.first?.identity.recordName, legacy.id.name)
  }

  func testCanonicalAndLegacyRecordsForOneDomainApplyAndQuarantineInEitherOrder() async throws {
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let snip = Snip(content: "canonical wins", origin: .quickEntry)
    let canonicalDraft = try CloudFullRecordCodec.snipDraft(snip, in: zone)
    let legacyDraft = CloudRecordDraft(
      id: CloudRecordID(zone: zone, name: snip.id.uuidString.lowercased()),
      recordType: canonicalDraft.recordType,
      schemaVersion: canonicalDraft.schemaVersion,
      routingFields: canonicalDraft.routingFields,
      encryptedFields: canonicalDraft.encryptedFields,
      removedEncryptedFields: canonicalDraft.removedEncryptedFields
    )
    let canonical = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: canonicalDraft)
    )
    let legacy = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: legacyDraft)
    )

    for records in [[canonical, legacy], [legacy, canonical]] {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudFullCanonicalLegacyTests-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
      let persistence = CloudFullSyncPersistence(
        library: library,
        namespace: namespace,
        dataZone: zone
      )
      let batch = CloudFetchedBatch(
        id: UUID(),
        items: records.map(CloudFetchItemResult.record),
        engineState: nil
      )

      try await persistence.stage(.fetched(batch))
      try await persistence.applyStaged(batch.id)

      let local = try await library.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(local.snips.first(where: { $0.id == snip.id })?.content, "canonical wins")
      let stored = try await library.cloudFullStorageSnapshot(
        namespaceKey: namespace.canonicalKey
      )
      XCTAssertEqual(stored.readyEntities.map(\.identity.recordName), [canonical.id.name])
      XCTAssertEqual(stored.quarantines.map(\.identity.recordName), [legacy.id.name])
    }
  }

  func testFutureRecordTypeDoesNotBlockKnownRecordOrEngineAdvance() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullFutureTypeTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let list = SnipList(id: UUID(), name: "Known", systemImage: "folder", position: 1)
    let known = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
      )
    )
    let futureDraft = CloudRecordDraft(
      id: CloudRecordID(zone: zone, name: "a-\(UUID().uuidString.lowercased())"),
      recordType: "Attachment",
      schemaVersion: 9,
      routingFields: ["schemaVersion": .int64(9)],
      encryptedFields: ["future": .string("untouched")]
    )
    let future = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: futureDraft)
    )
    let engine = CloudEngineStateEnvelope(
      namespace: namespace,
      serialization: Data("after-future-record".utf8)
    )
    let batch = CloudFetchedBatch(
      id: UUID(),
      items: [.record(future), .record(known)],
      engineState: engine
    )

    try await persistence.stage(.fetched(batch))
    try await persistence.applyStaged(batch.id)

    let local = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(local.lists.first(where: { $0.id == list.id })?.desiredName, "Known")
    let storedEngine = try await persistence.loadEngineState()
    XCTAssertEqual(storedEngine, engine)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    XCTAssertFalse(stored.readyEntities.contains(where: {
      $0.identity.recordName == future.id.name
    }))
  }

  func testNewOldNewEditPreservesFutureFieldsAndUnknownOrigin() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullFutureFieldTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let snip = Snip(content: "future base", origin: .quickEntry)
    let base = try CloudFullRecordCodec.snipDraft(snip, in: zone)
    var encrypted = base.encryptedFields
    encrypted["origin"] = .string("future-origin")
    encrypted["futureField"] = .string("keep me")
    let future = CloudRecordDraft(
      id: base.id,
      recordType: base.recordType,
      schemaVersion: 9,
      routingFields: base.routingFields,
      encryptedFields: encrypted,
      removedEncryptedFields: base.removedEncryptedFields
    )
    let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
    try await writer.start(state: nil)
    let inbox = try CloudFullRecordCodec.listDraft(
      .inbox,
      updatedAt: Date(timeIntervalSince1970: 0),
      in: zone
    )
    let sent = try await writer.send(
      CloudOutboundBatch(operations: [.save(inbox), .save(future)])
    )
    try await writer.confirmApplied(sent.id)

    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let coordinator = CloudFullSyncCoordinator(
      store: persistence,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await coordinator.fetchRemote()
    let received = await library.snapshot(sortedBy: .manual)
    let oldClientSnip = try XCTUnwrap(received.snips.first(where: { $0.id == snip.id }))
    XCTAssertEqual(oldClientSnip.origin, .quickEntry)
    _ = try await library.perform(
      .update(
        id: snip.id,
        content: "old client edit",
        attachmentURLs: nil,
        expectedUpdatedAt: oldClientSnip.updatedAt,
        now: Date(timeIntervalSince1970: 10)
      ),
      sortedBy: .manual
    )
    try await coordinator.sendPending()

    let finalSnapshot = await server.fullSnapshot(for: base.id)
    let final = try XCTUnwrap(finalSnapshot)
    XCTAssertEqual(final.schemaVersion, 9)
    XCTAssertEqual(final.encryptedFields["origin"], .string("future-origin"))
    XCTAssertEqual(final.encryptedFields["futureField"], .string("keep me"))
    XCTAssertEqual(final.encryptedFields["text"], .string("old client edit"))
  }

  func testServerConflictMergesIndependentFieldsThenRetriesFromServerShadow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullConflictTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let firstLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("first.store"))
    let secondLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("second.store"))
    _ = try await firstLibrary.perform(
      .add(
        content: "base",
        origin: .quickEntry,
        source: SnipSource(applicationName: "Source"),
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    let seeded = await firstLibrary.snapshot(sortedBy: .manual)
    let seed = try XCTUnwrap(seeded.snips.first)
    let firstStore = CloudFullSyncPersistence(
      library: firstLibrary,
      namespace: namespace,
      dataZone: zone,
      now: { Date(timeIntervalSince1970: 2) }
    )
    try await firstStore.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: seed.id),
    ])
    let first = CloudFullSyncCoordinator(
      store: firstStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await first.sync()
    let secondStore = CloudFullSyncPersistence(
      library: secondLibrary,
      namespace: namespace,
      dataZone: zone,
      now: { Date(timeIntervalSince1970: 3) }
    )
    let second = CloudFullSyncCoordinator(
      store: secondStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await second.fetchRemote()

    _ = try await firstLibrary.perform(
      .update(
        id: seed.id,
        content: "server text",
        attachmentURLs: nil,
        expectedUpdatedAt: seed.updatedAt,
        now: Date(timeIntervalSince1970: 4)
      ),
      sortedBy: .manual
    )
    _ = try await secondLibrary.perform(.setDone(ids: [seed.id], done: true), sortedBy: .manual)
    try await first.sendPending()
    try await second.sendPending()
    try await second.sendPending()
    try await first.fetchRemote()

    let firstSnapshot = await firstLibrary.snapshot(sortedBy: .manual)
    let secondSnapshot = await secondLibrary.snapshot(sortedBy: .manual)
    let firstFinal = try XCTUnwrap(firstSnapshot.snips.first(where: { $0.id == seed.id }))
    let secondFinal = try XCTUnwrap(secondSnapshot.snips.first(where: { $0.id == seed.id }))
    XCTAssertEqual(firstFinal.content, "server text")
    XCTAssertTrue(firstFinal.isDone)
    XCTAssertEqual(secondFinal.content, "server text")
    XCTAssertTrue(secondFinal.isDone)
    let recordID = CloudRecordID.snip(seed.id, in: zone)
    let acceptedCount = await server.acceptedOperationCount(for: recordID)
    XCTAssertEqual(acceptedCount, 3)
  }

  func testLocalDeleteAndChangedServerRecordNeedsAttentionWithoutChoosing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDeleteConflictTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let firstLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("first.store"))
    let secondLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("second.store"))
    _ = try await firstLibrary.perform(
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
    let seeded = await firstLibrary.snapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(seeded.snips.first)
    let firstStore = CloudFullSyncPersistence(
      library: firstLibrary,
      namespace: namespace,
      dataZone: zone
    )
    try await firstStore.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snip.id),
    ])
    let first = CloudFullSyncCoordinator(
      store: firstStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await first.sync()
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
    _ = try await secondLibrary.perform(.delete(ids: [snip.id]), sortedBy: .manual)
    _ = try await firstLibrary.perform(
      .update(
        id: snip.id,
        content: "server changed",
        attachmentURLs: nil,
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )
    try await first.sendPending()
    try await second.sync()

    let secondLocal = await secondLibrary.snapshot(sortedBy: .manual)
    XCTAssertFalse(secondLocal.snips.contains(where: { $0.id == snip.id }))
    let stored = try await secondLibrary.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    XCTAssertEqual(stored.conflicts.count, 1)
    let payload = try JSONDecoder().decode(
      CloudSnipDeleteConflictPayload.self,
      from: try XCTUnwrap(stored.conflicts.first?.payload)
    )
    XCTAssertTrue(payload.localWasDeleted)
    XCTAssertEqual(payload.server.text, "server changed")
    let recordID = CloudRecordID.snip(snip.id, in: zone)
    let count = await server.acceptedOperationCount(for: recordID)
    XCTAssertEqual(count, 2)
  }

}
