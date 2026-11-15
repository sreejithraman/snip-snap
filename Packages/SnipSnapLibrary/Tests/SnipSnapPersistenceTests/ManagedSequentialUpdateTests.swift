import Foundation
import SnipSnapCore
import Synchronization
import XCTest
@testable import SnipSnapPersistence

final class ManagedSequentialUpdateTests: XCTestCase {
  func testNextIndependentUpdateWaitsForSyncAfterThePreviousWriteSucceeded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let queued = expectation(description: "The second update waits behind normal sync")
    let diagnostics = AppDiagnosticRecorder { event in
      if event == .writeAdmission(.started, reason: .syncBusy) { queued.fulfill() }
    }
    let persistence = try SwiftDataSyncModePersistence(rootURL: root, diagnostics: diagnostics)
    let namespace = ICloudSyncNamespaceBinding(scope: "private", accountLineage: "test-account",
      generation: UUID(), zones: [.init(name: "test-zone", ownerName: "test-owner")])
    try await persistence.activateEmptyCollection(namespace: namespace)
    let library = try await persistence.activeLibrary()
    var snips: [Snip] = []
    for content in ["First", "Second"] {
      let update = try await library.perform(.add(content: content, origin: .agent, source: nil,
        listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: Date()), sortedBy: .manual)
      snips.append(try XCTUnwrap(update.snapshot.snips.first { $0.content == content }))
    }
    _ = try await library.perform(.setDone(ids: Set(snips.map(\.id)), done: true), sortedBy: .manual)
    let before = try await library.checkedSnapshot(sortedBy: .manual)
    let first = try XCTUnwrap(before.snips.first { $0.id == snips[0].id })
    let second = try XCTUnwrap(before.snips.first { $0.id == snips[1].id })
    let firstResult = try await library.perform(.update(id: first.id, content: "First updated",
      attachmentURLs: nil, expectedUpdatedAt: first.updatedAt, now: Date()), sortedBy: .manual)
    XCTAssertEqual(firstResult.snapshot.snips.first { $0.id == first.id }?.content, "First updated")

    let storeID = try await persistence.snapshot().activeStore.id
    let lease = try await persistence.activeCloudMutationLease(storeID: storeID)
    let held = expectation(description: "Normal sync owns write admission")
    let release = SequentialUpdateLatch()
    let syncing = Task {
      try await lease.run {
        held.fulfill()
        await release.wait()
      }
    }
    await fulfillment(of: [held], timeout: 2)
    let updating = Task {
      try await library.perform(.update(id: second.id, content: "Second updated",
        attachmentURLs: nil, expectedUpdatedAt: second.updatedAt, now: Date()), sortedBy: .manual)
    }
    await fulfillment(of: [queued], timeout: 2)
    await release.open()
    try await syncing.value
    let secondResult = try await updating.value
    XCTAssertEqual(secondResult.snapshot.snips.first { $0.id == second.id }?.content, "Second updated")
    let state = try await persistence.snapshot()
    XCTAssertFalse(state.hasActiveMutationReservation)

