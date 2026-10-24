import Foundation
import SnipSnapCore
import XCTest
@testable import SnipSnapPersistence

final class SnipCLIDataRecoveryTests: XCTestCase {
  func testGuardedListRecoveryRejectsStaleCurrentAndAcceptsEditedDataAfterReread() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("snips.store"))
    let scope = SnipRecoveryScope("guarded-list")
    let created = try await store.perform(.createList(name: "Current", systemImage: "folder"),
                                          sortedBy: .chronological)
    let current = try XCTUnwrap(created.snapshot.lists.first { $0.name == "Current" })
    var alternate = current
    alternate.name = "Recovered"
    let recovered = RecoveredListEdit(id: UUID(), currentListID: current.id,
                                     recovered: alternate, conflictingFields: [.name])
    try await store.testStoreCloudConflict(namespaceKey: .init(rawValue: scope.rawValue),
      key: "list-choice", reference: .init(kind: .list, domainID: current.id),
      payload: Data("wire".utf8), recovery: .list(recovered))
    _ = try await store.perform(.updateList(id: current.id, name: "Newer", systemImage: "star"),
                                sortedBy: .chronological)
    let session = SavedSnipsSession(library: store, recoveryScope: scope)
    do {
      _ = try await session.resolveRecovery(recovered.id, choice: .useRecovered,
        expectation: .init(record: .list(recovered), currentList: current), sortedBy: .chronological)
      XCTFail("A newer list must invalidate the recovery guard")
    } catch SnipLibraryError.recoveryChanged {}
    let latest = try await store.checkedSnapshot(sortedBy: .chronological)
    let newer = try XCTUnwrap(latest.lists.first { $0.id == current.id })
    var edited = alternate
    edited.name = "Edited"
    let result = try await session.resolveRecovery(recovered.id, choice: .editList(edited),
      expectation: .init(record: .list(recovered), currentList: newer), sortedBy: .chronological)
    XCTAssertEqual(result?.library.lists.first { $0.id == current.id }?.name, "Edited")
    XCTAssertEqual(result?.library.lists.first { $0.id == current.id }?.systemImage, "star")
    XCTAssertEqual(result?.recovery.pendingLists.count, 0)
  }

  func testGuardedSnipRecoverySupportsEveryChoiceIncludingEditedData() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var edited = Snip(content: "Edited", origin: .quickEntry)
    edited.isDone = false
    let choices: [(SnipRecoveryChoice, String, Int)] = [
      (.keepCurrent, "Current", 1), (.useRecovered, "Recovered", 1),
      (.keepBoth, "Current", 2), (.editSnip(edited), "Edited", 1)
    ]
    for (index, scenario) in choices.enumerated() {
      let store = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("\(index)/snips.store"))
      let scope = SnipRecoveryScope("guarded-choices")
      let current = Snip(content: "Current", origin: .quickEntry, isDone: true)
      let alternate = Snip(content: "Recovered", origin: .quickEntry)
      let recovered = RecoveredSnip(id: alternate.id, currentSnipID: current.id,
                                   recovered: alternate, conflictingFields: [.text])
      _ = try await store.perform(.restore(snips: [current]), sortedBy: .chronological)
      try await store.testStoreCloudConflict(namespaceKey: .init(rawValue: scope.rawValue),
        key: "choice", reference: .init(kind: .snip, domainID: current.id),
        payload: Data("wire".utf8), recovery: .snip(recovered))
      let session = SavedSnipsSession(library: store, recoveryScope: scope)
      let result = try await session.resolveRecovery(recovered.id, choice: scenario.0,
        expectation: .init(record: .snip(recovered), currentSnip: current), sortedBy: .chronological)
      XCTAssertEqual(result?.library.snips.first { $0.id == current.id }?.content, scenario.1)
      XCTAssertEqual(result?.library.snips.first { $0.id == current.id }?.isDone, true)
      XCTAssertEqual(result?.library.snips.count, scenario.2)
      XCTAssertEqual(result?.recovery.pendingSnips.count, 0)
    }
  }

  func testGuardedRecoveryRejectsChangedCurrentWithoutConsumingRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("snips.store")
    let store = try SwiftDataSnipLibrary(storeURL: storeURL)
    let scope = SnipRecoveryScope("guarded-recovery")
    let current = Snip(content: "Current", origin: .quickEntry)
    let alternate = Snip(content: "Recovered", origin: .quickEntry)
    let recovered = RecoveredSnip(id: alternate.id, currentSnipID: current.id,
                                 recovered: alternate, conflictingFields: [.text])
    _ = try await store.perform(.restore(snips: [current]), sortedBy: .chronological)
    try await store.testStoreCloudConflict(namespaceKey: .init(rawValue: scope.rawValue),
      key: "guarded", reference: .init(kind: .snip, domainID: current.id),
      payload: Data("wire".utf8), recovery: .snip(recovered))
    let expectation = SnipRecoveryExpectation(record: .snip(recovered), currentSnip: current)
    let otherWriter = try SwiftDataSnipLibrary(storeURL: storeURL)
    _ = try await otherWriter.perform(.setDone(ids: [current.id], done: true), sortedBy: .chronological)
    let session = SavedSnipsSession(library: store, recoveryScope: scope)
    do {
      _ = try await session.resolveRecovery(recovered.id, choice: .useRecovered,
        expectation: expectation, sortedBy: .chronological)
      XCTFail("A newer linked snip must invalidate the recovery guard")
    } catch SnipLibraryError.recoveryChanged {}
    let snapshot = try await store.checkedSnapshot(sortedBy: .chronological)
    XCTAssertEqual(snapshot.snips.first?.content, "Current")
    XCTAssertEqual(snapshot.snips.first?.isDone, true)
    let pending = try await store.recoverySnapshot(in: scope)
    XCTAssertEqual(pending.pendingSnips, [recovered])
  }
}
