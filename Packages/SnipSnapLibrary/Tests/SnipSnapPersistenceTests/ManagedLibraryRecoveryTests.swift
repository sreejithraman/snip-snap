import Foundation
import SnipSnapCore
import XCTest
@testable import SnipSnapPersistence

final class ManagedLibraryRecoveryTests: XCTestCase {
  func testAppAssemblyShowsStoredRecoveredSnipsAndListsThroughSession() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let modeRoot = root.appendingPathComponent("SyncMode")
    let persistence = try SwiftDataSyncModePersistence(rootURL: modeRoot)
    let namespace = namespace()
    try await persistence.activateEmptyCollection(namespace: namespace)
    let scope = SnipRecoveryScope(namespace.namespaceKey.rawValue)
    let fixture = try await seedRecoveries(in: persistence, scope: scope)
    let fallback = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("fallback.store"))
    let assembly = SnipLibraryAssembly(library: fallback, syncModeRootURL: modeRoot)
    let session = SavedSnipsSession(library: assembly.library, recoveryScope: assembly.recoveryScope)

    let recovery = try await session.checkedRecovery()
    XCTAssertEqual(recovery.pendingSnips, [fixture.snipRecovery])
    XCTAssertEqual(recovery.pendingLists, [fixture.listRecovery])
    let state = await session.state(sortedBy: .chronological)
    XCTAssertEqual(state.library.snips.map(\.content), ["Current"])
    XCTAssertEqual(state.recovery, recovery)
  }

  func testManagedSessionResolvesGuardedSnipAndListInLocalAndSyncStores() async throws {
    for useCloud in [false, true] {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let persistence = try SwiftDataSyncModePersistence(rootURL: root)
      let namespace = namespace()
      if useCloud { try await persistence.activateEmptyCollection(namespace: namespace) }
      let scope = SnipRecoveryScope(namespace.namespaceKey.rawValue)
      let fixture = try await seedRecoveries(in: persistence, scope: scope)
      let library = try await persistence.activeLibrary()
      let session = SavedSnipsSession(library: library, recoveryScope: scope)
      let before = try await persistence.snapshot()

      let snipState = try await session.resolveRecovery(
        fixture.snipRecovery.id, choice: .useRecovered,
        expectation: .init(record: .snip(fixture.snipRecovery), currentSnip: fixture.current),
        sortedBy: .chronological)
      let resolvedSnip = try XCTUnwrap(snipState?.library.snips.first)
      XCTAssertEqual(resolvedSnip.content, "Recovered")
      XCTAssertEqual(resolvedSnip.isDone, true)
      XCTAssertEqual(resolvedSnip.listID, fixture.list.id)
      XCTAssertEqual(snipState?.recovery.pendingSnips, [])
      XCTAssertEqual(snipState?.recovery.pendingLists, [fixture.listRecovery])

      let listState = try await session.resolveRecovery(
        fixture.listRecovery.id, choice: .useRecovered,
        expectation: .init(record: .list(fixture.listRecovery), currentList: fixture.list),
        sortedBy: .chronological)
      XCTAssertEqual(listState?.library.lists.first { $0.id == fixture.list.id }?.name, "Recovered list")
      XCTAssertEqual(listState?.library.snips.first?.listID, fixture.list.id)
      XCTAssertEqual(listState?.recovery, .empty)
      let after = try await persistence.snapshot()
      XCTAssertEqual(after.activeStore.revision, before.activeStore.revision + 2)
      XCTAssertFalse(after.hasActiveMutationReservation)

      let reopened = try SwiftDataSyncModePersistence(rootURL: root)
      let persisted = try await reopened.activeLibrary()
      let persistedRecovery = try await persisted.recoverySnapshot(in: scope)
      let persistedLibrary = try await persisted.checkedSnapshot(sortedBy: .chronological)
      XCTAssertEqual(persistedRecovery, .empty)
      XCTAssertEqual(persistedLibrary.snips.first?.content, "Recovered")
      XCTAssertEqual(persistedLibrary.lists.first { $0.id == fixture.list.id }?.name, "Recovered list")
    }
  }

  func testRecoveryReadFailureIsReportedAndLaterRecoveryReadClearsOnlyReadAttention() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fault = RecoveryReadFault()
    let persistence = try SwiftDataSyncModePersistence(rootURL: root, readHook: { try await fault.check() })
    let scope = SnipRecoveryScope("managed-read-health")
    let fixture = try await seedRecoveries(in: persistence, scope: scope)
    let library = try await persistence.activeLibrary()
    let session = SavedSnipsSession(library: library, recoveryScope: scope)
    await fault.setFailing(true)

    do {
      _ = try await session.checkedRecovery()
      XCTFail("A recovery read failure must reach the caller")
    } catch RecoveryReadFault.Failure.injected {}
    let failed = try await persistence.snapshot()
    XCTAssertEqual(failed.attentionReason, .storeReadFailed)

    await fault.setFailing(false)
    let recovered = try await session.checkedRecovery()
    XCTAssertEqual(recovered.pendingSnips, [fixture.snipRecovery])
    XCTAssertEqual(recovered.pendingLists, [fixture.listRecovery])
    let healthy = try await persistence.snapshot()
    XCTAssertNil(healthy.attentionReason)

    try await persistence.recordAttention(.storageFailure)
    await fault.setFailing(true)
    do {
      _ = try await session.checkedRecovery()
      XCTFail("An existing attention reason must not hide a read failure")
    } catch RecoveryReadFault.Failure.injected {}
    await fault.setFailing(false)
    _ = try await session.checkedRecovery()
    let otherAttention = try await persistence.snapshot()
    XCTAssertEqual(otherAttention.attentionReason, .storageFailure)
  }

  func testGuardedResolutionRejectsEditDuringAdmissionWithoutConsumingRecovery() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let edit = RecoveryAdmissionEdit()
    let persistence = try SwiftDataSyncModePersistence(rootURL: root, writeHook: { point in
      if point == .afterRevisionReserved { try await edit.apply() }
    })
    let scope = SnipRecoveryScope("managed-stale-guard")
    let fixture = try await seedRecoveries(in: persistence, scope: scope)
    let library = try await persistence.activeLibrary()
    let session = SavedSnipsSession(library: library, recoveryScope: scope)
    await edit.prepare(store: fixture.store, snipID: fixture.current.id)

    do {
      _ = try await session.resolveRecovery(
        fixture.snipRecovery.id, choice: .useRecovered,
        expectation: .init(record: .snip(fixture.snipRecovery), currentSnip: fixture.current),
        sortedBy: .chronological)
      XCTFail("An edit after admission must invalidate the reviewed current snip")
    } catch SnipLibraryError.recoveryChanged {}
    let pending = try await session.checkedRecovery()
    XCTAssertEqual(pending.pendingSnips, [fixture.snipRecovery])
    let unchanged = try await session.checkedSnapshot(sortedBy: .chronological)
    let latest = try XCTUnwrap(unchanged.snips.first)
    XCTAssertEqual(latest.content, "Current")
    XCTAssertEqual(latest.isDone, false)
    let rejected = try await persistence.snapshot()
    XCTAssertFalse(rejected.hasActiveMutationReservation)

    var edited = fixture.snipRecovery.recovered
    edited.content = "Chosen edit"
    let resolved = try await session.resolveRecovery(
      fixture.snipRecovery.id, choice: .editSnip(edited),
      expectation: .init(record: .snip(fixture.snipRecovery), currentSnip: latest),
      sortedBy: .chronological)
    XCTAssertEqual(resolved?.library.snips.first?.content, "Chosen edit")
    XCTAssertEqual(resolved?.library.snips.first?.isDone, false)
    XCTAssertEqual(resolved?.recovery.pendingSnips, [])
  }

  func testRecoveryWriteAdmissionBlocksFreezeAndFrozenSourceRejectsResolution() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = RecoveryPauseGate()
    let reserved = expectation(description: "Recovery write reserved")
    let persistence = try SwiftDataSyncModePersistence(rootURL: root, writeHook: { point in
      if point == .afterRevisionReserved {
        reserved.fulfill()
        await gate.pause()
      }
    })
    let scope = SnipRecoveryScope("managed-transition")
    let fixture = try await seedRecoveries(in: persistence, scope: scope)
    let library = try await persistence.activeLibrary()
    _ = try await persistence.beginTransition(to: .iCloudSync, namespace: namespace())
    try await persistence.recordPreparationComplete()
    let resolution = Task {
      try await library.resolveRecovery(fixture.snipRecovery.id, in: scope, choice: .keepCurrent)
    }
    await fulfillment(of: [reserved], timeout: 5)
    let admitted = try await persistence.snapshot()
    XCTAssertTrue(admitted.hasActiveMutationReservation)
    do {
      _ = try await persistence.freezeSource()
      XCTFail("Freeze cannot pass an admitted recovery write")
    } catch SyncModePersistenceError.transitionInProgress {}
    // Opening another managed adapter cannot release a live reservation.
    let other = try await persistence.activeLibrary()
    do {
      _ = try await other.resolveRecovery(fixture.listRecovery.id, in: scope, choice: .keepCurrent)
      XCTFail("Another adapter cannot write while recovery holds admission")
    } catch SnipLibraryError.modeTransitionInProgress {}
    await gate.resume()
    _ = try await resolution.value

    _ = try await persistence.freezeSource()
    do {
      _ = try await library.resolveRecovery(
        fixture.listRecovery.id, in: scope, choice: .useRecovered,
        expectation: .init(record: .list(fixture.listRecovery), currentList: fixture.list))
      XCTFail("A frozen source must reject recovery resolution")
    } catch SnipLibraryError.modeTransitionInProgress {}
    let pending = try await library.recoverySnapshot(in: scope)
    XCTAssertEqual(pending.pendingSnips, [])
    XCTAssertEqual(pending.pendingLists, [fixture.listRecovery])
    try await persistence.unfreezeBeforePointerSwap()
  }

  func testSessionReplacementFollowsActiveStoreAndRecoveryScope() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    let library = try await persistence.activeLibrary()
    let session = SavedSnipsSession(library: library)
    let local = await session.state(sortedBy: .chronological)
    XCTAssertEqual(local.recovery, .empty)

    let firstNamespace = namespace()
    try await persistence.activateEmptyCollection(namespace: firstNamespace)
    let firstScope = SnipRecoveryScope(firstNamespace.namespaceKey.rawValue)
    let first = try await seedRecoveries(in: persistence, scope: firstScope)
    let firstState = await session.replaceLibrary(
      library, recoveryScope: firstScope, sortedBy: .chronological)
    XCTAssertEqual(firstState.recovery.pendingSnips, [first.snipRecovery])

    let secondNamespace = namespace()
    try await persistence.activateEmptyCollection(namespace: secondNamespace)
    let secondScope = SnipRecoveryScope(secondNamespace.namespaceKey.rawValue)
    let second = try await seedRecoveries(in: persistence, scope: secondScope)
    let secondLibrary = try await persistence.activeLibrary()
    let secondState = await session.replaceLibrary(
      secondLibrary, recoveryScope: secondScope, sortedBy: .chronological)
    XCTAssertEqual(secondState.recovery.pendingSnips, [second.snipRecovery])
    XCTAssertEqual(secondState.recovery.pendingLists, [second.listRecovery])
    let oldScope = try await library.recoverySnapshot(in: firstScope)
    XCTAssertEqual(oldScope, .empty)
    do {
      _ = try await library.resolveRecovery(first.snipRecovery.id, in: firstScope, choice: .useRecovered)
      XCTFail("A retained adapter cannot resolve a recovery in a retired store")
    } catch SnipLibraryError.recoveryNotFound {}
    let stillPending = try await session.checkedRecovery()
    XCTAssertEqual(stillPending.pendingSnips, [second.snipRecovery])

    try await persistence.activateEmptyCollection(namespace: nil)
    let backToLocal = await session.replaceLibrary(
      library, recoveryScope: nil, sortedBy: .chronological)
    XCTAssertEqual(backToLocal.recovery, .empty)
    XCTAssertEqual(backToLocal.library.snips, [])
  }

  func testOlderRecoveryReadCannotOverwriteNewerSnapshotReadHealth() async throws {
    for failOlder in [false, true] {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let started = expectation(description: "Older recovery read started")
      let overlap = RecoveryReadOverlap(failOlder: failOlder, started: started)
      let persistence = try SwiftDataSyncModePersistence(rootURL: root, readHook: { try await overlap.check() })
      let scope = SnipRecoveryScope("managed-overlapping-reads")
      let fixture = try await seedRecoveries(in: persistence, scope: scope)
      let older = persistence.activeLibrary(fallback: fixture.store)
      let olderRead = Task { try await older.recoverySnapshot(in: scope) }
      await fulfillment(of: [started], timeout: 5)
      guard await overlap.hasStarted else {
        await overlap.resume()
        _ = await olderRead.result
        return XCTFail("The managed recovery read must reach the store")
      }

      let newer = persistence.activeLibrary(fallback: fixture.store)
      do {
        let snapshot = try await newer.checkedSnapshot(sortedBy: .chronological)
        XCTAssertTrue(failOlder, "The newer read should fail in this scenario")
        XCTAssertEqual(snapshot.snips.first?.content, "Current")
      } catch {
        XCTAssertFalse(failOlder, "The newer read should succeed in this scenario")
        XCTAssertTrue(error is RecoveryReadOverlap.Failure)
      }
      await overlap.resume()
      do {
        let recovered = try await olderRead.value
        XCTAssertFalse(failOlder, "The older read should fail in this scenario")
        XCTAssertEqual(recovered.pendingSnips, [fixture.snipRecovery])
      } catch {
        XCTAssertTrue(failOlder, "The older read should succeed in this scenario")
        XCTAssertTrue(error is RecoveryReadOverlap.Failure)
      }
      let health = try await persistence.snapshot()
      XCTAssertEqual(health.attentionReason, failOlder ? nil : .storeReadFailed)
      let recovered = try await newer.recoverySnapshot(in: scope)
      XCTAssertEqual(recovered.pendingLists, [fixture.listRecovery])
      let healthy = try await persistence.snapshot()
      XCTAssertNil(healthy.attentionReason)
    }
  }

  private struct Fixture {
    let store: SwiftDataSnipLibrary
    let current: Snip
    let list: SnipList
    let snipRecovery: RecoveredSnip
    let listRecovery: RecoveredListEdit
  }

  private func seedRecoveries(
    in persistence: SwiftDataSyncModePersistence,
    scope: SnipRecoveryScope
  ) async throws -> Fixture {
    let activeID = try await persistence.snapshot().activeStore.id
    let store = try await persistence.libraryForTransition(storeID: activeID)
    let created = try await store.perform(
      .createList(name: "Current list", systemImage: "folder"), sortedBy: .chronological)
    let list = try XCTUnwrap(created.snapshot.lists.first { $0.name == "Current list" })
    let current = Snip(content: "Current", origin: .quickEntry, listID: list.id, isDone: true)
    _ = try await store.perform(.restore(snips: [current]), sortedBy: .chronological)
    let alternate = Snip(content: "Recovered", origin: .quickEntry)
    let snipRecovery = RecoveredSnip(
      id: alternate.id, currentSnipID: current.id, recovered: alternate, conflictingFields: [.text])
    var recoveredList = list
    recoveredList.name = "Recovered list"
    let listRecovery = RecoveredListEdit(
      id: UUID(), currentListID: list.id, recovered: recoveredList, conflictingFields: [.name])
    try await store.testStoreCloudConflict(
      namespaceKey: .init(rawValue: scope.rawValue), key: "snip-recovery",
      reference: .init(kind: .snip, domainID: current.id), payload: Data("snip wire".utf8),
      recovery: .snip(snipRecovery))
    try await store.testStoreCloudConflict(
      namespaceKey: .init(rawValue: scope.rawValue), key: "list-recovery",
      reference: .init(kind: .list, domainID: list.id), payload: Data("list wire".utf8),
      recovery: .list(listRecovery))
    return Fixture(
      store: store, current: current, list: list, snipRecovery: snipRecovery, listRecovery: listRecovery)
  }

  private func namespace() -> ICloudSyncNamespaceBinding {
    ICloudSyncNamespaceBinding(
      scope: "private", accountLineage: "managed-recovery-tests", generation: UUID(),
      zones: [ICloudSyncZoneBinding(name: "SnipSnap", ownerName: "test-owner")])
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ManagedLibraryRecoveryTests-\(UUID().uuidString)")
  }
}

