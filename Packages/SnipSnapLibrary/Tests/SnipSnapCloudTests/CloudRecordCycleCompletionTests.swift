import Foundation
import XCTest
@testable import SnipSnapCloud

final class CloudRecordCycleCompletionTests: XCTestCase {
  func testCancelledExplicitTransferReleasesTheCoordinatorWhileEngineCycleContinues() async throws {
    let cycle = CloudRecordCycleCompletion()
    let firstEntered = expectation(description: "First transfer reached the active engine cycle")
    let secondEntered = expectation(description: "Next transfer acquires the coordinator")
    let transport = CycleWaitingTransport(cycle: cycle) { count in
      if count == 1 { firstEntered.fulfill() }
      if count == 2 { secondEntered.fulfill() }
    }
    let coordinator = CloudFullSyncCoordinator(store: AutomaticSyncStoreProbe(), transport: transport)
    let cancelled = expectation(description: "Explicit transfer stops without waiting for CloudKit")
    let first = Task {
      do {
        try await coordinator.sync()
        XCTFail("Expected cancellation")
      } catch is CancellationError {
        cancelled.fulfill()
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
    await fulfillment(of: [firstEntered], timeout: 2)
    first.cancel()
    await fulfillment(of: [cancelled], timeout: 2)

    // The same coordinator admits a new request; cancelling one caller did not
    // complete the engine cycle or let a fetch pass it.
    let second = Task { try await coordinator.sync() }
    await fulfillment(of: [secondEntered], timeout: 2)
    let beforeCompletion = await transport.fetchCount
    XCTAssertEqual(beforeCompletion, 0)
    cycle.finish()
    _ = try await second.value
    await first.value
    let afterCompletion = await transport.fetchCount
    XCTAssertEqual(afterCompletion, 1)
  }

  func testCompletionBeforeWaitDoesNotLoseTheWakeup() async throws {
    let cycle = CloudRecordCycleCompletion()
    cycle.finish()
    try await cycle.wait()
    cycle.finish()
    try await cycle.wait()
  }

  func testAlreadyCancelledCallerCannotPassACompletedCycle() async {
    let cycle = CloudRecordCycleCompletion()
    cycle.finish()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        try await cycle.wait()
        XCTFail("Expected cancellation")
      } catch is CancellationError {
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
    await task.value
  }
}

private actor CycleWaitingTransport: CloudRecordTransport {
  let cycle: CloudRecordCycleCompletion
  private let onWait: @Sendable (Int) -> Void
  private var waitCount = 0
  private(set) var fetchCount = 0

  init(cycle: CloudRecordCycleCompletion, onWait: @escaping @Sendable (Int) -> Void) {
    self.cycle = cycle
    self.onWait = onWait
  }
  func start(state: CloudEngineStateEnvelope?) {}
  func finishCurrentSyncCycle() async throws {
    waitCount += 1
    onWait(waitCount)
    try await cycle.wait()
  }
  func fetch(scope: CloudFetchScope) -> CloudFetchedBatch {
    fetchCount += 1
    return CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
  }
  func send(_ batch: CloudOutboundBatch) -> CloudSentBatch {
    CloudSentBatch(id: UUID(), items: [], engineState: nil)
  }
  func confirmApplied(_ batchID: UUID) {}
  func fetchRecord(_ id: CloudRecordID, fields: Set<String>) -> CloudRecordSnapshot? { nil }
  func fetchAsset(_ id: CloudRecordID, field: String,
                  destination: CloudAssetDestination) -> CloudAssetReceipt? { nil }
}
