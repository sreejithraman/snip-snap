import CloudKit
import Foundation
import XCTest
@testable import SnipSnapCloud

final class CloudRecordTransportMailboxTests: XCTestCase {
  func testEventDuringFailedDeliveryGetsOneFollowupWithoutSpinning() async throws {
    let mailbox = CloudRecordTransportMailbox()
    let pause = MailboxControlPause()
    let calls = MailboxDeliveryCount()
    let followup = expectation(description: "An intervening event gets another delivery")
    let unexpected = expectation(description: "A failed head alone does not spin")
    unexpected.isInverted = true
    mailbox.configure {
      switch await calls.next() {
      case 1:
        await pause.suspend()
      case 2:
        followup.fulfill()
      default:
        unexpected.fulfill()
      }
      // An apply failure returns without confirming the head.
    }
    let first = UUID()
    let second = UUID()
    mailbox.append(.accountChange(first))
    await pause.waitUntilSuspended()
    mailbox.append(.accountChange(second))
    await pause.resume()
    await fulfillment(of: [followup], timeout: 2)
    await fulfillment(of: [unexpected], timeout: 0.1)
    let count = await calls.value
    XCTAssertEqual(count, 2)
    XCTAssertEqual(mailbox.first?.id, first)
    _ = try mailbox.confirm(first)
    XCTAssertEqual(mailbox.first?.id, second)
    _ = try mailbox.confirm(second)
  }

  func testFailedFetchWithholdsQueuedAndFrozenWorkUntilFreshScheduling() {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let saveID = CloudRecordID(zone: zone, name: "save")
    let deleteID = CloudRecordID(zone: zone, name: "delete")
    let otherID = CloudRecordID(zone: zone, name: "other")
    let original = CloudRecordDraft.text(id: saveID, snipID: UUID(), text: "old shadow")
    let refreshed = CloudRecordDraft.text(id: saveID, snipID: UUID(), text: "new shadow")
    var queue = CloudRecordOutboundQueue()
    _ = queue.schedule(CloudOutboundBatch(operations: [
      .save(original), .delete(deleteID, base: nil), .delete(otherID, base: nil),
    ]))
    queue.beginCycle()
    let failedID = UUID()
    queue.observe(.fetched(CloudFetchedBatch(id: failedID,
      items: [.failed(saveID, .invalidRecord), .failed(deleteID, .retryable)], engineState: nil)), zones: [zone])

    XCTAssertEqual(queue.current.operations.map(\.id), [otherID])
    XCTAssertEqual(queue.cycle?.operations(pendingIDs: [saveID, deleteID, otherID]).map(\.id), [otherID])
    XCTAssertNil(queue.cycle?.draft(saveID))
    queue.recordSupplied([otherID])
    // A successful refetch can refresh queued work but cannot change the frozen cycle.
    queue.confirmAdmission(failedID, durable: CloudRecordOutboundAdmission(blockedRecordIDs: [saveID, deleteID]))
    let recoveredID = UUID()
    queue.confirmAdmission(recoveredID, durable: CloudRecordOutboundAdmission(blockedRecordIDs: [deleteID]))
    XCTAssertNil(queue.schedule(CloudOutboundBatch(operations: [.save(refreshed)])))
    XCTAssertNil(queue.cycle?.draft(saveID))
    let sentID = UUID()
    XCTAssertEqual(queue.finishCycle(sentID).operations.map(\.id), [otherID])
    queue.confirm(CloudSentBatch(id: sentID, items: [.deleted(otherID)], engineState: nil))
    queue.beginCycle()
    XCTAssertEqual(queue.cycle?.draft(saveID), refreshed)
    XCTAssertEqual(queue.cycle?.operations(pendingIDs: [saveID, deleteID]).map(\.id), [saveID])
  }

