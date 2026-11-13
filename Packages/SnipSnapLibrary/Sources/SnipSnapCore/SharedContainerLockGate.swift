import Synchronization

/// Admits locks on App Group files only while the owner says the process cannot be suspended.
///
/// iOS terminates a suspended app that holds such a lock (`0xdead10cc`). An expiring activity
/// requested after a background wake does not prevent that suspension, so the iOS app closes
/// this gate before it becomes eligible and opens it when it is active again.
public final class SharedContainerLockGate: Sendable {
  public static let process = SharedContainerLockGate()

  private struct State {
    var isOpen = true
    var holders = 0
    var whenReleased: [@Sendable () -> Void] = []
  }

  private let state = Mutex(State())

  public init() {}

  public func open() {
    state.withLock { $0.isOpen = true }
  }

  /// Stops new admissions. `whenReleased` runs after every current holder releases its lock.
  public func close(whenReleased: @escaping @Sendable () -> Void = {}) {
    let released = state.withLock { state in
      state.isOpen = false
      guard state.holders > 0 else { return true }
      state.whenReleased.append(whenReleased)
      return false
    }
    if released { whenReleased() }
  }

  /// Returns nil while closed. Release the admission only after unlocking.
  public func admit() -> Admission? {
    let admitted = state.withLock { state in
      guard state.isOpen else { return false }
      state.holders += 1
      return true
    }
    return admitted ? Admission(gate: self) : nil
  }

  fileprivate func release() {
    let callbacks = state.withLock { state -> [@Sendable () -> Void] in
      state.holders -= 1
      guard state.holders == 0 else { return [] }
      defer { state.whenReleased.removeAll() }
      return state.whenReleased
    }
    for callback in callbacks { callback() }
  }

  public final class Admission: Sendable {
    private let gate: SharedContainerLockGate
    private let released = Mutex(false)

    fileprivate init(gate: SharedContainerLockGate) {
      self.gate = gate
    }

    deinit { release() }

    public func release() {
      let first = released.withLock { released in
        defer { released = true }
        return !released
      }
      if first { gate.release() }
    }
  }
}
