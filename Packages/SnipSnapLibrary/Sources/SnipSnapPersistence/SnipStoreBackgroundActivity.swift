import Foundation
import Synchronization

/// Keeps iOS execution time tied to one synchronous store operation.
final class SnipStoreBackgroundActivity: Sendable {
  typealias End = @Sendable () -> Void
  typealias Runner = @Sendable (@escaping @Sendable () -> Void) -> End

  // Task-local injection keeps concurrent tests and separate stores independent.
  @TaskLocal static var runner: Runner? = platformRunner

  private static var platformRunner: Runner? {
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
  static func runExpiringActivity(
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
    let expired = Mutex(false)
  }

  private let expiration: Expiration
  private let ended = Mutex(false)
  private let end: End

  private init(expiration: Expiration, end: @escaping End) {
    self.expiration = expiration
    self.end = end
  }

  static func begin() throws -> SnipStoreBackgroundActivity? {
    guard let runner else { return nil }
    let expiration = Expiration()
    let end = runner { expiration.expired.withLock { $0 = true } }
    let activity = SnipStoreBackgroundActivity(expiration: expiration, end: end)
    do {
      try activity.check()
      return activity
    } catch {
      activity.finish()
      throw error
    }
  }

  deinit { finish() }

  func check() throws {
    if expiration.expired.withLock({ $0 }) { throw CancellationError() }
  }

  func finish() {
    let shouldEnd = ended.withLock { ended in
      guard !ended else { return false }
      ended = true
      return true
    }
    if shouldEnd { end() }
  }
}