private actor RecoveryReadFault {
  enum Failure: Error { case injected }
  private var failing = false

  func setFailing(_ value: Bool) { failing = value }
  func check() throws {
    if failing { throw Failure.injected }
  }
}

private actor RecoveryAdmissionEdit {
  private var store: SwiftDataSnipLibrary?
  private var snipID: UUID?

  func prepare(store: SwiftDataSnipLibrary, snipID: UUID) {
    self.store = store
    self.snipID = snipID
  }

  func apply() async throws {
    guard let store, let snipID else { return }
    self.store = nil
    self.snipID = nil
    _ = try await store.perform(.setDone(ids: [snipID], done: false), sortedBy: .chronological)
  }
}

private actor RecoveryPauseGate {
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?

  func pause() async {
    guard !released else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func resume() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

private actor RecoveryReadOverlap {
  enum Failure: Error { case injected }
  private let failOlder: Bool
  private let started: XCTestExpectation
  private let gate = RecoveryPauseGate()
  private var attempts = 0
  var hasStarted: Bool { attempts > 0 }

  init(failOlder: Bool, started: XCTestExpectation) {
    self.failOlder = failOlder
    self.started = started
  }

  func check() async throws {
    attempts += 1
    let attempt = attempts
    if attempt == 1 {
      started.fulfill()
      await gate.pause()
    }
    if (attempt == 1 && failOlder) || (attempt == 2 && !failOlder) {
      throw Failure.injected
    }
  }

  func resume() async { await gate.resume() }
}