  func testResetDropsOldCheckpointsBeforeAnAlreadyQueuedNotificationRuns() throws {
    let mailbox = CloudRecordTransportMailbox()
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account", generation: UUID(), zones: [])
    let old = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("old".utf8))
    let fresh = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("fresh".utf8))
    mailbox.append(.checkpoint(UUID(), old))
    mailbox.reset()
    let freshID = UUID()
    mailbox.append(.checkpoint(freshID, fresh))
    guard case .checkpoint(let id, let state)? = mailbox.first else { return XCTFail("Missing fresh checkpoint") }
    XCTAssertEqual(id, freshID)
    XCTAssertEqual(state, fresh)
    _ = try mailbox.confirm(freshID)
    XCTAssertNil(mailbox.first)
  }

  func testCheckpointsAloneDoNotBlockARecordProvider() {
    let mailbox = CloudRecordTransportMailbox()
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account", generation: UUID(), zones: [])
    mailbox.append(.checkpoint(UUID(), CloudEngineStateEnvelope(namespace: namespace, serialization: Data())))
    XCTAssertFalse(mailbox.hasUncommittedRecords)
    let fetched = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
    mailbox.append(.batch(CloudPendingBatch(batch: .fetched(fetched), outbound: nil)))
    XCTAssertTrue(mailbox.hasUncommittedRecords)
  }

  func testUnattemptedCycleKeepsRestoredWorkUntilTheFetchMailboxCommits() async throws {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let id = CloudRecordID(zone: zone, name: "restored-pending")
    let outbound = CloudOutboundBatch(operations: [.delete(id, base: nil)])
    var queue = CloudRecordOutboundQueue()
    _ = queue.schedule(outbound)
    let mailbox = CloudRecordTransportMailbox()
    let fetched = CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.fetched(zone)], engineState: nil)
    let control = MailboxControlPause()
    let drained = expectation(description: "The delegate mailbox drains after the control check")
    mailbox.configure {
      await control.suspend()
      while let event = mailbox.first { _ = try? mailbox.confirm(event.id) }
      drained.fulfill()
    }
    mailbox.append(.batch(CloudPendingBatch(batch: .fetched(fetched), outbound: nil)))
    await control.waitUntilSuspended()

    // The engine can finish a cycle while its record provider waits for a fetch commit.
    queue.beginCycle()
    XCTAssertTrue(mailbox.hasUncommittedRecords)
    let sentID = UUID()
    let supplied = queue.finishCycle(sentID)
    XCTAssertTrue(supplied.operations.isEmpty)
    let sent = CloudSentBatch(id: sentID,
      items: supplied.operations.map { .failed($0.id, .retryable) }, engineState: nil)
    XCTAssertNil(CloudSyncIssueError.issue(in: .sent(sent)))
    mailbox.append(.batch(CloudPendingBatch(batch: .sent(sent), outbound: supplied)))
    XCTAssertNil(queue.schedule(outbound))

    await control.resume()
    await fulfillment(of: [drained], timeout: 2)
    queue.confirm(sent)
    // Re-adding after commit uses CKSyncEngine's documented automatic scheduling entry point.
    XCTAssertEqual(queue.schedule(outbound), outbound)
    queue.beginCycle()
    queue.recordSupplied([id])
    let completedID = UUID()
    XCTAssertEqual(queue.finishCycle(completedID).operations, outbound.operations)
    queue.confirm(CloudSentBatch(id: completedID, items: [.deleted(id)], engineState: nil))
    XCTAssertTrue(queue.current.operations.isEmpty)
  }

  func testAcknowledgementIncludesOnlyRecordsReturnedByApplesBatchHelper() async throws {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let operations = (0..<300).map { index in
      CloudOutboundOperation.delete(CloudRecordID(zone: zone, name: "item-\(index)"), base: nil)
    }
    var queue = CloudRecordOutboundQueue()
    _ = queue.schedule(CloudOutboundBatch(operations: operations))
    queue.beginCycle()
    let pending = operations.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(
      CloudKitRecordMapper.recordID(for: $0.id)) }
    let provided = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending, recordProvider: { _ in nil })
    let batch = try XCTUnwrap(provided)
    let suppliedIDs = Set(batch.recordIDsToDelete.map(CloudKitRecordMapper.id(for:)))
    XCTAssertFalse(suppliedIDs.isEmpty)
    XCTAssertLessThan(suppliedIDs.count, operations.count)
    queue.recordSupplied(suppliedIDs)

    let batchID = UUID()
    let sent = queue.finishCycle(batchID)
    XCTAssertEqual(Set(sent.operations.map(\.id)), suppliedIDs)
    queue.confirm(CloudSentBatch(id: batchID, items: suppliedIDs.map { .deleted($0) }, engineState: nil))
    XCTAssertEqual(Set(queue.current.operations.map(\.id)), Set(operations.map(\.id)).subtracting(suppliedIDs))
  }

  func testSendCycleDefersNewIDsAndNewBodiesUntilTheOriginalResultIsCommitted() {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let firstID = CloudRecordID(zone: zone, name: "first")
    let laterID = CloudRecordID(zone: zone, name: "later")
    let snipID = UUID()
    let original = CloudRecordDraft.text(id: firstID, snipID: snipID, text: "original")
    let edited = CloudRecordDraft.text(id: firstID, snipID: snipID, text: "edited")
    let newRecord = CloudRecordDraft.text(id: laterID, snipID: UUID(), text: "new")
    let first = CloudOutboundBatch(operations: [.save(original)], zonesToSave: [zone])
    let later = CloudOutboundBatch(operations: [.save(edited), .save(newRecord)])
    var queue = CloudRecordOutboundQueue()
    XCTAssertEqual(queue.schedule(first), first)
    queue.beginCycle()

    XCTAssertNil(queue.schedule(later))
    XCTAssertEqual(queue.cycle?.draft(firstID), original)
    XCTAssertNil(queue.cycle?.draft(laterID))
    XCTAssertEqual(queue.cycle?.operations(pendingIDs: [firstID, laterID]), first.operations)
    queue.recordSupplied([firstID])
    let sentID = UUID()
    XCTAssertEqual(queue.finishCycle(sentID), first)
    XCTAssertNil(queue.schedule(later))

    queue.confirm(CloudSentBatch(id: sentID, items: [], databaseEvents: [.zoneSaved(zone)], engineState: nil))
    XCTAssertEqual(queue.schedule(later), later)
    queue.beginCycle()
    XCTAssertEqual(queue.cycle?.draft(firstID), edited)
    XCTAssertEqual(queue.cycle?.draft(laterID), newRecord)
  }
}

private actor MailboxDeliveryCount {
  private(set) var value = 0

  func next() -> Int {
    value += 1
    return value
  }
}

private actor MailboxControlPause {
  private var suspended = false
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?

  func suspend() async {
    if released { return }
    suspended = true
    waiters.forEach { $0.resume() }
    waiters = []
    await withCheckedContinuation { release = $0 }
  }
  func waitUntilSuspended() async {
    if suspended { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func resume() {
    released = true
    release?.resume()
    release = nil
  }
}
