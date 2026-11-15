import Foundation
import SnipSnapPersistence
import Synchronization

/// Fails an Apple Account isolation's pointer-swap commit the way a full disk would. During
/// isolation, the next manifest write after the store-retirement hook is that commit. Unarmed,
/// it writes like production.
final class AccountIsolationSwapFault: Sendable {
  enum Failure: Error { case injected }

  private struct Plan {
    var failsNextSwap = false
    var failsNextWrite = false
  }

  private let plan = Mutex(Plan())

  func failNextSwap() {
    plan.withLock { $0.failsNextSwap = true }
  }

  func arm(_ point: SyncModeWritePoint) {
    guard point == .beforeStoreRetirement else { return }
    plan.withLock { plan in
      guard plan.failsNextSwap else { return }
      plan.failsNextSwap = false
      plan.failsNextWrite = true
    }
  }

  func write(_ data: Data, to url: URL) throws {
    let fails = plan.withLock { plan in
      defer { plan.failsNextWrite = false }
      return plan.failsNextWrite
    }
    if fails { throw Failure.injected }
    try DurableFile.write(data, to: url)
  }
}
