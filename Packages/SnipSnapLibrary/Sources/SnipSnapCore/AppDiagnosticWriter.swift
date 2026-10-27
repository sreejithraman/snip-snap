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
    var loss = false
    var occurrences: [AppDiagnosticOccurrence] = []

    var priority: Int {
      switch event.outcome {
      case .failed: 2
      case .missing, .cancelled: 1
      case .started, .succeeded: 0
      }
    }
  }

  private let trace: RuntimeTrace.Span
  private let store: AppDiagnosticEventStore
  private let requiresReadableControls: Bool
  private let capacity: Int
  private let scheduleRetry: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
  private let queue = DispatchQueue(label: "SnipSnap.diagnostic-writer", qos: .utility)
  private let lock = NSLock()
  private let logger = Logger(subsystem: "SnipSnap", category: "Operations")
  private var pending: [Submission] = []
  private var losses: [String: Submission] = [:]
  private var pendingOccurrences = 0
  private static let occurrenceCapacity = 2_048
  private static let lossOccurrenceCapacity = 64
  // Loss totals use lock; reporting cursors and retry attempts belong to queue.
  private var droppedOccurrences = 0
  private var uncertainOccurrences = 0
  private var reportedDropped = 0
  private var reportedUncertain = 0
  private var retryAttempts = 0
  private var scheduled = false
  // Queue-owned batch; a busy store retains it for the next finite retry.
  // Together with pending, at most 2 * capacity + 6 envelopes and
  // 2 * occurrenceCapacity exact event times and 6 * lossOccurrenceCapacity
  // loss chunks are retained. Loss chunks compact an old prefix, never a tail.
  private var batch: [Submission] = []
  private var retryDelay: TimeInterval = 0.05

  init(
    store: AppDiagnosticEventStore, capacity: Int = 128, requiresReadableControls: Bool = false,
    scheduleRetry: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil,
    runtimeTrace: RuntimeTrace = .live
  ) {
    trace = runtimeTrace.span(.writer)
    self.store = store
    self.requiresReadableControls = requiresReadableControls
    self.capacity = max(1, min(capacity, 256))
    self.scheduleRetry =
      scheduleRetry ?? { delay, run in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: run)
      }
  }

  func submit(_ event: AppDiagnosticEvent, at date: Date = Date()) {
    let stamp = AppDiagnosticSubmissionStamp.capture()
    lock.withLock {
      if let index = pending.indices.last, pending[index].event == event,
        date >= pending[index].last, date.timeIntervalSince(pending[index].first) < 60,
        pendingOccurrences < Self.occurrenceCapacity
      {
        pending[index].last = date
        pending[index].occurrences.append(.init(stamp: stamp, date: date))
        pendingOccurrences += 1
        return
      }
      let submission = Submission(
        event: event, first: date, last: date,
        occurrences: [.init(stamp: stamp, date: date)])
      if pending.count == capacity || pendingOccurrences == Self.occurrenceCapacity {
        if let victim = pending.firstIndex(where: { $0.priority < submission.priority }) {
          let omitted = pending.remove(at: victim)
          pendingOccurrences -= omitted.occurrences.count
          accountForLoss(omitted)
        } else {
          accountForLoss(submission)
          scheduleLocked()
          return
        }
      }
      pending.append(submission)
      pendingOccurrences += 1
      scheduleLocked()
    }
  }

  func perform<T>(_ operation: () throws -> T) throws -> T {
    try queue.sync {
      try drain()
      return try operation()
    }
  }

  func flush(timeout: TimeInterval) async -> Bool {
    guard timeout.isFinite, timeout > 0, !Task.isCancelled else { return false }
    let duration = min(timeout, 2)
    let request = DrainRequest()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        request.install(continuation)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + duration) {
          request.finish(false)
        }
        queue.async { self.flushAttempt(request) }
      }
    } onCancel: {
      request.finish(false)
    }
  }

  private func flushAttempt(_ request: DrainRequest) {
    guard request.isPending else { return }
    do {
      try drain(shouldContinue: { request.isPending })
      request.finish(true)
    } catch AppDiagnosticAccessError.busy {
      noteDeferredAttempt()
      queue.asyncAfter(deadline: .now() + 0.01) { self.flushAttempt(request) }
    } catch {
      request.finish(false)
    }
  }

  private final class DrainRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    var isPending: Bool { lock.withLock { result == nil } }
    func install(_ continuation: CheckedContinuation<Bool, Never>) {
      let finished = lock.withLock { () -> Bool? in
        if let result { return result }
        self.continuation = continuation
        return nil
      }
      if let finished { continuation.resume(returning: finished) }
    }
    func finish(_ value: Bool) {
      let waiting = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
        guard result == nil else { return nil }
        result = value
        let waiting = continuation
        continuation = nil
        return waiting
      }
      waiting?.resume(returning: value)
    }
  }

  private func scheduleLocked() {
    guard !scheduled else { return }
    scheduled = true
    queue.async { self.pump() }
  }

  /// Caller holds lock. Each of three fixed categories keeps a bounded exact
  /// tail and a counted prefix. Counts remain exact unless a control cuts that prefix.
  private func accountForLoss(_ submission: Submission, code: String? = nil) {
    let code =
      code
      ?? (submission.priority > 0 ? "diagnostics.failureOverflow" : "diagnostics.routineOverflow")
    let occurrences = submission.occurrences.reduce(0) { $0 + $1.count }
    if code == "diagnostics.writeFailed" { uncertainOccurrences += occurrences }
    else { droppedOccurrences += occurrences }
    var loss = losses.removeValue(forKey: code) ?? Submission(
      event: .failure(
        operation: "diagnostics.recording", errorCode: code, visibility: .background),
      first: submission.first, last: submission.last, loss: true)
    for occurrence in submission.occurrences {
      if loss.occurrences.count == Self.lossOccurrenceCapacity {
        let oldest = loss.occurrences.removeFirst()
        loss.occurrences[0].merge(oldest)
      }
      loss.occurrences.append(occurrence)
    }
    losses[code] = loss
  }

  private func drain(shouldContinue: () -> Bool = { true }) throws {
    try drainBatch(shouldContinue: shouldContinue)
    guard shouldContinue() else { throw CancellationError() }
    // Freeze a finite batch. New submissions stay behind this operation, so a
    // continuous storm cannot indefinitely postpone clear/toggle/export.
    batch = lock.withLock {
      let result = pending + losses.keys.sorted().compactMap { losses[$0] }
      pending.removeAll(keepingCapacity: true)
      pendingOccurrences = 0
      losses.removeAll(keepingCapacity: true)
      return result
    }
    try drainBatch(shouldContinue: shouldContinue)
    reportLossIfChanged()
    if retryAttempts > 0 {
      reportHealth(.writerRecovered)
      retryAttempts = 0
    }
  }

  private func drainBatch(shouldContinue: () -> Bool) throws {
    while let submission = batch.first {
      guard shouldContinue() else { throw CancellationError() }
      var attemptedAppend = false
      do {
        if requiresReadableControls, try !store.readRecordingEnabled() {
          batch.removeFirst()
          continue
        }
        attemptedAppend = true
        try store.appendThrowing(submission.event, occurrences: submission.occurrences)
        retryDelay = 0.05
        batch.removeFirst()
      } catch AppDiagnosticAccessError.busy {
        throw AppDiagnosticAccessError.busy
      } catch {
        if requiresReadableControls {
          // Unknown shared controls cannot authorize later persistence or loss replay.
          let discarded = batch.filter { !$0.loss }.reduce(0) {
            $0 + $1.occurrences.reduce(0) { $0 + $1.count }
          }
          batch.removeAll(keepingCapacity: true)
          lock.withLock {
            if attemptedAppend, !submission.loss {
              uncertainOccurrences += submission.occurrences.reduce(0) { $0 + $1.count }
            }
            droppedOccurrences += discarded + pending.reduce(0) {
              $0 + $1.occurrences.reduce(0) { $0 + $1.count }
            }
            pending.removeAll(keepingCapacity: true)
            losses.removeAll(keepingCapacity: true)
            pendingOccurrences = 0
          }
          logger.error("Shared diagnostic persistence failed; queued events discarded.")
          throw error
        }
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
      noteDeferredAttempt()
      let delay = retryDelay
      retryDelay = min(5, retryDelay * 2)
      scheduleRetry(delay) { self.queue.async { self.pump() } }
    }
  }

  private func noteDeferredAttempt() {
    retryAttempts += 1
    reportLossIfChanged()
    // Geometric milestones bound trace volume during a persistent denial.
    if retryAttempts.nonzeroBitCount == 1 { reportHealth(.writerDeferred) }
  }

  private func reportLossIfChanged() {
    let counts = lock.withLock { (droppedOccurrences, uncertainOccurrences) }
    guard counts.0 != reportedDropped || counts.1 != reportedUncertain else { return }
    reportedDropped = counts.0
    reportedUncertain = counts.1
    reportHealth(.writerLoss)
  }

  private func reportHealth(_ phase: RuntimeTrace.Phase) {
    let counts = lock.withLock { (pending.count + losses.count, droppedOccurrences, uncertainOccurrences) }
    trace.health(phase, queued: batch.count + counts.0, retries: retryAttempts,
      dropped: counts.1, uncertain: counts.2)
  }
}