    let reopened = try SwiftDataSyncModePersistence(rootURL: root)
    let persisted = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(Set(persisted.snips.map(\.content)), ["First updated", "Second updated"])
    XCTAssertTrue(persisted.snips.allSatisfy(\.isDone))
  }

  func testQueuedUpdateSurvivesOneFailedSyncRelease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let queued = expectation(description: "The update waits behind normal sync")
    let diagnostics = AppDiagnosticRecorder { event in
      if event == .writeAdmission(.started, reason: .syncBusy) { queued.fulfill() }
    }
    let faults = ManifestWriteFaults()
    let persistence = try await makeICloudPersistence(root: root, faults: faults, diagnostics: diagnostics)
    let library = try await persistence.activeLibrary()
    let added = try await library.perform(addCommand("Before sync"), sortedBy: .manual)
    let snip = try XCTUnwrap(added.snapshot.snips.first)

    let lease = try await persistence.activeCloudMutationLease(
      storeID: try await persistence.snapshot().activeStore.id)
    let held = expectation(description: "Normal sync owns write admission")
    let release = SequentialUpdateLatch()
    let syncing = Task {
      try await lease.run {
        held.fulfill()
        await release.wait()
      }
    }
    await fulfillment(of: [held], timeout: 2)
    let updating = Task {
      try await library.perform(.update(id: snip.id, content: "Updated during sync",
        attachmentURLs: nil, expectedUpdatedAt: snip.updatedAt, now: Date()), sortedBy: .manual)
    }
    await fulfillment(of: [queued], timeout: 2)
    faults.failNextWrites(1)
    await release.open()

    do { try await syncing.value; XCTFail("Sync must see its failed release") }
    catch SyncModePersistenceError.storageFailure {}
    do {
      let updated = try await updating.value
      XCTAssertEqual(updated.snapshot.snips.first { $0.id == snip.id }?.content, "Updated during sync")
    } catch {
      XCTFail("The queued update must survive one failed sync release: \(error)")
    }
    let state = try await persistence.snapshot()
    XCTAssertFalse(state.hasActiveMutationReservation)

    let reopened = try SwiftDataSyncModePersistence(rootURL: root)
    let persisted = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(persisted.snips.map(\.content), ["Updated during sync"])
  }

  func testEditAndSyncResumeAfterAReservationClearFailsTwice() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let faults = ManifestWriteFaults()
    let persistence = try await makeICloudPersistence(root: root, faults: faults)
    let library = try await persistence.activeLibrary()
    faults.failNextReservationClear(writes: 2)
    do {
      _ = try await library.perform(addCommand("Saved before the failed clear"), sortedBy: .manual)
      XCTFail("The edit must report the failed reservation clear")
    } catch SyncModePersistenceError.storageFailure {}
    let leftover = try await persistence.snapshot()
    XCTAssertTrue(leftover.hasActiveMutationReservation)

    let lease = try await persistence.activeCloudMutationLease(storeID: leftover.activeStore.id)
    do { try await lease.run {} }
    catch { XCTFail("Sync must run once the disk recovers: \(error)") }
    do { _ = try await library.perform(addCommand("After the disk recovers"), sortedBy: .manual) }
    catch { XCTFail("The next edit must save once the disk recovers: \(error)") }

    let state = try await persistence.snapshot()
    XCTAssertFalse(state.hasActiveMutationReservation)
    let saved = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(Set(saved.snips.map(\.content)),
      ["Saved before the failed clear", "After the disk recovers"])
  }

  func testReopenClearsAReservationLeftByAFailedRelease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let faults = ManifestWriteFaults()
    let persistence = try await makeICloudPersistence(root: root, faults: faults)
    let library = try await persistence.activeLibrary()
    faults.failNextReservationClear(writes: 2)
    do {
      _ = try await library.perform(addCommand("Saved before the failed clear"), sortedBy: .manual)
      XCTFail("The edit must report the failed reservation clear")
    } catch SyncModePersistenceError.storageFailure {}

    let reopened = try SwiftDataSyncModePersistence(rootURL: root)
    let state = try await reopened.snapshot()
    XCTAssertFalse(state.hasActiveMutationReservation)
    XCTAssertEqual(state.activeStore.revision, 1)
    let active = try await reopened.activeLibrary()
    _ = try await active.perform(addCommand("After reopen"), sortedBy: .manual)
    let saved = try await active.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(Set(saved.snips.map(\.content)), ["Saved before the failed clear", "After reopen"])
  }

  func testAccountIsolationRecoversAfterAReservationClearFailsTwice() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let faults = ManifestWriteFaults()
    let persistence = try await makeICloudPersistence(root: root, faults: faults)
    let library = try await persistence.activeLibrary()
    faults.failNextReservationClear(writes: 2)
    do {
      _ = try await library.perform(addCommand("Saved before the failed clear"), sortedBy: .manual)
      XCTFail("The edit must report the failed reservation clear")
    } catch SyncModePersistenceError.storageFailure {}

    do { _ = try await persistence.isolateActiveCloudStore(reason: .signedOut) }
    catch { return XCTFail("Account isolation must not stay refused by the failed clear: \(error)") }
    let state = try await persistence.snapshot()
    XCTAssertFalse(state.hasActiveMutationReservation)
    XCTAssertNotNil(state.accountIsolation)
  }

  func testOptOutStartsAfterAReservationClearFailsTwice() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let faults = ManifestWriteFaults()
    let persistence = try await makeICloudPersistence(root: root, faults: faults)
    let library = try await persistence.activeLibrary()
    faults.failNextReservationClear(writes: 2)
    do {
      _ = try await library.perform(addCommand("Saved before the failed clear"), sortedBy: .manual)
      XCTFail("The edit must report the failed reservation clear")
    } catch SyncModePersistenceError.storageFailure {}

    let transition: SyncModeTransition
    do { transition = try await persistence.beginTransition(to: .localOnly, namespace: nil) }
    catch { return XCTFail("Opt-out must not stay refused by the failed clear: \(error)") }
    XCTAssertEqual(transition.targetKind, .localOnly)
  }

  func testStoreReplacementRefusesAStoreHeldBySync() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try await makeICloudPersistence(root: root, faults: ManifestWriteFaults())
    let lease = try await persistence.activeCloudMutationLease(
      storeID: try await persistence.snapshot().activeStore.id)
    let held = expectation(description: "Normal sync owns write admission")
    let release = SequentialUpdateLatch()
    let syncing = Task {
      try await lease.run {
        held.fulfill()
        await release.wait()
      }
    }
    await fulfillment(of: [held], timeout: 2)

    do {
      _ = try await persistence.isolateActiveCloudStore(reason: .signedOut)
      XCTFail("Account isolation must wait for sync to release the store")
    } catch SyncModePersistenceError.transitionInProgress {}
    do {
      try await persistence.discardActiveCloudCollection()
      XCTFail("Discarding the synced collection must wait for sync to release the store")
    } catch SyncModePersistenceError.transitionInProgress {}
    await release.open()
    try await syncing.value
  }

  func testEditsResumeAfterAnEditFailsToSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fault = SaveFault()
    let persistence = try SwiftDataSyncModePersistence(rootURL: root, afterMutationBeforeSave: fault.check)
    let library = try await persistence.activeLibrary()
    let revision = try await persistence.snapshot().activeStore.revision
    fault.failNextSave()
    do {
      _ = try await library.perform(addCommand("Lost to the failed save"), sortedBy: .manual)
      XCTFail("The edit must report the failed save")
    } catch CocoaError.fileWriteOutOfSpace {}
    let afterFailure = try await persistence.snapshot()
    XCTAssertFalse(afterFailure.hasActiveMutationReservation)

    do { _ = try await library.perform(addCommand("Saved after the failed save"), sortedBy: .manual) }
    catch { XCTFail("The next edit must save: \(error)") }
    let state = try await persistence.snapshot()
    XCTAssertFalse(state.hasActiveMutationReservation)
    XCTAssertEqual(state.activeStore.revision, revision + 2)
    let saved = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(saved.snips.map(\.content), ["Saved after the failed save"])
  }

  func testEditsResumeAfterAnImportFailsToSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let backup = try SwiftDataSnipLibrary(
      storeURL: root.appendingPathComponent("Backup", isDirectory: true)
        .appendingPathComponent("snips.store"))
    _ = try await backup.perform(addCommand("Lost with the failed import"), sortedBy: .manual)
    let source = try await backup.transferSnapshot(revision: 0)
    let fault = SaveFault()
    let persistence = try SwiftDataSyncModePersistence(
      rootURL: root.appendingPathComponent("Library", isDirectory: true),
      afterMutationBeforeSave: fault.check)
    let library = try await persistence.activeLibrary()
    let preview = try await library.previewImport(source, transitionID: UUID())
    XCTAssertEqual(preview.addedSnipCount, 1)
    fault.failNextSave()
    do {
      _ = try await library.applyImport(preview)
      XCTFail("The import must report the failed save")
    } catch CocoaError.fileWriteOutOfSpace {}
    let afterFailure = try await persistence.snapshot()
    XCTAssertFalse(afterFailure.hasActiveMutationReservation)

    do { _ = try await library.perform(addCommand("Saved after the failed import"), sortedBy: .manual) }
    catch { XCTFail("The next edit must save: \(error)") }
    let saved = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(saved.snips.map(\.content), ["Saved after the failed import"])
  }
}

