import Foundation
import SwiftData
import XCTest

@testable import SnipSnapCore
@testable import SnipSnapPersistence

extension CloudFullRecordPersistenceTests {
  func testReenableMergeKeepsAcceptedBytesAndAtomicallyStoresSidecars() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-reenable")
    let transitionID = UUID()
    let listID = UUID()
    try await store.testAcceptCloudEntity(
      namespaceKey: namespace,
      value: entity(.list, listID, identity("l-\(listID.uuidString.lowercased())"))
    )
    let storageBefore = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    let acceptedBefore = try XCTUnwrap(storageBefore.readyEntities.first)
    let target = try await store.transferSnapshot(revision: 9)
    let sendBatch = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: transitionID,
      expectedEngineState: nil,
      nextEngineState: nil,
      items: []
    )
    try await store.stageCloudFullBatch(sendBatch)
    let sendResult = try await store.commitCloudFullBatch(sendBatch)
    XCTAssertEqual(sendResult, .applied)
    let conflict = CloudConflictInput(
      key: "reenable-list-conflict",
      reference: acceptedBefore.reference,
      format: .listMergeV1,
      payload: Data("conflict".utf8)
    )
    let recoveryID = SnipLibraryTransferPlanner.derivedUUID(
      transitionID: transitionID,
      sourceID: listID
    )
    let recovery = CloudFullRecoveryInput(
      namespaceKey: namespace.rawValue,
      batchID: recoveryID,
      kind: .terminalFetch,
      outboundData: Data(),
      resultData: try JSONSerialization.data(withJSONObject: [
        "storageVersion": 1, "batch": ["fetched": ["_0": [
          "id": recoveryID.uuidString, "items": [], "zoneEvents": [],
          "databaseEvents": [["failed": [
            "_0": ["name": "text", "ownerName": "owner"], "_1": "quotaExceeded",
          ]]],
        ]]],
      ])
    )
    let transfer = try SnipLibraryTransferPlanner.plan(source: target, target: target, transitionID: transitionID)
    let plan = CloudFullReenableApplyPlan(
      namespaceKey: namespace.rawValue, transfer: transfer, conflicts: [conflict],
      recoveryInputs: [recovery], result: transfer.result
    )

    let failing = try SwiftDataSnipLibrary(
      storeURL: location.store,
      afterMutationBeforeSave: { throw Crash.expected }
    )
    do {
      try await failing.applyCloudFullReenablePlan(plan)
      XCTFail("Expected the one-save re-enable failure")
    } catch {
      XCTAssertTrue(error is Crash)
    }
    let afterFailure = try SwiftDataSnipLibrary(storeURL: location.store)
    let failedStorage = try await afterFailure.cloudFullStorageSnapshot(namespaceKey: namespace)
    let failedRecovery = try await afterFailure.cloudFullRecoveryEvents(namespaceKey: namespace)
    XCTAssertEqual(failedStorage.readyEntities, [acceptedBefore])
    XCTAssertTrue(failedStorage.conflicts.isEmpty)
    XCTAssertTrue(failedRecovery.isEmpty)

    try await store.applyCloudFullReenablePlan(plan)
    let sendReplay = try await store.commitCloudFullBatch(sendBatch)
    XCTAssertEqual(sendReplay, .replayed)

    let storageAfter = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    let acceptedAfter = try XCTUnwrap(storageAfter.readyEntities.first)
    XCTAssertEqual(acceptedAfter, acceptedBefore)
    let stored = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(stored.conflicts.map(\.key), [conflict.key])
    let recoveryAfter = try await store.cloudFullRecoveryEvents(namespaceKey: namespace)
    XCTAssertEqual(recoveryAfter.count, 1)
  }

  func testReenablePlanNeverOverwritesDifferentBytesAtDeterministicAttachmentPath() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let input = location.root.appendingPathComponent("input.txt")
    let originalBytes = Data("original bytes".utf8)
    try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
    try originalBytes.write(to: input)
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    _ = try await store.perform(
      .add(
        content: "attachment",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [input],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    let target = try await store.transferSnapshot(revision: 2)
    let attachment = try XCTUnwrap(target.snips.first?.attachments.first)
    var changedBytes = target.attachmentData
    changedBytes[attachment.id] = Data("different bytes".utf8)
    let source = SnipLibraryTransferSnapshot(revision: 0, snips: target.snips, lists: target.lists,
      attachmentData: changedBytes)
    let empty = SnipLibraryTransferSnapshot(revision: 0, snips: [], lists: [.inbox], attachmentData: [:])
    let transfer = try SnipLibraryTransferPlanner.plan(source: source, target: empty, transitionID: UUID())
    let plan = CloudFullReenableApplyPlan(
      namespaceKey: "private|attachment-collision", transfer: transfer, conflicts: [],
      recoveryInputs: [], result: transfer.result
    )

    do {
      try await store.applyCloudFullReenablePlan(plan)
      XCTFail("Expected the attachment collision")
    } catch {
      XCTAssertEqual(
        error as? SnipLibraryError,
        .transferConflict(.attachmentIdentity(attachment.id))
      )
    }
    let after = await store.snapshot(sortedBy: .manual)
    let storedURL = try XCTUnwrap(after.attachmentURLs[attachment.id])
    XCTAssertEqual(try Data(contentsOf: storedURL), originalBytes)
  }
}
