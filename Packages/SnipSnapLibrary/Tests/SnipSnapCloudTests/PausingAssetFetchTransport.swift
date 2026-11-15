import Foundation
import SnipSnapCloud
import Synchronization

/// Forwards every call to a fake transport, but asks `pause` before each asset fetch.
struct PausingAssetFetchTransport: CloudRecordTransport {
  let inner: FakeCloudRecordTransport
  let pause: AssetFetchPause

  func start(state: CloudEngineStateEnvelope?) async throws {
    try await inner.start(state: state)
  }

  func start(
    state: CloudEngineStateEnvelope?,
    initialOutbound: CloudOutboundBatch?
  ) async throws {
    try await inner.start(state: state, initialOutbound: initialOutbound)
  }

  func start(
    state: CloudEngineStateEnvelope?,
    initialOutbound: CloudOutboundBatch?,
    outboundAdmission: CloudRecordOutboundAdmission
  ) async throws {
    try await inner.start(
      state: state,
      initialOutbound: initialOutbound,
      outboundAdmission: outboundAdmission
    )
  }

  func reset() async {
    await inner.reset()
  }

  func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
    try await inner.fetch(scope: scope)
  }

  func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
    try await inner.send(batch)
  }

  func confirmApplied(_ batchID: UUID) async throws {
    try await inner.confirmApplied(batchID)
  }

  func confirmApplied(
    _ batchID: UUID,
    outboundAdmission: CloudRecordOutboundAdmission
  ) async throws {
    try await inner.confirmApplied(batchID, outboundAdmission: outboundAdmission)
  }

  func pendingEvent() async -> CloudRecordTransportEvent? {
    await inner.pendingEvent()
  }

  func finishCurrentSyncCycle() async throws {
    try await inner.finishCurrentSyncCycle()
  }

  func fetchRecord(_ id: CloudRecordID, fields: Set<String>) async throws -> CloudRecordSnapshot? {
    try await inner.fetchRecord(id, fields: fields)
  }

  func fetchAsset(
    _ id: CloudRecordID,
    field: String,
    destination: CloudAssetDestination
  ) async throws -> CloudAssetReceipt? {
    await pause.hit()
    return try await inner.fetchAsset(id, field: field, destination: destination)
  }
}

/// Once armed, holds the next asset fetch until `release()`. Every other fetch passes through.
final class AssetFetchPause: Sendable {
  private struct State {
    var armed = false
    var paused = false
    var released = false
    var waiting: CheckedContinuation<Void, Never>?
  }

  private let state = Mutex(State())

  func arm() {
    state.withLock { $0.armed = true }
  }

  func hit() async {
    let holds = state.withLock { state in
      guard state.armed else { return false }
      state.armed = false
      state.paused = true
      return true
    }
    guard holds else { return }
    await withCheckedContinuation { continuation in
      let releasedEarly = state.withLock { state in
        if !state.released { state.waiting = continuation }
        return state.released
      }
      if releasedEarly { continuation.resume() }
    }
  }

  func release() {
    let waiting = state.withLock { state in
      state.released = true
      defer { state.waiting = nil }
      return state.waiting
    }
    waiting?.resume()
  }

  /// Returns whether the held fetch started within `timeout`.
  func waitUntilPaused(within timeout: Duration) async -> Bool {
    await poll(within: timeout) { state.withLock { $0.paused } }
  }
}

/// Marks when a task's work ends, so a test can wait a bounded time for it.
final class TaskEndMark: Sendable {
  private let ended = Mutex(false)

  func set() {
    ended.withLock { $0 = true }
  }

  /// Returns whether the mark was set within `timeout`.
  func wait(within timeout: Duration) async -> Bool {
    await poll(within: timeout) { ended.withLock { $0 } }
  }
}

/// Checks `condition` until it holds or `timeout` passes, and returns whether it holds.
func poll(within timeout: Duration, until condition: () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while !(await condition()), ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}
