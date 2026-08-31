import Foundation
import SwiftData
import XCTest

@testable import SnipSnapCore
@testable import SnipSnapPersistence

extension CloudFullRecordPersistenceTests {
  func testReenablePlanKeepsFreshAcceptedBytesAndAtomicallyStoresSidecarsAndReceipt() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let namespace = "private|account-a|generation-reenable"
    let transitionID = UUID()
    let listID = UUID()
    _ = try await store.acceptCloudEntity(
      namespaceKey: namespace,
      value: entity(.list, listID, identity("l-\(listID.uuidString.lowercased())"))
    )
    let storageBefore = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    let acceptedBefore = try XCTUnwrap(storageBefore.readyEntities.first)
    let target = try await store.transferSnapshot(revision: 9)
    let conflict = CloudConflictInput(
      key: "reenable-list-conflict",
      reference: acceptedBefore.reference,
      format: .listMergeV1,
      payload: Data("conflict".utf8)
    )
    let recovery = CloudFullRecoveryInput(
      namespaceKey: namespace,
      batchID: SnipLibraryTransferPlanner.derivedUUID(
        transitionID: transitionID,
        sourceID: listID
      ),
      kind: .terminalFetch,
      outboundData: Data(),
      resultData: Data("recovered".utf8)
    )
    let plan = try CloudFullReenableApplyPlan(
      transitionID: transitionID,
      namespaceKey: namespace,
      targetRevision: target.revision,
      targetDigest: SnipLibraryTransferPlanner.digest(snapshot: target),
      snips: target.snips,
      lists: target.lists,
      attachmentData: target.attachmentData,
      dormantPayload: target.opaqueSyncStatePayload,
      acceptedCAS: [CloudFullReenableAcceptedCAS(acceptedBefore)],
      conflicts: [conflict],
      recoveryInputs: [recovery],
      result: SnipLibraryTransferResult(approvedSnipIDs: [], recoveredSourceSnipIDs: [])
    )

    let failing = try SwiftDataSnipLibrary(
      storeURL: location.store,
      afterMutationBeforeSave: { throw Crash.expected }
    )
    do {
      _ = try await failing.applyCloudFullReenablePlan(plan, currentRevision: 9)
      XCTFail("Expected the one-save re-enable failure")
    } catch {
      XCTAssertTrue(error is Crash)
    }
    let afterFailure = try SwiftDataSnipLibrary(storeURL: location.store)
    let failedStorage = try await afterFailure.cloudFullStorageSnapshot(namespaceKey: namespace)
    let failedRecovery = try await afterFailure.cloudFullRecoveryEvents(namespaceKey: namespace)
    let failedReceipt = try await afterFailure.cloudFullReenableReceipt(
      namespaceKey: namespace,
      transitionID: transitionID
    )
    XCTAssertEqual(failedStorage.readyEntities, [acceptedBefore])
    XCTAssertTrue(failedStorage.conflicts.isEmpty)
    XCTAssertTrue(failedRecovery.isEmpty)
    XCTAssertNil(failedReceipt)

    _ = try await store.applyCloudFullReenablePlan(plan, currentRevision: 9)
    _ = try await store.applyCloudFullReenablePlan(plan, currentRevision: 9)

    let storageAfter = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    let acceptedAfter = try XCTUnwrap(storageAfter.readyEntities.first)
    XCTAssertEqual(acceptedAfter, acceptedBefore)
    let stored = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(stored.conflicts.map(\.key), [conflict.key])
    let recoveryAfter = try await store.cloudFullRecoveryEvents(namespaceKey: namespace)
    let receipt = try await store.cloudFullReenableReceipt(
      namespaceKey: namespace,
      transitionID: transitionID
    )
    XCTAssertEqual(recoveryAfter.count, 1)
    XCTAssertEqual(receipt, plan.planDigest)

