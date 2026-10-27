import Foundation
import SnipSnapCore
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
