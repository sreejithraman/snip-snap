import CloudKit
import Foundation
import SnipSnapCore

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
  private enum Backoff {
    case ready
    case coolingDown(consecutiveTransientFailures: Int, nextAttempt: ContinuousClock.Instant)

    var consecutiveTransientFailures: Int {
      guard case .coolingDown(let failures, _) = self else { return 0 }
      return failures
    }

    var nextAttempt: ContinuousClock.Instant? {
      guard case .coolingDown(_, let nextAttempt) = self else { return nil }
      return nextAttempt
    }
  }

  private let now: @Sendable () -> ContinuousClock.Instant
  private var backoff = Backoff.ready
  private let gate = AsyncOperationGate()
  private let sleep: @Sendable (Duration) async throws -> Void
  private let diagnostics: AppDiagnosticRecorder

  package init(
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    diagnostics: AppDiagnosticRecorder = .live
  ) {
    self.now = now
    self.sleep = sleep
    self.diagnostics = diagnostics
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
      while let nextAttempt = backoff.nextAttempt, nextAttempt > now() {
        try await sleep(now().duration(to: nextAttempt))
      }
      try Task.checkCancellation()
      do {
        let value = try await operation()
        backoff = .ready
        return value
      } catch {
        let transient = CloudKitRetryPolicy.isTransient(error)
        let failures = transient
          ? min(backoff.consecutiveTransientFailures + 1, 7)
          : backoff.consecutiveTransientFailures
        let delay = CloudKitRetryPolicy.delay(after: error, attempt: failures)
        if let delay {
          let deadline = now().advanced(by: delay)
          backoff = .coolingDown(
            consecutiveTransientFailures: failures,
            nextAttempt: max(backoff.nextAttempt ?? deadline, deadline)
          )
        }
        CloudSyncDiagnostics.recordRetry(error, operation: operationName,
          selectedDelay: delay, nextAttemptIn: backoff.nextAttempt.map { max(.zero, now().duration(to: $0)) },
          diagnostics: diagnostics)
        guard transient, attempt < 3 else { throw error }
        attempt += 1
      }
    }
  }

}
