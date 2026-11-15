import Foundation

/// One completion shared by overlapping engine cycles and their explicit callers.
/// Cancelling a caller does not cancel CloudKit's work or release other callers.
package final class CloudRecordCycleCompletion: @unchecked Sendable {
  private enum Phase {
    case waiting([UUID: CheckedContinuation<Void, any Error>])
    case finished
  }

  private let lock = NSLock()
  private var phase = Phase.waiting([:])

  package func wait() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result: Result<Void, any Error>? = lock.withLock {
          if Task.isCancelled { return .failure(CancellationError()) }
          guard case .waiting(var waiters) = phase else { return .success(()) }
          waiters[id] = continuation
          phase = .waiting(waiters)
          return nil
        }
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      let continuation = self.lock.withLock { () -> CheckedContinuation<Void, any Error>? in
        guard case .waiting(var waiters) = self.phase else { return nil }
        let continuation = waiters.removeValue(forKey: id)
        self.phase = .waiting(waiters)
        return continuation
      }
      continuation?.resume(throwing: CancellationError())
    }
    try Task.checkCancellation()
  }

  package func finish() {
    let pending = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
      guard case .waiting(let waiters) = phase else { return [] }
      phase = .finished
      return Array(waiters.values)
    }
    pending.forEach { $0.resume() }
  }
}
