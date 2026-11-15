import Foundation
import Synchronization

/// Keeps iOS execution time tied to one synchronous file operation.
package final class FileAccessBackgroundActivity: Sendable {
  package typealias End = @Sendable () -> Void
  package typealias Runner = @Sendable (@escaping @Sendable () -> Void) -> End

  package static var platformRunner: Runner? {
    #if os(iOS)
    { expire in
      runExpiringActivity(expire: expire) { body in
        ProcessInfo.processInfo.performExpiringActivity(
          withReason: "Snip Snap store access", using: body
        )
      }
    }
    #else
    nil
    #endif
  }

  // Foundation schedules the work on a concurrent queue. Adapt its two
  // callbacks to a scope which ends only after the caller releases its lock.
  package static func runExpiringActivity(
    expire: @escaping @Sendable () -> Void,
    schedule: (@escaping @Sendable (Bool) -> Void) -> Void
  ) -> End {
    let admitted = DispatchSemaphore(value: 0)
    let completion = DispatchGroup()
    completion.enter()
    schedule { expired in
      if expired { expire() }
      admitted.signal()
      completion.wait()
    }
    admitted.wait()
    return { completion.leave() }
  }

  private final class Expiration: Sendable {
    private enum Phase: Sendable {
      case requested
      case granted
      /// Foundation expired the request before it answered admission.
      case denied
      case expired
      case ended(expired: Bool)

      var isExpired: Bool {
        switch self {
        case .requested, .granted: false
        case .denied, .expired: true
        case .ended(let expired): expired
        }
      }
    }

    private let state = Mutex(Phase.requested)

    var isExpired: Bool { state.withLock { $0.isExpired } }

    /// Returns true only when expiry ends granted protection.
    func expire() -> Bool {
      state.withLock { phase in
        switch phase {
        case .requested:
          phase = .denied
          return false
        case .granted:
          phase = .expired
          return true
        case .denied, .expired, .ended:
          return false
        }
      }
    }

    func resolveAdmission() -> Bool {
      state.withLock { phase in
        guard case .requested = phase else { return !phase.isExpired }
        phase = .granted
        return true
      }
    }

    /// Returns true only for the first call.
    func finish() -> Bool {
      state.withLock { phase in
        if case .ended = phase { return false }
        phase = .ended(expired: phase.isExpired)
        return true
      }
    }
  }

  private let expiration: Expiration
  private let end: End
  private let trace: RuntimeTrace.Span?

  private init(expiration: Expiration, end: @escaping End, trace: RuntimeTrace.Span?) {
    self.expiration = expiration
    self.end = end
    self.trace = trace
  }

  package static func begin(
    runner: Runner?, trace: RuntimeTrace.Span? = nil
  ) throws -> FileAccessBackgroundActivity? {
    guard let runner else { return nil }
    trace?.mark(.protectionRequested)
    let expiration = Expiration()
    let end = runner {
      if expiration.expire() { trace?.mark(.protectionExpired) }
    }
    let activity = FileAccessBackgroundActivity(expiration: expiration, end: end, trace: trace)
    trace?.mark(expiration.resolveAdmission() ? .protectionGranted : .protectionDenied)
    do {
      try activity.check()
      return activity
    } catch {
      activity.finish()
      throw error
    }
  }

  deinit { finish() }

  package func check() throws {
    if expiration.isExpired { throw CancellationError() }
  }

  package func finish() {
    if expiration.finish() {
      end()
      trace?.mark(.protectionEnded)
    }
  }
}
