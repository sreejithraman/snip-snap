import Foundation
import SwiftData
import XCTest

@testable import SnipSnapCore
@testable import SnipSnapPersistence

extension CloudFullRecordPersistenceTests {
  func testFullBatchCommitsLocalRecordsBasesConflictStageAndEngineOnce() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-a")
    let listID = UUID()
    let snipID = UUID()
    let list = SnipList(
      id: listID,
      name: "Work",
      systemImage: "briefcase",
      position: 1,
      sortKey: try XCTUnwrap(SnipOrderKey.rebalanced(count: 2).first)
    )
    let snipMutation = CloudLocalSnipMutation(
      snipID: snipID,
      requestID: snipID,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2),
      content: "remote",
      origin: .quickEntry,
      source: nil,
      listID: listID,
      isDone: false,
      orderKey: try XCTUnwrap(SnipOrderKey.rebalanced(count: 2).last)
    )
    let snipAccepted = entity(
      .snip,
      snipID,
      identity("s-batch"),
      dependencyListID: listID
    )
    let listAccepted = entity(.list, listID, identity("l-batch"))
    let conflict = CloudConflictInput(
      key: "batch-list-conflict",
      reference: listAccepted.reference,
      format: .listMergeV1,
      payload: Data("list conflict".utf8)
    )
    let batch = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: nil,
      nextEngineState: Data("engine-1".utf8),
      items: [
        CloudFullBatchItem(
          accepted: snipAccepted,
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localPrecondition: .requireMissing,
          localMutation: .upsertSnip(snipMutation),
          conflict: nil,
          quarantine: nil
        ),
        CloudFullBatchItem(
          accepted: listAccepted,
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localPrecondition: .requireMissing,
          localMutation: .upsertList(list),
          conflict: conflict,
          quarantine: nil
        ),
      ]
    )
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    try await store.stageCloudFullBatch(batch)
    let applied = try await store.commitCloudFullBatch(batch)
    let replayed = try await store.commitCloudFullBatch(batch)
    XCTAssertEqual(applied, .applied)
    XCTAssertEqual(replayed, .replayed)

    let local = await store.snapshot(sortedBy: .manual)
    XCTAssertEqual(local.snips.first(where: { $0.id == snipID })?.content, "remote")
    XCTAssertEqual(local.lists.first(where: { $0.id == listID })?.desiredName, "Work")
    let full = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertTrue(full.deferredEntities.isEmpty)
    XCTAssertEqual(Set(full.readyEntities.map(\.reference.domainID)), [snipID, listID])
    XCTAssertEqual(full.conflicts.map(\.key), ["batch-list-conflict"])
    let textState = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
    XCTAssertEqual(textState.engineState, Data("engine-1".utf8))
    XCTAssertTrue(textState.stagedBatches.isEmpty)

    let exactReplay = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: Data("engine-1".utf8),
      nextEngineState: Data("engine-2".utf8),
      items: [
        CloudFullBatchItem(
          accepted: snipAccepted,
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localPrecondition: .exactSnip(snipMutation),
          localMutation: .upsertSnip(snipMutation),
          conflict: nil,
          quarantine: nil
        )
      ]
    )
    try await store.stageCloudFullBatch(exactReplay)
    let exactResult = try await store.commitCloudFullBatch(exactReplay)
    XCTAssertEqual(exactResult, .applied)
    let afterExact = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(
      afterExact.readyEntities.first(where: { $0.reference.domainID == snipID })?.localRevision,
      1
    )

    let changed = CloudAcceptedEntityInput(
      reference: snipAccepted.reference,
      identity: snipAccepted.identity,
      schemaVersion: snipAccepted.schemaVersion,
      acceptedData: Data("changed".utf8),
      presenceData: snipAccepted.presenceData,
      shadowData: snipAccepted.shadowData,
      systemFields: Data("changed-system".utf8),
      dependencyListID: listID
    )
    let stale = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: Data("engine-2".utf8),
      nextEngineState: Data("must-not-commit".utf8),
      items: [
        CloudFullBatchItem(
          accepted: changed,
          expectedLocalRevision: 99,
          expectedSystemFields: snipAccepted.systemFields,
          localMutation: .none,
          conflict: nil,
          quarantine: nil
        )
      ]
    )
    try await store.stageCloudFullBatch(stale)
    do {
      _ = try await store.commitCloudFullBatch(stale)
      XCTFail("Expected stale accepted state to fail")
    } catch {
      XCTAssertEqual(error as? CloudFullStorageError, .staleAcceptedEntity)
    }
    let afterStale = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
    XCTAssertEqual(afterStale.engineState, Data("engine-2".utf8))
    XCTAssertEqual(afterStale.stagedBatches.map(\.id), [stale.batchID])
  }

  func testFullBatchDefersLocalSnipAndRollsBackEverySurfaceOnFailedSave() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-a")
    let listID = UUID()
    let snipID = UUID()
    let key = try XCTUnwrap(SnipOrderKey.rebalanced(count: 1).first)
    let mutation = CloudLocalSnipMutation(
      snipID: snipID,
      requestID: snipID,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      content: "held",
      origin: .quickEntry,
      source: nil,
      listID: listID,
      isDone: false,
      orderKey: key
    )
    let snipBatch = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: nil,
      nextEngineState: Data("engine-snip".utf8),
      items: [
        CloudFullBatchItem(
          accepted: entity(.snip, snipID, identity("s-held"), dependencyListID: listID),
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localPrecondition: .requireMissing,
          localMutation: .upsertSnip(mutation),
          conflict: nil,
          quarantine: nil
        )
      ]
    )
    do {
      let store = try SwiftDataSnipLibrary(storeURL: location.store)
      try await store.stageCloudFullBatch(snipBatch)
      let applied = try await store.commitCloudFullBatch(snipBatch)
      let local = await store.snapshot(sortedBy: .manual)
      XCTAssertEqual(applied, .applied)
      XCTAssertFalse(local.snips.contains { $0.id == snipID })
    }
    let list = SnipList(id: listID, name: "Later", systemImage: "clock", position: 1, sortKey: key)
    let listBatch = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: Data("engine-snip".utf8),
      nextEngineState: Data("engine-list".utf8),
      items: [
        CloudFullBatchItem(
          accepted: entity(.list, listID, identity("l-later")),
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localPrecondition: .requireMissing,
          localMutation: .upsertList(list),
          conflict: nil,
          quarantine: nil
        )
      ]
    )
    let staging = try SwiftDataSnipLibrary(storeURL: location.store)
    try await staging.stageCloudFullBatch(listBatch)
    let failing = try SwiftDataSnipLibrary(
      storeURL: location.store,
      afterMutationBeforeSave: { throw Crash.expected }
    )
    do {
      _ = try await failing.commitCloudFullBatch(listBatch)
      XCTFail("Expected the injected save failure")
    } catch {
      XCTAssertTrue(error is Crash)
    }
    let afterFailure = try SwiftDataSnipLibrary(storeURL: location.store)
    let failedLocal = await afterFailure.snapshot(sortedBy: .manual)
    XCTAssertFalse(failedLocal.snips.contains { $0.id == snipID })
    let stillStaged = try await afterFailure.cloudTextSyncSnapshot(namespaceKey: namespace)
    XCTAssertEqual(stillStaged.engineState, Data("engine-snip".utf8))
    XCTAssertEqual(stillStaged.stagedBatches.map(\.id), [listBatch.batchID])

    let released = try await afterFailure.commitCloudFullBatch(listBatch)
    let releasedLocal = await afterFailure.snapshot(sortedBy: .manual)
    XCTAssertEqual(released, .applied)
    XCTAssertEqual(releasedLocal.snips.first(where: { $0.id == snipID })?.content, "held")
    let ready = try await afterFailure.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertTrue(ready.deferredEntities.isEmpty)
  }

  func testFullBatchKeepsStageWhenLocalStateChangesAfterStaging() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-local-cas")
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    _ = try await store.perform(
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
    let baseSnapshot = await store.snapshot(sortedBy: .manual)
    let base = try XCTUnwrap(baseSnapshot.snips.first)
    let expected = CloudLocalSnipMutation(base)
    let incoming = CloudLocalSnipMutation(
      snipID: base.id,
      requestID: base.requestID,
      createdAt: base.createdAt,
      updatedAt: Date(timeIntervalSince1970: 2),
      content: "remote",
      origin: base.origin,
      source: base.source,
      listID: base.listID,
      isDone: base.isDone,
      orderKey: base.manualSortKey
    )
    let batch = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: nil,
      nextEngineState: Data("next".utf8),
      items: [
        CloudFullBatchItem(
          accepted: entity(.snip, base.id, identity("s-local-cas")),
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localPrecondition: .exactSnip(expected),
          localMutation: .upsertSnip(incoming),
          conflict: nil,
          quarantine: nil
        )
      ]
    )
    try await store.stageCloudFullBatch(batch)
    _ = try await store.perform(
      .update(
        id: base.id,
        content: "newer local",
        attachmentURLs: nil,
        expectedUpdatedAt: base.updatedAt,
        now: Date(timeIntervalSince1970: 3)
      ),
      sortedBy: .manual
    )

    do {
      _ = try await store.commitCloudFullBatch(batch)
      XCTFail("Expected stale local state")
    } catch {
      XCTAssertEqual(error as? CloudFullStorageError, .staleLocalEntity)
    }
    let after = await store.snapshot(sortedBy: .manual)
    XCTAssertEqual(after.snips.first?.content, "newer local")
    let wire = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
    XCTAssertNil(wire.engineState)
    XCTAssertEqual(wire.stagedBatches.map(\.id), [batch.batchID])
  }

  func testFullBatchRejectsFinalSnipStateThatReferencesARemovedList() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-final-state")
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let listUpdate = try await store.perform(
      .createList(name: "Work", systemImage: "briefcase"),
      sortedBy: .manual
    )
    guard case .listCreated(let list) = listUpdate.outcome else {
      return XCTFail("Expected a list")
    }
    let snipID = UUID()
    let snip = CloudLocalSnipMutation(
      snipID: snipID,
      requestID: snipID,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      content: "remote",
      origin: .quickEntry,
      source: nil,
      listID: list.id,
      isDone: false,
      orderKey: try XCTUnwrap(SnipOrderKey.rebalanced(count: 1).first)
    )
    let batch = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: nil,
      nextEngineState: Data("must-not-advance".utf8),
      items: [
        CloudFullBatchItem(
          accepted: entity(.snip, snipID, identity("s-final"), dependencyListID: list.id),
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localPrecondition: .requireMissing,
          localMutation: .upsertSnip(snip),
          conflict: nil,
          quarantine: nil
        ),
        CloudFullBatchItem(
          accepted: entity(.list, list.id, identity("l-final")),
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localPrecondition: .exactList(CloudLocalListMutation(list)),
          localMutation: .removeList(list.id),
          conflict: nil,
          quarantine: nil
        ),
      ]
    )
    try await store.stageCloudFullBatch(batch)
    do {
      _ = try await store.commitCloudFullBatch(batch)
      XCTFail("Expected invalid final state")
    } catch {
      XCTAssertEqual(error as? CloudFullStorageError, .invalidLocalMutation)
    }
    let after = await store.snapshot(sortedBy: .manual)
    XCTAssertTrue(after.lists.contains(where: { $0.id == list.id }))
    XCTAssertFalse(after.snips.contains(where: { $0.id == snipID }))
    let wire = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
    XCTAssertNil(wire.engineState)
    XCTAssertEqual(wire.stagedBatches.map(\.id), [batch.batchID])
  }

  func testFullBatchRejectsDuplicateEntityItemsInEitherOrder() async throws {
    for (collision, reversed) in [
      ("domain", false),
      ("domain", true),
      ("identity", false),
      ("identity", true),
    ] {
      let location = temporaryStore()
      defer { try? FileManager.default.removeItem(at: location.root) }
      let namespace = CloudSyncNamespaceKey(
        rawValue: "private|account-a|generation-duplicate-item-\(collision)-\(reversed)"
      )
      let firstID = UUID()
      let secondID = collision == "domain" ? firstID : UUID()
      let firstIdentity = identity("s-duplicate-item-first")
      let secondIdentity = collision == "identity"
        ? firstIdentity
        : identity("s-duplicate-item-second")
      let key = try XCTUnwrap(SnipOrderKey.rebalanced(count: 1).first)
      let firstMutation = CloudLocalSnipMutation(
        snipID: firstID,
        requestID: firstID,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        content: "first",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        isDone: false,
        orderKey: key
      )
      let secondMutation = CloudLocalSnipMutation(
        snipID: secondID,
        requestID: secondID,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        content: "second",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        isDone: false,
        orderKey: key
      )
      let first = CloudFullBatchItem(
        accepted: entity(.snip, firstID, firstIdentity),
        expectedLocalRevision: nil,
        expectedSystemFields: nil,
        localPrecondition: .requireMissing,
        localMutation: .upsertSnip(firstMutation),
        conflict: nil,
        quarantine: nil
      )
      let second = CloudFullBatchItem(
        accepted: entity(.snip, secondID, secondIdentity),
        expectedLocalRevision: nil,
        expectedSystemFields: nil,
        localPrecondition: .requireMissing,
        localMutation: .upsertSnip(secondMutation),
        conflict: nil,
        quarantine: nil
      )
      let batch = CloudFullBatchCommit(
        namespaceKey: namespace.rawValue,
        batchID: UUID(),
        expectedEngineState: nil,
        nextEngineState: Data("must-not-advance".utf8),
        items: reversed ? [second, first] : [first, second]
      )
      let store = try SwiftDataSnipLibrary(storeURL: location.store)
      try await store.stageCloudFullBatch(batch)
      do {
        _ = try await store.commitCloudFullBatch(batch)
        XCTFail("Expected duplicate batch item rejection")
      } catch {
        XCTAssertEqual(error as? CloudFullStorageError, .invalidBatchReplay)
      }
      let local = await store.snapshot(sortedBy: .manual)
      XCTAssertTrue(local.snips.isEmpty)
      let full = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
      XCTAssertTrue(full.readyEntities.isEmpty)
      XCTAssertTrue(full.deferredEntities.isEmpty)
      let wire = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
      XCTAssertNil(wire.engineState)
      XCTAssertEqual(wire.stagedBatches.map(\.id), [batch.batchID])
    }
  }

  func testFullBatchRemovesAcceptedAndLocalStateWithCASAndReplaysOnce() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-remove")
    let snipID = UUID()
    let key = try XCTUnwrap(SnipOrderKey.rebalanced(count: 1).first)
    let mutation = CloudLocalSnipMutation(
      snipID: snipID,
      requestID: snipID,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      content: "delete me",
      origin: .quickEntry,
      source: nil,
      listID: SnipList.inbox.id,
      isDone: false,
      orderKey: key
    )
    let accepted = entity(.snip, snipID, identity("s-remove"))
    let seed = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: nil,
      nextEngineState: Data("seeded".utf8),
      items: [
        CloudFullBatchItem(
          accepted: accepted,
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localPrecondition: .requireMissing,
          localMutation: .upsertSnip(mutation),
          conflict: nil,
          quarantine: nil
        )
      ]
    )
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    try await store.stageCloudFullBatch(seed)
    _ = try await store.commitCloudFullBatch(seed)

    let remove = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: Data("seeded".utf8),
      nextEngineState: Data("removed".utf8),
      items: [
        CloudFullBatchItem(
          accepted: accepted,
          acceptedAction: .remove,
          expectedLocalRevision: 1,
          expectedSystemFields: accepted.systemFields,
          localPrecondition: .exactSnip(mutation),
          localMutation: .removeSnip(snipID),
          conflict: nil,
          quarantine: nil
        )
      ]
    )
    try await store.stageCloudFullBatch(remove)
    let applied = try await store.commitCloudFullBatch(remove)
    let replayed = try await store.commitCloudFullBatch(remove)
    XCTAssertEqual(applied, .applied)
    XCTAssertEqual(replayed, .replayed)
    let local = await store.snapshot(sortedBy: .manual)
    XCTAssertTrue(local.snips.isEmpty)
    let full = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertTrue(full.readyEntities.isEmpty)
    XCTAssertTrue(full.deferredEntities.isEmpty)
    let wire = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
    XCTAssertEqual(wire.engineState, Data("removed".utf8))
  }

  func testFullBatchStaleAcceptedRemoveKeepsEverySurface() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-stale-remove")
    let accepted = entity(.list, SnipList.inbox.id, identity("l-stale-remove"))
    let seed = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: nil,
      nextEngineState: Data("seeded".utf8),
      items: [
        CloudFullBatchItem(
          accepted: accepted,
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localPrecondition: .exactList(CloudLocalListMutation(.inbox)),
          localMutation: .upsertList(.inbox),
          conflict: nil,
          quarantine: nil
        )
      ]
    )
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    try await store.stageCloudFullBatch(seed)
    _ = try await store.commitCloudFullBatch(seed)
    let remove = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: Data("seeded".utf8),
      nextEngineState: Data("must-not-advance".utf8),
      items: [
        CloudFullBatchItem(
          accepted: accepted,
          acceptedAction: .remove,
          expectedLocalRevision: 99,
          expectedSystemFields: accepted.systemFields,
          localPrecondition: .none,
          localMutation: .none,
          conflict: nil,
          quarantine: nil
        )
      ]
    )
    try await store.stageCloudFullBatch(remove)
    do {
      _ = try await store.commitCloudFullBatch(remove)
      XCTFail("Expected stale accepted remove")
    } catch {
      XCTAssertEqual(error as? CloudFullStorageError, .staleAcceptedEntity)
    }
    let full = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(full.readyEntities.count, 1)
    let wire = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
    XCTAssertEqual(wire.engineState, Data("seeded".utf8))
    XCTAssertEqual(wire.stagedBatches.map(\.id), [remove.batchID])
  }

  func testFullBatchUpdatesSnipFieldsWithoutTouchingAttachmentReferenceOrBytes() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
    let sourceURL = location.root.appendingPathComponent("input.bin")
    let laterSourceURL = location.root.appendingPathComponent("later.bin")
    let bytes = Data([9, 8, 7, 0, 255])
    let laterBytes = Data([1, 3, 3, 7])
    try bytes.write(to: sourceURL)
    try laterBytes.write(to: laterSourceURL)
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    _ = try await store.perform(
      .add(
        content: "before",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [sourceURL],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    let before = await store.snapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(before.snips.first)
    let attachment = try XCTUnwrap(snip.attachments.first)
    let attachmentURL = try XCTUnwrap(before.attachmentURLs[attachment.id])
    let mutation = CloudLocalSnipMutation(
      snipID: snip.id,
      requestID: snip.requestID,
      createdAt: snip.createdAt,
      updatedAt: Date(timeIntervalSince1970: 2),
      content: "after",
      origin: snip.origin,
      source: snip.source,
      listID: snip.listID,
      isDone: true,
      orderKey: snip.manualSortKey
    )
    let accepted = entity(.snip, snip.id, identity("s-attachment"))
    let batch = CloudFullBatchCommit(
      namespaceKey: "private|account-a|generation-a",
      batchID: UUID(),
      expectedEngineState: nil,
      nextEngineState: Data("engine".utf8),
      items: [
        CloudFullBatchItem(
          accepted: accepted,
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localPrecondition: .exactSnip(CloudLocalSnipMutation(snip)),
          localMutation: .upsertSnip(mutation),
          conflict: nil,
          quarantine: nil
        )
      ]
    )
    try await store.stageCloudFullBatch(batch)
    _ = try await store.perform(
      .editAttachments(
        snipID: snip.id,
        content: snip.content,
        edits: [
          .existing(attachmentID: attachment.id),
          .added(sourceURL: laterSourceURL),
        ],
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 3)
      ),
      sortedBy: .manual
    )
    _ = try await store.commitCloudFullBatch(batch)

    let after = await store.snapshot(sortedBy: .manual)
    let updated = try XCTUnwrap(after.snips.first(where: { $0.id == snip.id }))
    XCTAssertEqual(updated.content, "after")
    XCTAssertTrue(updated.isDone)
    XCTAssertEqual(updated.attachments.first, attachment)
    XCTAssertEqual(updated.attachments.count, 2)
    XCTAssertEqual(after.attachmentURLs[attachment.id], attachmentURL)
    XCTAssertEqual(try Data(contentsOf: attachmentURL), bytes)
    let laterAttachment = try XCTUnwrap(updated.attachments.last)
    let laterURL = try XCTUnwrap(after.attachmentURLs[laterAttachment.id])
    XCTAssertEqual(try Data(contentsOf: laterURL), laterBytes)
  }

  func testLegacyNamespaceClearRemovesEveryFullRecordRowAndReplayReceipt() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-clear")
    let snipID = UUID()
    let accepted = entity(.snip, snipID, identity("s-clear"))
    let batch = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: nil,
      nextEngineState: Data("engine".utf8),
      items: [
        CloudFullBatchItem(
          accepted: accepted,
          expectedLocalRevision: nil,
          expectedSystemFields: nil,
          localMutation: .none,
          conflict: nil,
          quarantine: nil
        )
      ]
    )
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    try await store.stageCloudFullBatch(batch)
    let firstApply = try await store.commitCloudFullBatch(batch)
    XCTAssertEqual(firstApply, .applied)
    try await store.testStoreCloudConflict(
      namespaceKey: namespace,
      key: "clear-conflict",
      reference: accepted.reference,
      payload: Data("conflict".utf8)
    )
    try await store.storeDormantCloudBase(
      namespaceKey: namespace,
      reference: accepted.reference,
      identity: accepted.identity,
      payload: Data("base".utf8)
    )
    try await store.setCloudEnrollment(
      namespaceKey: namespace,
      references: [
        accepted.reference,
        CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      ]
    )
    try await store.testAcceptCloudEntity(
      namespaceKey: namespace,
      value: entity(.snip, snipID, identity("s-clear-duplicate"))
    )
    try await store.stageCloudPendingDeletes(
      namespaceKey: namespace,
      values: [CloudPendingDelete(reference: accepted.reference, identity: accepted.identity)]
    )
    try await store.clearCloudTextSyncState(namespaceKey: namespace)

    let cleared = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertTrue(cleared.readyEntities.isEmpty)
    XCTAssertTrue(cleared.deferredEntities.isEmpty)
    XCTAssertTrue(cleared.conflicts.isEmpty)
    XCTAssertTrue(cleared.quarantines.isEmpty)
    XCTAssertTrue(cleared.enrolledEntities.isEmpty)
    XCTAssertTrue(cleared.pendingDeletes.isEmpty)
    let dormant = try await store.testDormantCloudBase(
      namespaceKey: namespace,
      reference: accepted.reference
    )
    XCTAssertNil(dormant)
    let clearedWire = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
    XCTAssertNil(clearedWire.engineState)
    XCTAssertTrue(clearedWire.stagedBatches.isEmpty)

    try await store.stageCloudFullBatch(batch)
    let afterClear = try await store.commitCloudFullBatch(batch)
    XCTAssertEqual(afterClear, .applied)
  }

}
