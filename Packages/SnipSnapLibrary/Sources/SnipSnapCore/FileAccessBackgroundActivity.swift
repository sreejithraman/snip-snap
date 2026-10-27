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
    struct State: Sendable {
      var expired = false
      var admitted = false
      var finished = false
    }
    let state = Mutex(State())
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
      let admitted = expiration.state.withLock { state in
        guard !state.expired, !state.finished else { return false }
        state.expired = true
        return state.admitted
      }
      if admitted { trace?.mark(.protectionExpired) }
    }
    let activity = FileAccessBackgroundActivity(expiration: expiration, end: end, trace: trace)
    let admitted = expiration.state.withLock { state in
      state.admitted = !state.expired
      return state.admitted
    }
    trace?.mark(admitted ? .protectionGranted : .protectionDenied)
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
    if expiration.state.withLock({ $0.expired }) { throw CancellationError() }
  }

  package func finish() {
    let shouldEnd = expiration.state.withLock { state in
      guard !state.finished else { return false }
      state.finished = true
      return true
    }
    if shouldEnd {
      end()
      trace?.mark(.protectionEnded)
    }
  }
}
