import Foundation
import SwiftData
import XCTest

@testable import SnipSnapCore
@testable import SnipSnapPersistence

final class CloudFullRecordPersistenceTests: XCTestCase {
  enum Crash: Error { case expected }

  func testRejectsDuplicateDomainAndRecordBindingsWithoutReplacingOriginal() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-a")
    let snipID = UUID()
    let firstID = identity("s-first")
    let first = entity(.snip, snipID, firstID)

    try await store.testAcceptCloudEntity(namespaceKey: namespace, value: first)
    try await store.testAcceptCloudEntity(
      namespaceKey: namespace,
      value: entity(.snip, snipID, identity("s-second"))
    )
    let otherID = UUID()
    try await store.testAcceptCloudEntity(
      namespaceKey: namespace,
      value: entity(.snip, otherID, firstID)
    )

    let snapshot = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(snapshot.readyEntities.map(\.reference), [first.reference])
    XCTAssertEqual(snapshot.readyEntities.first?.acceptedData, first.acceptedData)
    XCTAssertEqual(snapshot.quarantines.count, 2)
  }

  func testDefersSnipUntilItsListArrivesAndReleasesOnceAcrossReopen() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-a")
    let listID = UUID()
    let snipID = UUID()
    do {
      let store = try SwiftDataSnipLibrary(storeURL: location.store)
      try await store.testAcceptCloudEntity(
        namespaceKey: namespace,
        value: entity(.snip, snipID, identity("s-\(snipID)"), dependencyListID: listID)
      )
      let pending = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
      XCTAssertTrue(pending.readyEntities.isEmpty)
      XCTAssertEqual(pending.deferredEntities.map(\.reference.domainID), [snipID])
    }

    do {
      let store = try SwiftDataSnipLibrary(storeURL: location.store)
      let list = entity(.list, listID, identity("l-\(listID)"))
      try await store.testAcceptCloudEntity(namespaceKey: namespace, value: list)
      try await store.testAcceptCloudEntity(namespaceKey: namespace, value: list)
      let ready = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
      XCTAssertTrue(ready.deferredEntities.isEmpty)
      XCTAssertEqual(Set(ready.readyEntities.map(\.reference.domainID)), [listID, snipID])
    }
  }

  func testConflictReplayIsIdempotentButPayloadChangeIsRejected() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-a")
    let reference = CloudEntityReference(kind: .list, domainID: UUID())
    let payload = Data("conflict".utf8)
    let store = try SwiftDataSnipLibrary(storeURL: location.store)

    try await store.testStoreCloudConflict(
      namespaceKey: namespace,
      key: "stable-key",
      reference: reference,
      payload: payload
    )
    try await store.testStoreCloudConflict(
      namespaceKey: namespace,
      key: "stable-key",
      reference: reference,
      payload: payload
    )
    do {
      try await store.testStoreCloudConflict(
        namespaceKey: namespace,
        key: "stable-key",
        reference: reference,
        payload: Data("changed".utf8)
      )
      XCTFail("Expected changed replay to fail")
    } catch {
      XCTAssertEqual(error as? CloudFullStorageError, .invalidConflictReplay)
    }
    let snapshot = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(
      snapshot.conflicts,
      [
        CloudStoredConflict(
          key: "stable-key",
          reference: reference,
          format: .listMergeV1,
          payload: payload
        )
      ]
    )
  }

  func testAcceptedEntityAndConflictCommitTogetherOrNotAtAll() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-a")
    let snipID = UUID()
    let value = entity(.snip, snipID, identity("s-atomic"))
    let conflict = CloudConflictInput(
      key: "atomic-key",
      reference: value.reference,
      format: .snipMergeV1,
      payload: Data("payload".utf8)
    )
    let failing = try SwiftDataSnipLibrary(
      storeURL: location.store,
      afterMutationBeforeSave: { throw Crash.expected }
    )
    do {
      try await failing.testAcceptCloudEntity(
        namespaceKey: namespace,
        value: value,
        conflict: conflict
      )
      XCTFail("Expected the injected write failure")
    } catch {
      XCTAssertTrue(error is Crash)
    }

    let reopened = try SwiftDataSnipLibrary(storeURL: location.store)
    let empty = try await reopened.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertTrue(empty.readyEntities.isEmpty)
    XCTAssertTrue(empty.conflicts.isEmpty)

    try await reopened.testAcceptCloudEntity(
      namespaceKey: namespace,
      value: value,
      conflict: conflict
    )
    let committed = try await reopened.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(committed.readyEntities.map(\.reference), [value.reference])
    XCTAssertEqual(committed.conflicts.map(\.key), [conflict.key])
  }

  func testEnrollmentRequiresListDependencyAndDormantBaseUsesExactNamespace() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-a")
    let otherAccount = CloudSyncNamespaceKey(rawValue: "private|account-b|generation-a")
    let otherGeneration = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-b")
    let list = CloudEntityReference(kind: .list, domainID: UUID())
    let snip = CloudEntityReference(kind: .snip, domainID: UUID())
    try await store.testAcceptCloudEntity(
      namespaceKey: namespace,
      value: entity(.list, list.domainID, identity("l-list"))
    )
    try await store.testAcceptCloudEntity(
      namespaceKey: namespace,
      value: entity(.snip, snip.domainID, identity("s-snip"), dependencyListID: list.domainID)
    )
    do {
      try await store.setCloudEnrollment(namespaceKey: namespace, references: [snip])
      XCTFail("Expected dependency-closed enrollment")
    } catch {
      XCTAssertEqual(error as? CloudFullStorageError, .invalidEnrollment)
    }
    try await store.setCloudEnrollment(namespaceKey: namespace, references: [list, snip])
    let transferBeforeDormant = try await store.transferSnapshot(revision: 1)
    try await store.storeDormantCloudBase(
      namespaceKey: namespace,
      reference: snip,
      identity: identity("s-snip"),
      payload: Data("base".utf8)
    )

    let exact = try await store.testDormantCloudBase(namespaceKey: namespace, reference: snip)
    let wrongAccount = try await store.testDormantCloudBase(
      namespaceKey: otherAccount,
      reference: snip
    )
    let wrongGeneration = try await store.testDormantCloudBase(
      namespaceKey: otherGeneration,
      reference: snip
    )
    XCTAssertEqual(exact?.payload, Data("base".utf8))
    XCTAssertNil(wrongAccount)
    XCTAssertNil(wrongGeneration)
    let transferAfterDormant = try await store.transferSnapshot(revision: 1)
    XCTAssertNotEqual(
      SnipLibraryTransferPlanner.digest(snapshot: transferBeforeDormant),
      SnipLibraryTransferPlanner.digest(snapshot: transferAfterDormant)
    )

    let localNamespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-local-seed")
    let localList = CloudEntityReference(kind: .list, domainID: UUID())
    let localSnip = CloudEntityReference(kind: .snip, domainID: UUID())
    try await store.setCloudEnrollment(
      namespaceKey: localNamespace,
      references: [localList, localSnip],
      localDependencies: [localSnip.domainID: localList.domainID]
    )
    let localEnrollment = try await store.cloudFullStorageSnapshot(namespaceKey: localNamespace)
    XCTAssertEqual(localEnrollment.enrolledEntities, [localList, localSnip])

    do {
      try await store.storeDormantCloudBase(
        namespaceKey: namespace,
        reference: snip,
        identity: identity("other-record"),
        payload: Data("other".utf8)
      )
      XCTFail("Expected the dormant domain collision")
    } catch {
      XCTAssertEqual(error as? CloudFullStorageError, .duplicateDormantBinding)
    }
    do {
      try await store.storeDormantCloudBase(
        namespaceKey: namespace,
        reference: CloudEntityReference(kind: .snip, domainID: UUID()),
        identity: identity("s-snip"),
        payload: Data("other".utf8)
      )
      XCTFail("Expected the dormant identity collision")
    } catch {
      XCTAssertEqual(error as? CloudFullStorageError, .duplicateDormantBinding)
    }
  }

  func testTransferSavesDormantBundleWithLocalCandidateOrRollsBackBoth() async throws {
    let sourceLocation = temporaryStore()
    let targetLocation = temporaryStore()
    defer {
      try? FileManager.default.removeItem(at: sourceLocation.root)
      try? FileManager.default.removeItem(at: targetLocation.root)
    }
    let source = try SwiftDataSnipLibrary(storeURL: sourceLocation.store)
    let target = try SwiftDataSnipLibrary(
      storeURL: targetLocation.store,
      afterMutationBeforeSave: { throw Crash.expected }
    )
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-a")
    let otherNamespace = CloudSyncNamespaceKey(rawValue: "private|account-b|generation-b")
    let first = CloudEntityReference(kind: .snip, domainID: UUID())
    let second = CloudEntityReference(kind: .list, domainID: UUID())
    try await source.storeDormantCloudBase(
      namespaceKey: namespace,
      reference: first,
      identity: identity("s-first"),
      payload: Data("first-base".utf8)
    )
    try await source.storeDormantCloudBase(
      namespaceKey: otherNamespace,
      reference: second,
      identity: identity("l-second"),
      payload: Data("second-base".utf8)
    )
    _ = try await source.perform(
      .add(
        content: "copied with bases",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    let snapshot = try await source.transferSnapshot(revision: 4)
    let plan = try await target.prepareTransferPlan(
      snapshot,
      transitionID: UUID(),
      replacingTargetSnipIDs: [],
      priorSeedProvenance: [],
      priorServerAcceptedSnipIDs: [],
      priorSeededListIDs: []
    )

    do {
      _ = try await target.applyTransferPlan(plan)
      XCTFail("Expected the transfer save to fail")
    } catch {
      XCTAssertTrue(error is Crash)
    }
    let failed = try SwiftDataSnipLibrary(storeURL: targetLocation.store)
    let failedSnapshot = await failed.snapshot(sortedBy: SnipSortMode.manual)
    XCTAssertTrue(failedSnapshot.snips.isEmpty)
    let basesAfterFailure = try await failed.dormantCloudBases()
    XCTAssertTrue(basesAfterFailure.isEmpty)

    _ = try await failed.applyTransferPlan(plan)
    let copied = await failed.snapshot(sortedBy: SnipSortMode.manual)
    XCTAssertEqual(
      copied.snips.map { $0.content },
      ["copied with bases"]
    )
    let bases = try await failed.dormantCloudBases()
    XCTAssertEqual(
      bases.map(\.namespaceKey),
      [namespace.rawValue, otherNamespace.rawValue]
    )
    XCTAssertEqual(
      bases.map(\.payload),
      [Data("first-base".utf8), Data("second-base".utf8)]
    )
  }

  func entity(
    _ kind: CloudEntityKind,
    _ id: UUID,
    _ identity: CloudTextStorageIdentity,
    dependencyListID: UUID? = nil
  ) -> CloudAcceptedEntityInput {
    CloudAcceptedEntityInput(
      reference: CloudEntityReference(kind: kind, domainID: id),
      identity: identity,
      schemaVersion: 2,
      acceptedData: Data("accepted-\(id)".utf8),
      presenceData: Data("presence-\(id)".utf8),
      shadowData: Data("shadow-\(id)".utf8),
      systemFields: Data("system-\(id)".utf8),
      dependencyListID: dependencyListID ?? (kind == .snip ? SnipList.inbox.id : nil)
    )
  }

  func identity(_ name: String) -> CloudTextStorageIdentity {
    CloudTextStorageIdentity(zoneName: "SnipSnap", ownerName: "owner", recordName: name)
  }

  func temporaryStore() -> (root: URL, store: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullRecordPersistenceTests-\(UUID().uuidString)")
    return (root, root.appendingPathComponent("snips.store"))
  }
}
