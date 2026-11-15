import CloudKit
import Foundation
import Synchronization

/// Limits how long one direct CloudKit call may run. CloudKit ends a call after `idle` without
/// data or after its kind's total. A read also has a backstop in case CloudKit ignores its
/// configuration or a cancel.
package struct CloudKitCallBound: Sendable {
  package enum Kind: Sendable {
    /// Account checks, small records, and zone changes.
    case small
    /// Any call that moves a file, such as an attachment or clipboard asset.
    case transfer
  }

  package let idle: Duration
  package let smallTotal: Duration
  package let transferTotal: Duration
  package let backstopMargin: Duration

  package static let standard = CloudKitCallBound(
    idle: .seconds(30),
    smallTotal: .seconds(60),
    transferTotal: .seconds(10 * 60),
    backstopMargin: .seconds(15)
  )

  package init(
    idle: Duration,
    smallTotal: Duration,
    transferTotal: Duration,
    backstopMargin: Duration
  ) {
    self.idle = idle
    self.smallTotal = smallTotal
    self.transferTotal = transferTotal
    self.backstopMargin = backstopMargin
  }

  package func configuration(_ kind: Kind) -> CKOperation.Configuration {
    let configuration = CKOperation.Configuration()
    configuration.timeoutIntervalForRequest = idle.timeInterval
    configuration.timeoutIntervalForResource = total(kind).timeInterval
    configuration.qualityOfService = .userInitiated
    return configuration
  }

  /// Returns `operation`'s result or error, or throws `networkFailure` once the kind's total
  /// plus the margin passes. The caller's cancel reaches `operation`, but the caller still waits
  /// for one of those two. The backstop cancels `operation`; if it runs on anyway, its late
  /// result is dropped. `operation` must only read, so an abandoned call changes nothing.
  package func read<Value: Sendable>(
    _ kind: Kind,
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let limit = total(kind) + backstopMargin
    let call = CallTask()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let outcome = FirstOutcome(continuation)
        let timer = Task {
          try await Task.sleep(for: limit)
          outcome.resolve(.failure(CKError(.networkFailure)))
          call.cancel()
        }
        call.attach(Task {
          let result: Result<Value, any Error>
          do {
            result = .success(try await operation())
          } catch {
            result = .failure(error)
          }
          timer.cancel()
          outcome.resolve(result)
        })
      }
    } onCancel: {
      call.cancel()
    }
  }

  private func total(_ kind: Kind) -> Duration {
    switch kind {
    case .small: smallTotal
    case .transfer: transferTotal
    }
  }
}

/// Cancels a call's task, even when the cancel comes before the task exists.
private final class CallTask: Sendable {
  private struct State {
    var task: Task<Void, Never>?
    var cancelled = false
  }

  private let state = Mutex(State())

  func attach(_ task: Task<Void, Never>) {
    let cancelled = state.withLock { state in
      state.task = task
      return state.cancelled
    }
    if cancelled { task.cancel() }
  }

  func cancel() {
    let task = state.withLock { state in
      state.cancelled = true
      return state.task
    }
    task?.cancel()
  }
}

/// Resumes its continuation with the first result only.
private final class FirstOutcome<Value: Sendable>: Sendable {
  private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

  init(_ continuation: CheckedContinuation<Value, any Error>) {
    self.continuation = Mutex(continuation)
  }

  func resolve(_ result: Result<Value, any Error>) {
    continuation.withLock { $0.take() }?.resume(with: result)
  }
}

private extension Duration {
  var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
