import Foundation
import XCTest

@testable import SnipSnapCore
@testable import SnipSnapPersistence

final class SnipRecoveryPersistenceTests: XCTestCase {
  private enum Crash: Error { case expected }

  func testSyncModeJournalPersistsAndRecoversAFrozenTransition() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let syncModeRoot = location.root.appendingPathComponent("SyncMode", isDirectory: true)
    let namespace = ICloudSyncNamespaceBinding(
      scope: "private",
      accountLineage: "account-a",
      generation: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      zones: [ICloudSyncZoneBinding(name: "SnipSnap", ownerName: "owner-a")]
    )
    let persistence = try SwiftDataSyncModePersistence(rootURL: syncModeRoot)

    _ = try await persistence.beginTransition(to: .iCloudSync, namespace: namespace)
    try await persistence.recordPreparationComplete()
    let token = try await persistence.freezeSource()
    _ = try await persistence.finalSnapshot(using: token)

    let frozen = try await persistence.snapshot().transition
    XCTAssertEqual(frozen?.phase, .sourceFrozen)
    XCTAssertEqual(frozen?.freezeToken, token)
    XCTAssertEqual(frozen?.freezeSnapshotTaken, true)

    let reopened = try SwiftDataSyncModePersistence(rootURL: syncModeRoot)
    let recovered = try await reopened.snapshot().transition
    XCTAssertEqual(recovered?.phase, .candidateReady)
    XCTAssertNil(recovered?.freezeToken)
    XCTAssertEqual(recovered?.freezeSnapshotTaken, false)

