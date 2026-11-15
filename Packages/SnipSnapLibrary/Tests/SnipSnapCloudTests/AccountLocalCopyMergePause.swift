import SnipSnapPersistence
import Synchronization

/// Holds the first Keep Local Copy merge at its seam until released, then lets it go on, or
/// fail when built with `failsOnRelease`. Later merges pass through. Every merge that reaches
/// the seam counts.
final class AccountLocalCopyMergePause: Sendable {
  enum Failure: Error { case injected }

  private struct State {
    var hits = 0
    var released = false
    var paused: CheckedContinuation<Void, Never>?
  }

  private let state = Mutex(State())
  private let failsOnRelease: Bool

  init(failsOnRelease: Bool = false) {
    self.failsOnRelease = failsOnRelease
  }

  var hits: Int { state.withLock { $0.hits } }

  func hit(_ point: SyncModeWritePoint) async throws {
    guard point == .beforeAccountLocalCopyMerge else { return }
    let isFirst = state.withLock { state in
      state.hits += 1
      return state.hits == 1
    }
    guard isFirst else { return }
    await withCheckedContinuation { continuation in
      let releasedEarly = state.withLock { state in
        if !state.released { state.paused = continuation }
        return state.released
      }
      if releasedEarly { continuation.resume() }
    }
    if failsOnRelease { throw Failure.injected }
  }

  func release() {
    let paused = state.withLock { state in
      state.released = true
      defer { state.paused = nil }
      return state.paused
    }
    paused?.resume()
  }

  /// Polls until `count` merges reach the seam or `timeout` passes. The wait is bounded
  /// because a test also waits for a merge that a correct build never starts.
  func waitForHits(_ count: Int, within timeout: Duration) async {
    let deadline = ContinuousClock.now + timeout
    while hits < count, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}
