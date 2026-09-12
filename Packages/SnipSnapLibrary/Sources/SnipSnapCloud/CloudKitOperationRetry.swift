import CloudKit
import Foundation

package enum CloudKitRetryPolicy {
  package static func isTransient(_ error: Error) -> Bool {
    guard let error = error as? CKError else { return false }
    if error.code == .partialFailure {
      guard let itemErrors = error.partialErrorsByItemID?.values,
        !itemErrors.isEmpty
      else { return false }
      return itemErrors.allSatisfy(isTransient)
    }
    return isTransient(error.code)
  }

  package static func isTransient(_ code: CKError.Code) -> Bool {
    switch code {
    case .networkFailure, .networkUnavailable, .requestRateLimited,
         .serviceUnavailable, .zoneBusy, .serverResponseLost:
      true
    default:
      false
    }
  }

  package static func delay(
    after error: Error,
    attempt: Int
  ) -> Duration? {
    if let delay = serverDelay(after: error) { return delay }
    guard isTransient(error) else { return nil }
    return .seconds(1 << (min(7, max(1, attempt)) - 1))
  }

  private static func serverDelay(after error: Error) -> Duration? {
    guard let error = error as? CKError else { return nil }
    var delays = error.partialErrorsByItemID?.values.compactMap { serverDelay(after: $0) } ?? []
    if let number = error.userInfo[CKErrorRetryAfterKey] as? NSNumber,
      number.doubleValue.isFinite,
      number.doubleValue >= 0,
      number.doubleValue < Double(Int64.max / 1_000)
    {
      delays.append(.seconds(number.doubleValue))
    }
    return delays.max()
  }
}

/// Owns retry timing for direct CloudKit work outside CKSyncEngine.
package actor CloudKitOperationRetry {
  private let now: @Sendable () -> ContinuousClock.Instant
  private var nextAttempt: ContinuousClock.Instant?
  private var consecutiveFailures = 0
  private let gate = AsyncOperationGate()
  private let sleep: @Sendable (Duration) async throws -> Void

  package init(
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.now = now
    self.sleep = sleep
  }

  package func run<Value: Sendable>(
    operationName: String = "direct CloudKit request",
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    try await gate.withLease { try await self.runSerially(operationName: operationName, operation) }
  }

  private func runSerially<Value: Sendable>(
    operationName: String,
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    var attempt = 1
    while true {
      try Task.checkCancellation()
      while let nextAttempt, nextAttempt > now() {
        try await sleep(now().duration(to: nextAttempt))
      }
      try Task.checkCancellation()
      do {
        let value = try await operation()
        consecutiveFailures = 0
        return value
      } catch {
        let transient = CloudKitRetryPolicy.isTransient(error)
        if transient { consecutiveFailures = min(consecutiveFailures + 1, 7) }
        let delay = CloudKitRetryPolicy.delay(after: error, attempt: consecutiveFailures)
        if let delay {
          let deadline = now().advanced(by: delay)
          nextAttempt = max(nextAttempt ?? deadline, deadline)
        }
        CloudSyncDiagnostics.recordRetry(error, operation: operationName,
          selectedDelay: delay, nextAttemptIn: nextAttempt.map { max(.zero, now().duration(to: $0)) })
        guard transient, attempt < 3 else { throw error }
        attempt += 1
      }
    }
  }

}