    try await reopened.recordPreparationComplete()
    let resumed = try await reopened.snapshot().transition
    XCTAssertEqual(resumed?.phase, .remoteFetched)
  }

  func testAppAssemblyKeepsPendingCloudTransitionOutOfActiveRecoveryScope() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let syncModeRoot = location.root.appendingPathComponent("SyncMode", isDirectory: true)
    let namespace = ICloudSyncNamespaceBinding(
      scope: "private",
      accountLineage: "account-a",
      generation: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      zones: [ICloudSyncZoneBinding(name: "SnipSnap", ownerName: "owner-a")]
    )
    let persistence = try SwiftDataSyncModePersistence(rootURL: syncModeRoot)
    _ = try await persistence.beginTransition(to: .iCloudSync, namespace: namespace)
    let store = try SwiftDataSnipLibrary(storeURL: location.store)

    let assembly = SnipLibraryAssembly(
      library: store,
      syncModeRootURL: syncModeRoot
    )

    XCTAssertNil(assembly.recoveryScope)
    XCTAssertEqual(
      SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: syncModeRoot),
      .settingUp(namespace)
    )
  }

  func testAppAssemblyDiscoveryIsReadOnlyAndFailsClosed() throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let missingRoot = location.root.appendingPathComponent("MissingSyncMode", isDirectory: true)

    let localOnly = SnipLibraryAssembly(library: store, syncModeRootURL: missingRoot)

    XCTAssertNil(localOnly.recoveryScope)
    XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path))

    let malformedRoot = location.root.appendingPathComponent("MalformedSyncMode", isDirectory: true)
    try FileManager.default.createDirectory(at: malformedRoot, withIntermediateDirectories: true)
    try Data("{\"version\":2}".utf8).write(
      to: malformedRoot.appendingPathComponent("activation.json")
    )

    let malformed = SnipLibraryAssembly(library: store, syncModeRootURL: malformedRoot)

    XCTAssertNil(malformed.recoveryScope)
  }

  func testAppAssemblyRoutesLibraryCallsToTheActiveSyncModeStore() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let syncModeRoot = location.root.appendingPathComponent("SyncMode", isDirectory: true)
    let persistence = try SwiftDataSyncModePersistence(rootURL: syncModeRoot)
    let active = try await persistence.activeLibrary()
    _ = try await active.perform(
      .add(
        content: "active sync-mode value",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    let original = try SwiftDataSnipLibrary(storeURL: location.store)
    _ = try await original.perform(
      .add(
        content: "wrong original value",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )

    let assembly = SnipLibraryAssembly(
      library: original,
      syncModeRootURL: syncModeRoot
    )
    let snapshot = await assembly.library.snapshot(sortedBy: .manual)

    XCTAssertEqual(snapshot.snips.map(\.content), ["active sync-mode value"])
  }

  func testAppAssemblyUsesTheActiveCloudNamespaceWithARealRecoveryLibrary() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = ICloudSyncNamespaceBinding(
      scope: "private",
      accountLineage: "account-a",
      generation: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      zones: [ICloudSyncZoneBinding(name: "SnipSnap", ownerName: "owner-a")]
    )
    let current = Snip(content: "Current", origin: .quickEntry)
    let recoveredValue = Snip(id: UUID(), content: "Recovered", origin: .quickEntry)
    let recovered = RecoveredSnip(
      id: recoveredValue.id,
      currentSnipID: current.id,
      recovered: recoveredValue,
      conflictingFields: [.text]
    )
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let localAssembly = SnipLibraryAssembly(
      library: store,
      activeCloudNamespace: nil
    )
    XCTAssertNil(localAssembly.recoveryScope)

    let cloudAssembly = SnipLibraryAssembly(
      library: store,
      activeCloudNamespace: namespace
    )
    let scope = try XCTUnwrap(cloudAssembly.recoveryScope)
    XCTAssertEqual(scope.rawValue, namespace.namespaceKey.rawValue)

    _ = try await store.perform(.restore(snips: [current]), sortedBy: .manual)
    try await store.testStoreCloudConflict(
      namespaceKey: CloudSyncNamespaceKey(rawValue: scope.rawValue),
      key: "app-assembly",
      reference: CloudEntityReference(kind: .snip, domainID: current.id),
      payload: Data("wire".utf8),
      recovery: .snip(recovered)
    )

    let pending = try await cloudAssembly.library.recoverySnapshot(in: scope)
    XCTAssertEqual(pending.pendingSnips, [recovered])
    _ = try await cloudAssembly.library.resolveRecovery(
      recovered.id,
      in: scope,
      choice: .keepCurrent
    )
    let afterResolution = try await cloudAssembly.library.recoverySnapshot(in: scope)
    XCTAssertEqual(afterResolution, .empty)
  }

  func testUseRecoveredRereadsCurrentAndChangesOnlyConflictingSnipFieldsAcrossReopen() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let scope = SnipRecoveryScope("private|account-a|generation-a")
    let otherList = SnipList(id: UUID(), name: "Other", systemImage: "folder", position: 1)
    let current = Snip(
      id: UUID(),
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 10),
      updatedAt: Date(timeIntervalSince1970: 20),
      content: "Server text",
      origin: .quickEntry,
      source: SnipSource(applicationName: "Server app"),
      listID: SnipList.inboxID,
      isDone: false
    )
    let recovered = Snip(
      id: UUID(),
      requestID: current.requestID,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt,
      content: "Local text",
      origin: current.origin,
      source: SnipSource(applicationName: "Stale app"),
      listID: SnipList.inboxID,
      isDone: false
    )
    let item = RecoveredSnip(
      id: recovered.id,
      currentSnipID: current.id,
      recovered: recovered,
      conflictingFields: [.text]
    )

    do {
      let store = try SwiftDataSnipLibrary(storeURL: location.store)
      _ = try await store.perform(
        .createList(name: otherList.name, systemImage: otherList.systemImage),
        sortedBy: .manual
      )
      let listSnapshot = await store.snapshot(sortedBy: .manual)
      let storedList = try XCTUnwrap(
        listSnapshot.lists.first { $0.name == otherList.name }
      )
      _ = try await store.perform(.restore(snips: [current]), sortedBy: .manual)
      try await store.testStoreCloudConflict(
        namespaceKey: CloudSyncNamespaceKey(rawValue: scope.rawValue),
        key: "snip-text",
        reference: CloudEntityReference(kind: .snip, domainID: current.id),
        payload: Data("wire".utf8),
        recovery: .snip(item)
      )
      _ = try await store.perform(.setDone(ids: [current.id], done: true), sortedBy: .manual)
      _ = try await store.perform(
        .moveChronologically(ids: [current.id], to: storedList.id),
        sortedBy: .manual
      )
    }

    let reopened = try SwiftDataSnipLibrary(storeURL: location.store)
    let pending = try await reopened.recoverySnapshot(in: scope)
    XCTAssertEqual(pending.pendingSnips, [item])
    _ = try await reopened.resolveRecovery(item.id, in: scope, choice: .useRecovered)

    let resolved = await reopened.snapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(resolved.snips.first { $0.id == current.id })
    XCTAssertEqual(snip.content, "Local text")
    XCTAssertTrue(snip.isDone)
    XCTAssertNotEqual(snip.listID, SnipList.inboxID)
    XCTAssertEqual(snip.source?.applicationName, "Server app")
    let recoveryAfterResolution = try await reopened.recoverySnapshot(in: scope)
    let cloudAfterResolution = try await reopened.cloudFullStorageSnapshot(
      namespaceKey: CloudSyncNamespaceKey(rawValue: scope.rawValue)
    )
    XCTAssertTrue(recoveryAfterResolution.pendingSnips.isEmpty)
    XCTAssertTrue(cloudAfterResolution.conflicts.isEmpty)
  }

  func testKeepBothPromotesOnceAndKeepsRecoveredBadgeLinkAndFieldProvenance() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let scope = SnipRecoveryScope("private|account-a|generation-a")
    let current = Snip(content: "Current", origin: .quickEntry)
    let recovered = Snip(
      id: UUID(),
      requestID: UUID(),
      createdAt: current.createdAt,
      content: "Recovered",
      origin: .quickEntry,
      listID: UUID()
    )
    let item = RecoveredSnip(
      id: recovered.id,
      currentSnipID: current.id,
      recovered: recovered,
      conflictingFields: [.text, .done]
    )
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    _ = try await store.perform(.restore(snips: [current]), sortedBy: .manual)
    try await store.testStoreCloudConflict(
      namespaceKey: CloudSyncNamespaceKey(rawValue: scope.rawValue),
      key: "keep-both",
      reference: CloudEntityReference(kind: .snip, domainID: current.id),
      payload: Data("wire".utf8),
      recovery: .snip(item)
    )

    _ = try await store.resolveRecovery(item.id, in: scope, choice: .keepBoth)
    let library = await store.snapshot(sortedBy: .manual)
    XCTAssertEqual(Set(library.snips.map(\.id)), [current.id, recovered.id])
    let after = try await store.recoverySnapshot(in: scope)
    XCTAssertTrue(after.pendingSnips.isEmpty)
    let promotedReview = try XCTUnwrap(after.promotedSnips.first)
    XCTAssertEqual(after.promotedSnips.count, 1)
    XCTAssertEqual(promotedReview.state, .promoted)
    XCTAssertEqual(promotedReview.recovered, library.snips.first { $0.id == recovered.id })
    XCTAssertEqual(promotedReview.recovered.listID, SnipList.inboxID)
    XCTAssertEqual(after.promotedSnips.first?.currentSnipID, current.id)
    XCTAssertEqual(after.promotedSnips.first?.conflictingFields, [.text, .done])

    await assertRecoveryError(.recoveryChanged) {
      _ = try await store.resolveRecovery(item.id, in: scope, choice: .keepBoth)
    }
    let afterDuplicate = await store.snapshot(sortedBy: .manual)
    XCTAssertEqual(afterDuplicate.snips.count, 2)
  }

  func testResolutionReusesOrRemovesTheProvisionalRecoveredSnipFromReenable() async throws {
    let scope = SnipRecoveryScope("private|account-a|generation-a")
    let current = Snip(content: "Server", origin: .quickEntry)
    let recovered = Snip(
      id: UUID(),
      requestID: UUID(),
      createdAt: current.createdAt,
      content: "Local",
      origin: .quickEntry
    )
    let item = RecoveredSnip(
      id: recovered.id,
      currentSnipID: current.id,
      recovered: recovered,
      conflictingFields: [.text]
    )

    for choice in [SnipRecoveryChoice.keepBoth, .useRecovered, .keepCurrent] {
      let location = temporaryStore()
      defer { try? FileManager.default.removeItem(at: location.root) }
      let store = try SwiftDataSnipLibrary(storeURL: location.store)
      _ = try await store.perform(
        .restore(snips: [current, recovered]),
        sortedBy: .manual
      )
      try await store.testStoreCloudConflict(
        namespaceKey: CloudSyncNamespaceKey(rawValue: scope.rawValue),
        key: "reenable-\(String(describing: choice))",
        reference: CloudEntityReference(kind: .snip, domainID: current.id),
        payload: Data("wire".utf8),
        recovery: .snip(item)
      )

      _ = try await store.resolveRecovery(item.id, in: scope, choice: choice)
      let library = await store.snapshot(sortedBy: .manual)
      let review = try await store.recoverySnapshot(in: scope)
      let conflicts = try await store.cloudFullStorageSnapshot(namespaceKey: CloudSyncNamespaceKey(rawValue: scope.rawValue))
      XCTAssertTrue(review.pendingSnips.isEmpty)
      XCTAssertTrue(conflicts.conflicts.isEmpty)

      if choice == .keepBoth {
        XCTAssertEqual(Set(library.snips.map(\.id)), [current.id, recovered.id])
        XCTAssertEqual(review.promotedSnips, [item.promoted()])
      } else {
        XCTAssertEqual(library.snips.map(\.id), [current.id])
        XCTAssertTrue(review.promotedSnips.isEmpty)
        let resolvedCurrent = try XCTUnwrap(library.snips.first)
        XCTAssertEqual(
          resolvedCurrent.content,
          choice == .useRecovered ? recovered.content : current.content
        )
      }
    }
  }

  func testListEditChangesOnlyConflictingFieldsAndNeverChangesMembership() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let scope = SnipRecoveryScope("private|account-a|generation-a")
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let created = try await store.perform(
      .createList(name: "Server name", systemImage: "server.rack"),
      sortedBy: .manual
    )
    guard case .listCreated(let current) = created.outcome else {
      return XCTFail("Expected a List")
    }
    let member = Snip(content: "Member", origin: .quickEntry, listID: current.id)
    _ = try await store.perform(.restore(snips: [member]), sortedBy: .manual)
    var recoveredList = current
    recoveredList.name = "Local name"
    recoveredList.systemImage = "folder"
    let item = RecoveredListEdit(
      id: UUID(),
      currentListID: current.id,
      recovered: recoveredList,
      conflictingFields: [.name]
    )
    try await store.testStoreCloudConflict(
      namespaceKey: CloudSyncNamespaceKey(rawValue: scope.rawValue),
      key: "list-name",
      reference: CloudEntityReference(kind: .list, domainID: current.id),
      payload: Data("wire".utf8),
      recovery: .list(item)
    )
    var custom = recoveredList
    custom.name = "Chosen name"
    custom.systemImage = "star"

    _ = try await store.resolveRecovery(item.id, in: scope, choice: .editList(custom))
    let snapshot = await store.snapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.lists.first { $0.id == current.id }?.name, "Chosen name")
    XCTAssertEqual(snapshot.lists.first { $0.id == current.id }?.systemImage, "server.rack")
    XCTAssertEqual(snapshot.snips.first { $0.id == member.id }?.listID, current.id)
    let recoveryAfterEdit = try await store.recoverySnapshot(in: scope)
    XCTAssertTrue(recoveryAfterEdit.pendingLists.isEmpty)
  }

  func testListColorRecoveryChangesOnlyColor() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let scope = SnipRecoveryScope("private|account-a|generation-a")
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let created = try await store.perform(
      .createList(name: "Server name", systemImage: "server.rack"),
      sortedBy: .manual
    )
    guard case .listCreated(let current) = created.outcome else {
      return XCTFail("Expected a List")
    }
    let member = Snip(content: "Member", origin: .quickEntry, listID: current.id)
    _ = try await store.perform(.restore(snips: [member]), sortedBy: .manual)
    var recoveredList = current
    recoveredList.name = "Local name"
    recoveredList.systemImage = "folder"
    recoveredList.color = SnipListColorPreset.blue.color
    let item = RecoveredListEdit(
      id: UUID(),
      currentListID: current.id,
      recovered: recoveredList,
      conflictingFields: [.color]
    )
    try await store.testStoreCloudConflict(
      namespaceKey: CloudSyncNamespaceKey(rawValue: scope.rawValue),
      key: "list-name",
      reference: CloudEntityReference(kind: .list, domainID: current.id),
      payload: Data("wire".utf8),
      recovery: .list(item)
    )
    var custom = recoveredList
    custom.name = "Chosen name"
    custom.systemImage = "star"
    custom.color = SnipListColorPreset.violet.color

    _ = try await store.resolveRecovery(item.id, in: scope, choice: .editList(custom))
    let snapshot = await store.snapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.lists.first { $0.id == current.id }?.name, "Server name")
    XCTAssertEqual(snapshot.lists.first { $0.id == current.id }?.systemImage, "server.rack")
    XCTAssertEqual(snapshot.lists.first { $0.id == current.id }?.color, SnipListColorPreset.violet.color)
    XCTAssertEqual(snapshot.snips.first { $0.id == member.id }?.listID, current.id)
    let recoveryAfterEdit = try await store.recoverySnapshot(in: scope)
    XCTAssertTrue(recoveryAfterEdit.pendingLists.isEmpty)
  }

  func testResolutionRollsBackFieldChangeAndExactConflictDeletionOnWriteFailure() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let scope = SnipRecoveryScope("private|account-a|generation-a")
    let current = Snip(content: "Current", origin: .quickEntry)
    let recovered = Snip(id: UUID(), content: "Recovered", origin: .quickEntry)
    let item = RecoveredSnip(
      id: recovered.id,
      currentSnipID: current.id,
      recovered: recovered,
      conflictingFields: [.text]
    )
    do {
      let store = try SwiftDataSnipLibrary(storeURL: location.store)
      _ = try await store.perform(.restore(snips: [current]), sortedBy: .manual)
      try await store.testStoreCloudConflict(
        namespaceKey: CloudSyncNamespaceKey(rawValue: scope.rawValue),
        key: "atomic",
        reference: CloudEntityReference(kind: .snip, domainID: current.id),
        payload: Data("wire".utf8),
        recovery: .snip(item)
      )
    }

    let failing = try SwiftDataSnipLibrary(
      storeURL: location.store,
      afterMutationBeforeSave: { throw Crash.expected }
    )
    do {
      _ = try await failing.resolveRecovery(item.id, in: scope, choice: .useRecovered)
      XCTFail("Expected injected write failure")
    } catch {
      XCTAssertTrue(error is Crash)
    }

    let reopened = try SwiftDataSnipLibrary(storeURL: location.store)
    let localAfterFailure = await reopened.snapshot(sortedBy: .manual)
    let recoveryAfterFailure = try await reopened.recoverySnapshot(in: scope)
    let cloudAfterFailure = try await reopened.cloudFullStorageSnapshot(namespaceKey: CloudSyncNamespaceKey(rawValue: scope.rawValue))
    XCTAssertEqual(localAfterFailure.snips.first?.content, "Current")
    XCTAssertEqual(recoveryAfterFailure.pendingSnips, [item])
    XCTAssertEqual(cloudAfterFailure.conflicts.map(\.key), ["atomic"])
  }

  func testRecoverySnapshotsStayNamespaceScopedAndMissingCurrentDoesNotConsumeRecovery() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let firstScope = SnipRecoveryScope("private|account-a|generation-a")
    let secondScope = SnipRecoveryScope("private|account-b|generation-a")
    let current = Snip(content: "Current", origin: .quickEntry)
    let firstRecovered = Snip(id: UUID(), content: "First", origin: .quickEntry)
    let first = RecoveredSnip(
      id: firstRecovered.id,
      currentSnipID: current.id,
      recovered: firstRecovered,
      conflictingFields: [.text]
    )
    let secondRecovered = Snip(id: UUID(), content: "Second", origin: .quickEntry)
    let second = RecoveredSnip(
      id: secondRecovered.id,
      currentSnipID: current.id,
      recovered: secondRecovered,
      conflictingFields: [.text]
    )
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    _ = try await store.perform(.restore(snips: [current]), sortedBy: .manual)
    try await store.testStoreCloudConflict(
      namespaceKey: CloudSyncNamespaceKey(rawValue: firstScope.rawValue),
      key: "first",
      reference: CloudEntityReference(kind: .snip, domainID: current.id),
      payload: Data("first".utf8),
      recovery: .snip(first)
    )
    try await store.testStoreCloudConflict(
      namespaceKey: CloudSyncNamespaceKey(rawValue: secondScope.rawValue),
      key: "second",
      reference: CloudEntityReference(kind: .snip, domainID: current.id),
      payload: Data("second".utf8),
      recovery: .snip(second)
    )
    let firstSnapshot = try await store.recoverySnapshot(in: firstScope)
    let secondSnapshot = try await store.recoverySnapshot(in: secondScope)
    XCTAssertEqual(firstSnapshot.pendingSnips, [first])
    XCTAssertEqual(secondSnapshot.pendingSnips, [second])

    _ = try await store.perform(.delete(ids: [current.id]), sortedBy: .manual)
    await assertRecoveryError(.snipNotFound) {
      _ = try await store.resolveRecovery(first.id, in: firstScope, choice: .useRecovered)
    }
    let firstAfterMissing = try await store.recoverySnapshot(in: firstScope)
    let cloudAfterMissing = try await store.cloudFullStorageSnapshot(
      namespaceKey: CloudSyncNamespaceKey(rawValue: firstScope.rawValue)
    )
    XCTAssertEqual(firstAfterMissing.pendingSnips, [first])
    XCTAssertEqual(cloudAfterMissing.conflicts.map(\.key), ["first"])
  }

  private func assertRecoveryError(
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

  private func temporaryStore() -> (root: URL, store: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnipRecoveryPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    return (root, root.appendingPathComponent("snips.store"))
  }
}
