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
