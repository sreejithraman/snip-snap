import Foundation
import SnipSnapCore

/// Keeps iOS execution time tied to one synchronous store operation.
final class SnipStoreBackgroundActivity: Sendable {
  typealias End = FileAccessBackgroundActivity.End
  typealias Runner = FileAccessBackgroundActivity.Runner

  @TaskLocal static var runner: Runner? = FileAccessBackgroundActivity.platformRunner

  private let activity: FileAccessBackgroundActivity

  private init(activity: FileAccessBackgroundActivity) {
    self.activity = activity
  }

  static func runExpiringActivity(
    expire: @escaping @Sendable () -> Void,
    schedule: (@escaping @Sendable (Bool) -> Void) -> Void
  ) -> End {
    FileAccessBackgroundActivity.runExpiringActivity(expire: expire, schedule: schedule)
  }

  static func begin(
    trace: RuntimeTrace.Span = RuntimeTrace.live.span(.database, operation: .containerCleanup)
  ) throws -> SnipStoreBackgroundActivity? {
    guard let activity = try FileAccessBackgroundActivity.begin(runner: runner, trace: trace) else { return nil }
    let scope = SnipStoreBackgroundActivity(activity: activity)
    do {
      SnipStoreContainerCleanup.drain(while: scope)
      try scope.check()
      return scope
    } catch {
      scope.finish()
      throw error
    }
  }

  func check() throws { try activity.check() }

  func finish() { activity.finish() }
}
