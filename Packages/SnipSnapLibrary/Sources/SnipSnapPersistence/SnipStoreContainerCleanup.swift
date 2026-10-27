import Synchronization

/// Closing a SwiftData container can checkpoint SQLite even after its last read.
enum SnipStoreContainerCleanup {
  private static let pending = Mutex<[any AnyObject & Sendable]>([])

  static func release<Resource: AnyObject & Sendable>(_ container: inout Resource?) {
    guard container != nil else { return }
    do {
      let activity = try SnipStoreBackgroundActivity.begin()
      defer { activity?.finish() }
      try activity?.check()
      container = nil
    } catch {
      // An idle connection can wait; starting a checkpoint without time cannot.
      if let container { pending.withLock { $0.append(container) } }
      container = nil
    }
  }

  static func drain(while activity: SnipStoreBackgroundActivity) {
    while true {
      var container = pending.withLock { $0.popLast() }
      guard container != nil else { return }
      do {
        try activity.check()
      } catch {
        if let container { pending.withLock { $0.append(container) } }
        return
      }
      // Release outside the queue mutex and before ending execution protection.
      container = nil
    }
  }
}
