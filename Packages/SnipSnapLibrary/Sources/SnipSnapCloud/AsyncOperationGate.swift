import Foundation

/// Holds one operation at a time across suspension points, in arrival order.
/// Cancellation removes a waiting caller; an active operation releases on return.
package actor AsyncOperationGate {
  private var occupied = false
  private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []

  package func withLease<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    let id = UUID()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      if occupied {
        try await withCheckedThrowingContinuation { continuation in
          waiters.append((id, continuation))
        }
      } else {
        occupied = true
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
    defer {
      if waiters.isEmpty {
        occupied = false
      } else {
        waiters.removeFirst().1.resume()
      }
    }
    try Task.checkCancellation()
    return try await operation()
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
    waiters.remove(at: index).1.resume(throwing: CancellationError())
  }
}
