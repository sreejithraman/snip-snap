import Dispatch
import Foundation
import OSLog

/// One pump owns disk I/O. Submission holds only a short memory lock, never the
/// storage lock. Read/control operations flush submissions on the same queue.
final class AppDiagnosticWriter: @unchecked Sendable {
  private struct Submission {
    var event: AppDiagnosticEvent
    var first: Date
    var last: Date
    var count = 1
    var loss = false

    var priority: Int {
      switch event.outcome {
      case .failed: 2
      case .missing, .cancelled: 1
      case .started, .succeeded: 0
      }
    }
  }

  private let store: AppDiagnosticEventStore
  private let capacity: Int
  private let scheduleRetry: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
  private let queue = DispatchQueue(label: "SnipSnap.diagnostic-writer", qos: .utility)
  private let lock = NSLock()
  private let logger = Logger(subsystem: "SnipSnap", category: "Operations")
  private var pending: [Submission] = []
  private var losses: [String: Submission] = [:]
  private var scheduled = false
  // Queue-owned batch; a busy store retains it for the next finite retry.
  // Together with pending, at most 2 * capacity + 6 envelopes are retained.
  private var batch: [Submission] = []
  private var retryDelay: TimeInterval = 0.05

  init(
    store: AppDiagnosticEventStore, capacity: Int = 128,
    scheduleRetry: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil
  ) {
    self.store = store
    self.capacity = max(1, min(capacity, 256))
    self.scheduleRetry =
      scheduleRetry ?? { delay, run in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: run)
      }
  }

  func submit(_ event: AppDiagnosticEvent, at date: Date = Date()) {
    lock.withLock {
      let submission = Submission(event: event, first: date, last: date)
      if let last = pending.last, last.event == event, date >= last.last,
        date.timeIntervalSince(last.first) < 60, last.count < Int.max
      {
        pending[pending.count - 1].last = date
        pending[pending.count - 1].count += 1
        return
      }
      if pending.count == capacity {
        if let victim = pending.firstIndex(where: { $0.priority < submission.priority }) {
          accountForLoss(pending.remove(at: victim))
        } else {
          accountForLoss(submission)
          scheduleLocked()
          return
        }
      }
      pending.append(submission)
      scheduleLocked()
    }
  }

  func perform<T>(_ operation: () throws -> T) throws -> T {
    try queue.sync {
      try drain()
      return try operation()
    }
  }

  private func scheduleLocked() {
    guard !scheduled else { return }
    scheduled = true
    queue.async { self.pump() }
  }

  /// Caller holds lock. There are only three fixed loss categories, independent
  /// of the size of a storm. Their counts survive even if every slot is occupied.
  private func accountForLoss(_ submission: Submission, code: String? = nil) {
    let code =
      code
      ?? (submission.priority > 0 ? "diagnostics.failureOverflow" : "diagnostics.routineOverflow")
    if var loss = losses[code] {
      loss.first = min(loss.first, submission.first)
      loss.last = max(loss.last, submission.last)
      loss.count = Self.add(loss.count, submission.count)
      losses[code] = loss
    } else {
      losses[code] = Submission(
        event: .failure(
          operation: "diagnostics.recording", errorCode: code, visibility: .background),
        first: submission.first, last: submission.last, count: submission.count, loss: true)
    }
  }

  private static func add(_ lhs: Int, _ rhs: Int) -> Int {
    lhs > Int.max - rhs ? Int.max : lhs + rhs
  }

  private func drain() throws {
    try drainBatch()
    // Freeze a finite batch. New submissions stay behind this operation, so a
    // continuous storm cannot indefinitely postpone clear/toggle/export.
    batch = lock.withLock {
      let result = pending + losses.keys.sorted().compactMap { losses[$0] }
      pending.removeAll(keepingCapacity: true)
      losses.removeAll(keepingCapacity: true)
      return result
    }
    try drainBatch()
  }

  private func drainBatch() throws {
    while let submission = batch.first {
      do {
        try store.appendThrowing(
          submission.event, at: submission.last,
          count: submission.count, first: submission.first)
        retryDelay = 0.05
        batch.removeFirst()
      } catch AppDiagnosticAccessError.busy {
        throw AppDiagnosticAccessError.busy
      } catch {
        // A write can fail after partial persistence. Do not replay it and risk
        // inflating repeats. Record the number of uncertain writes on recovery.
        if !submission.loss {
          batch.removeFirst()
          lock.withLock { accountForLoss(submission, code: "diagnostics.writeFailed") }
          logger.error("Local diagnostic write failed; events may be missing.")
        }
        throw error
      }
    }
  }

  private func pump() {
    do {
      try drain()
      lock.withLock {
        if pending.isEmpty && losses.isEmpty {
          scheduled = false
        } else {
          queue.async { self.pump() }
        }
      }
    } catch {
      // Short initial retry for reader contention; persistent permission/disk
      // failures back off to one attempt per five seconds. Progress resets it.
      let delay = retryDelay
      retryDelay = min(5, retryDelay * 2)
      scheduleRetry(delay) { self.queue.async { self.pump() } }
    }
  }
}
