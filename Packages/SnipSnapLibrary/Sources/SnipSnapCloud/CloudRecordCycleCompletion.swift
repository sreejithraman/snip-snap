import Foundation

/// One completion shared by overlapping engine cycles and their explicit callers.
/// Cancelling a caller does not cancel CloudKit's work or release other callers.
package final class CloudRecordCycleCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

  package func wait() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result: Result<Void, any Error>? = lock.withLock {
          if Task.isCancelled { return .failure(CancellationError()) }
          if completed { return .success(()) }
          waiters[id] = continuation
          return nil
        }
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      let continuation = self.lock.withLock { self.waiters.removeValue(forKey: id) }
      continuation?.resume(throwing: CancellationError())
    }
    try Task.checkCancellation()
  }

  package func finish() {
    let pending = lock.withLock {
      completed = true
      let pending = Array(waiters.values)
      waiters.removeAll()
      return pending
    }
    pending.forEach { $0.resume() }
  }
}
