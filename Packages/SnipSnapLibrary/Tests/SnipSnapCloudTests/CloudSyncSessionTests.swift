import Foundation
import XCTest
@testable import SnipSnapCloud
import SnipSnapCore
import SnipSnapPersistence

final class CloudSyncSessionTests: XCTestCase {
  func testTryAgainWaitsForCurrentSyncInsteadOfReportingPause() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    let prematureCompletion = expectation(description: "Retry must wait for active work")
    prematureCompletion.isInverted = true
    let retry = Task {
      defer { prematureCompletion.fulfill() }
      return try await session.retrySynchronization()
    }
    await fulfillment(of: [prematureCompletion], timeout: 0.05)
    await probe.resume()

    _ = try await first.value
    let result = try await retry.value
    XCTAssertEqual(result, .contentUpdated)
    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "retry"])
  }

  func testLocalChangesDuringSyncBecomeOneFollowUpRequest() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    for _ in 0..<20 { await session.scheduleAutomaticSync() }
    await probe.resume()
    _ = try await first.value
    await probe.waitForEvent("schedule")

    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "schedule"])
  }

  func testCancelledCallerDoesNotCancelSharedSyncWork() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    first.cancel()
    do {
      _ = try await first.value
      XCTFail("Expected the caller to stop waiting")
    } catch is CancellationError {}
    await session.scheduleAutomaticSync()
    await probe.resume()
    await probe.waitForEvent("schedule")

    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "schedule"])
  }

  func testDeleteWaitsForSyncAndCancelledQueuedDeleteDoesNotRun() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    let prematureDelete = expectation(description: "Delete must wait for sync")
    prematureDelete.isInverted = true
    let deletion = Task {
      defer { prematureDelete.fulfill() }
      return try await session.deleteSyncedContent()
    }
    await fulfillment(of: [prematureDelete], timeout: 0.05)
    deletion.cancel()
    do {
      _ = try await deletion.value
      XCTFail("Expected cancelled delete to stop")
    } catch is CancellationError {}
    await probe.resume()
    _ = try await first.value

    let events = await probe.events()
    XCTAssertEqual(events, ["sync"])
  }

  func testQueuedSyncAndTryAgainShareOneTryAgainRun() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    let sync = Task { try await session.synchronize() }
    let retry = Task { try await session.retrySynchronization() }
    try await waitForQueuedRequests(2, in: session)
    await probe.resume()

    _ = try await first.value
    let syncResult = try await sync.value
    let retryResult = try await retry.value
    XCTAssertEqual(syncResult, .contentUpdated)
    XCTAssertEqual(retryResult, .contentUpdated)
    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "retry"])
  }

  func testCancelledQueuedRequestNeverRunsAndLaterRequestsStillSync() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    let retry = Task { try await session.retrySynchronization() }
    try await waitForQueuedRequests(1, in: session)
    retry.cancel()
    try await waitForQueuedRequests(0, in: session)
    await probe.resume()
    do {
      _ = try await retry.value
      XCTFail("Expected the cancelled Try Again to stop waiting")
    } catch is CancellationError {}
    _ = try await first.value

    let later = try await session.synchronize()
    XCTAssertEqual(later, .contentUpdated)
    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "sync"])
  }

  func testFailureReachesAutomaticErrorHandlerOnlyWhenScheduledSyncJoinedTheRun() async throws {
    let probe = SessionWorkProbe()
    let reports = ErrorReports()
    let session = SnipSnapCloudSyncSession(
      synchronize: { try await probe.run("sync"); return .contentUpdated },
      retry: { try await probe.run("retry"); throw SessionTestError("retry") },
      scheduleAutomaticSync: {
        try await probe.run("schedule")
        throw SessionTestError("schedule")
      },
      enable: { try await probe.run("enable"); return .enabled },
      delete: { try await probe.run("delete"); return .completed },
      activeLibrary: { throw SyncModePersistenceError.missingStore },
      automaticErrorHandler: { error in
        await reports.record(error as? SessionTestError ?? SessionTestError("unexpected \(error)"))
      }
    )
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    let retry = Task { try await session.retrySynchronization() }
    await session.scheduleAutomaticSync()
    try await waitForQueuedRequests(2, in: session)
    await probe.resume()
    _ = try await first.value

    do {
      _ = try await retry.value
      XCTFail("Expected Try Again that absorbed scheduled sync to fail")
    } catch let error as SessionTestError {
      XCTAssertEqual(error, SessionTestError("retry"))
      let reported = await reports.values()
      XCTAssertEqual(
        reported, [SessionTestError("retry")], "The report must precede the caller's result"
      )
    }
    do {
      _ = try await session.retrySynchronization()
      XCTFail("Expected Try Again alone to fail")
    } catch let error as SessionTestError {
      XCTAssertEqual(error, SessionTestError("retry"))
      let reported = await reports.values()
      XCTAssertEqual(reported, [SessionTestError("retry")])
    }
    await session.scheduleAutomaticSync()
    await probe.waitForEvent("schedule")
    // Queued while scheduled sync runs, so it returns only after that run reports its failure.
    let later = try await session.synchronize()
    XCTAssertEqual(later, .contentUpdated)

    let reported = await reports.values()
    XCTAssertEqual(reported, [SessionTestError("retry"), SessionTestError("schedule")])
    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "retry", "retry", "schedule", "sync"])
  }

  /// Waits for callers to join the queue rather than for a fixed time.
  private func waitForQueuedRequests(
    _ count: Int,
    in session: SnipSnapCloudSyncSession,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await session.queuedRequestCount != count {
      guard ContinuousClock.now < deadline else {
        XCTFail("Expected \(count) queued sync requests", file: file, line: line)
        return
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private func makeSession(_ probe: SessionWorkProbe) -> SnipSnapCloudSyncSession {
    SnipSnapCloudSyncSession(
      synchronize: { try await probe.run("sync"); return .contentUpdated },
      retry: { try await probe.run("retry"); return .contentUpdated },
      scheduleAutomaticSync: { try await probe.run("schedule") },
      enable: { try await probe.run("enable"); return .enabled },
      delete: { try await probe.run("delete"); return .completed },
      activeLibrary: { throw SyncModePersistenceError.missingStore }
    )
  }
}

private struct SessionTestError: Error, Equatable {
  let name: String

  init(_ name: String) {
    self.name = name
  }
}

private actor ErrorReports {
  private var recorded: [SessionTestError] = []

  func record(_ error: SessionTestError) {
    recorded.append(error)
  }

  func values() -> [SessionTestError] { recorded }
}

private actor SessionWorkProbe {
  private var active = false
  private var paused = false
  private var pauseNext = true
  private var recorded: [String] = []
  private var release: CheckedContinuation<Void, Never>?
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var eventWaiters: [(String, CheckedContinuation<Void, Never>)] = []

  func run(_ name: String) async throws {
    guard !active else { throw CloudTransportError.syncAlreadyRunning }
    active = true
    defer { active = false }
    recorded.append(name)
    let ready = eventWaiters.filter { $0.0 == name }
    eventWaiters.removeAll { $0.0 == name }
    ready.forEach { $0.1.resume() }
    if pauseNext {
      pauseNext = false
      paused = true
      pauseWaiters.forEach { $0.resume() }
      pauseWaiters = []
      await withCheckedContinuation { release = $0 }
    }
  }

  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { pauseWaiters.append($0) }
  }

  func resume() {
    paused = false
    release?.resume()
    release = nil
  }

  func waitForEvent(_ name: String) async {
    if recorded.contains(name) { return }
    await withCheckedContinuation { eventWaiters.append((name, $0)) }
  }

  func events() -> [String] { recorded }
}