    let mismatchedReplay = try CloudFullReenableApplyPlan(
      transitionID: transitionID,
      namespaceKey: namespace,
      targetRevision: target.revision,
      targetDigest: SnipLibraryTransferPlanner.digest(snapshot: target),
      snips: target.snips,
      lists: target.lists,
      attachmentData: target.attachmentData,
      dormantPayload: target.opaqueSyncStatePayload,
      acceptedCAS: [CloudFullReenableAcceptedCAS(acceptedBefore)],
      conflicts: [conflict],
      recoveryInputs: [recovery],
      result: SnipLibraryTransferResult(
        approvedSnipIDs: [],
        recoveredSourceSnipIDs: [listID]
      )
    )
    do {
      _ = try await store.applyCloudFullReenablePlan(mismatchedReplay, currentRevision: 9)
      XCTFail("Expected the receipt digest mismatch")
    } catch CloudFullStorageError.invalidBatchReplay {
      // Expected.
    }
    let receiptAfterMismatch = try await store.cloudFullReenableReceipt(
      namespaceKey: namespace,
      transitionID: transitionID
    )
    XCTAssertEqual(receiptAfterMismatch, plan.planDigest)
  }

  func testReenablePlanRejectsStaleAcceptedCASWithoutChangingAnySidecar() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let namespace = "private|account-a|generation-stale"
    let transitionID = UUID()
    let listID = UUID()
    let first = entity(.list, listID, identity("l-stale"))
    _ = try await store.acceptCloudEntity(namespaceKey: namespace, value: first)
    let before = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    let accepted = try XCTUnwrap(before.readyEntities.first)
    let target = try await store.transferSnapshot(revision: 3)
    let conflict = CloudConflictInput(
      key: "must-not-write",
      reference: accepted.reference,
      format: .listMergeV1,
      payload: Data("conflict".utf8)
    )
    let plan = try CloudFullReenableApplyPlan(
      transitionID: transitionID,
      namespaceKey: namespace,
      targetRevision: 3,
      targetDigest: SnipLibraryTransferPlanner.digest(snapshot: target),
      snips: target.snips,
      lists: target.lists,
      attachmentData: target.attachmentData,
      dormantPayload: target.opaqueSyncStatePayload,
      acceptedCAS: [CloudFullReenableAcceptedCAS(accepted)],
      conflicts: [conflict],
      recoveryInputs: [],
      result: SnipLibraryTransferResult(approvedSnipIDs: [], recoveredSourceSnipIDs: [])
    )
    let changed = CloudAcceptedEntityInput(
      reference: first.reference,
      identity: first.identity,
      schemaVersion: first.schemaVersion,
      acceptedData: Data("changed".utf8),
      presenceData: first.presenceData,
      shadowData: first.shadowData,
      systemFields: Data("changed-system".utf8),
      dependencyListID: first.dependencyListID
    )
    _ = try await store.acceptCloudEntity(namespaceKey: namespace, value: changed)

    do {
      _ = try await store.applyCloudFullReenablePlan(plan, currentRevision: 3)
      XCTFail("Expected stale accepted CAS")
    } catch {
      XCTAssertEqual(error as? CloudFullStorageError, .staleAcceptedEntity)
    }
    let after = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    let recovery = try await store.cloudFullRecoveryEvents(namespaceKey: namespace)
    XCTAssertTrue(after.conflicts.isEmpty)
    XCTAssertTrue(recovery.isEmpty)
    let receipt = try await store.cloudFullReenableReceipt(
      namespaceKey: namespace,
      transitionID: transitionID
    )
    XCTAssertNil(receipt)
  }

  func testReenablePlanRejectsAddedAcceptedRowAndNamespaceRevisionChange() async throws {
    for change in ["added-row", "namespace-revision"] {
      let location = temporaryStore()
      defer { try? FileManager.default.removeItem(at: location.root) }
      let store = try SwiftDataSnipLibrary(storeURL: location.store)
      let namespace = "private|account-a|generation-exact-cas-\(change)"
      let first = entity(.list, UUID(), identity("l-first"))
      _ = try await store.acceptCloudEntity(namespaceKey: namespace, value: first)
      let before = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
      let target = try await store.transferSnapshot(revision: 1)
      let plan = try CloudFullReenableApplyPlan(
        transitionID: UUID(),
        namespaceKey: namespace,
        expectedNamespaceRevision: before.namespaceState.revision,
        targetRevision: 1,
        targetDigest: SnipLibraryTransferPlanner.digest(snapshot: target),
        snips: target.snips,
        lists: target.lists,
        attachmentData: target.attachmentData,
        dormantPayload: target.opaqueSyncStatePayload,
        acceptedCAS: before.readyEntities.map(CloudFullReenableAcceptedCAS.init),
        conflicts: [],
        recoveryInputs: [],
        result: SnipLibraryTransferResult(approvedSnipIDs: [], recoveredSourceSnipIDs: [])
      )
      if change == "added-row" {
        _ = try await store.acceptCloudEntity(
          namespaceKey: namespace,
          value: entity(.list, UUID(), identity("l-added"))
        )
      } else {
        try await store.setCloudEnrollment(
          namespaceKey: namespace,
          references: [first.reference],
          localDependencies: [:]
        )
      }

      do {
        _ = try await store.applyCloudFullReenablePlan(plan, currentRevision: 1)
        XCTFail("Expected exact accepted-state CAS rejection")
      } catch {
        if change == "added-row" {
          XCTAssertEqual(error as? CloudFullStorageError, .staleAcceptedEntity)
        } else {
          XCTAssertEqual(error as? CloudFullStorageError, .namespaceStateMismatch)
        }
      }
      let receipt = try await store.cloudFullReenableReceipt(
        namespaceKey: namespace,
        transitionID: plan.transitionID
      )
      XCTAssertNil(receipt)
    }
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
    let transitionID = UUID()
    var changedBytes = target.attachmentData
    changedBytes[attachment.id] = Data("different bytes".utf8)
    let plan = try CloudFullReenableApplyPlan(
      transitionID: transitionID,
      namespaceKey: "private|attachment-collision",
      targetRevision: 2,
      targetDigest: SnipLibraryTransferPlanner.digest(snapshot: target),
      snips: target.snips,
      lists: target.lists,
      attachmentData: changedBytes,
      dormantPayload: target.opaqueSyncStatePayload,
      acceptedCAS: [],
      conflicts: [],
      recoveryInputs: [],
      result: SnipLibraryTransferResult(approvedSnipIDs: [], recoveredSourceSnipIDs: [])
    )

    do {
      _ = try await store.applyCloudFullReenablePlan(plan, currentRevision: 2)
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
    let receipt = try await store.cloudFullReenableReceipt(
      namespaceKey: plan.namespaceKey,
      transitionID: transitionID
    )
    XCTAssertNil(receipt)
  }
}