private func makeICloudPersistence(
  root: URL, faults: ManifestWriteFaults, diagnostics: AppDiagnosticRecorder = .live
) async throws -> SwiftDataSyncModePersistence {
  let persistence = try SwiftDataSyncModePersistence(rootURL: root, manifestWriter: faults.write,
    writeHook: faults.armAtReservationClear, diagnostics: diagnostics)
  let namespace = ICloudSyncNamespaceBinding(scope: "private", accountLineage: "test-account",
    generation: UUID(), zones: [.init(name: "test-zone", ownerName: "test-owner")])
  try await persistence.activateEmptyCollection(namespace: namespace)
  return persistence
}

private func addCommand(_ content: String) -> SnipLibraryCommand {
  .add(content: content, origin: .agent, source: nil, listID: SnipList.inboxID,
    attachmentURLs: [], requestID: UUID(), now: Date())
}

/// Fails chosen activation-manifest writes the way a full or failing disk would.
private final class ManifestWriteFaults: Sendable {
  private struct Plan {
    var failuresAtNextReservationClear = 0
    var failingWrites = 0
  }

  private let plan = Mutex(Plan())

  func failNextWrites(_ count: Int) {
    plan.withLock { $0.failingWrites = count }
  }

  /// Fails writes starting at the next reservation clear, so the reservation itself still commits.
  func failNextReservationClear(writes count: Int) {
    plan.withLock { $0.failuresAtNextReservationClear = count }
  }

  func armAtReservationClear(_ point: SyncModeWritePoint) {
    guard point == .beforeReservationCleared else { return }
    plan.withLock {
      $0.failingWrites += $0.failuresAtNextReservationClear
      $0.failuresAtNextReservationClear = 0
    }
  }

  func write(_ data: Data, to url: URL) throws {
    let fails = plan.withLock { plan in
      guard plan.failingWrites > 0 else { return false }
      plan.failingWrites -= 1
      return true
    }
    if fails { throw ManifestWriteFault.injected }
    try DurableFile.write(data, to: url)
  }
}

private enum ManifestWriteFault: Error { case injected }

/// Fails the next library save the way a full disk would.
private final class SaveFault: Sendable {
  private let armed = Mutex(false)

  func failNextSave() {
    armed.withLock { $0 = true }
  }

  func check() throws {
    let fails = armed.withLock { armed in
      defer { armed = false }
      return armed
    }
    if fails { throw CocoaError(.fileWriteOutOfSpace) }
  }
}

private actor SequentialUpdateLatch {
  private var isOpen = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}
