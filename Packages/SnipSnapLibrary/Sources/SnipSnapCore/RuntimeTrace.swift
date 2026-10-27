import Foundation
import OSLog
import Synchronization

/// App state for system traces; independent of an operation's diagnostic visibility.
public enum AppRuntimeTrace {
  public enum State: String, Sendable {
    case unknown, launching, active, inactive, background
  }

  public static func applicationState(_ state: State, protectedDataAvailable: Bool) {
    RuntimeTrace.context.withLock {
      $0.state = state
      $0.protectedDataAvailable = protectedDataAvailable
    }
    RuntimeTrace.live.emit(.init(component: .application, phase: .applicationState))
  }

  public static func protectedDataWillBecomeUnavailable(currentlyAvailable: Bool) {
    RuntimeTrace.context.withLock { $0.protectedDataAvailable = currentlyAvailable }
    RuntimeTrace.live.emit(.init(component: .application, phase: .protectedDataWillBecomeUnavailable))
  }

  public static func protectedDataAvailability(_ available: Bool) {
    RuntimeTrace.context.withLock { $0.protectedDataAvailable = available }
    RuntimeTrace.live.emit(.init(component: .application, phase: .protectedDataChanged))
  }
}

/// Production traces use only OSLog, independently of diagnostic history.
package struct RuntimeTrace: Sendable {
  package enum Component: String, Sendable { case application, diagnostics, database, writer }
  package enum Operation: String, Sendable {
    case access, append, read, export, clear, recording, migration, containerCleanup
  }
  package enum Phase: String, Sendable {
    case applicationState, protectedDataChanged, protectedDataWillBecomeUnavailable
    case protectionRequested, protectionGranted, protectionDenied, protectionExpired, protectionEnded
    case lockWaiting, lockAcquired, lockReleased, accessEnded
    case cleanupStarted, cleanupEnded, migrationStarted, migrationEnded
    case shareCleanupStarted, shareCleanupEnded
    case writerDeferred, writerRecovered, writerLoss
  }
  struct Context: Sendable {
    var state: AppRuntimeTrace.State = .unknown
    var protectedDataAvailable: Bool?
  }
  static let context = Mutex(Context())
  private static let sequence = Mutex<UInt64>(0)
  private static let session = UUID().uuidString
  private static let version = AppDiagnosticRecord.safeVersion(
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
  private static let build = AppDiagnosticRecord.safeVersion(
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
  private static let logger = Logger(subsystem: "SnipSnap", category: "Runtime")

  package struct Event: Sendable {
    package let component: Component
    package let phase: Phase
    package var operation: Operation? = nil
    package var id: UInt64? = nil
    package var elapsedMilliseconds: Double? = nil
    package var waitMilliseconds: Double? = nil
    package var holdMilliseconds: Double? = nil
    package var queued: Int? = nil
    package var retries: Int? = nil
    package var dropped: Int? = nil
    package var uncertain: Int? = nil
    package var appState: AppRuntimeTrace.State = .unknown
    package var protectedDataAvailable: Bool? = nil

    var persisted: Bool {
      switch phase {
      case .applicationState, .protectedDataChanged, .protectedDataWillBecomeUnavailable,
        .protectionDenied, .protectionExpired,
        .writerDeferred, .writerRecovered, .writerLoss:
        true
      case .lockAcquired, .lockReleased:
        appState == .background || appState == .inactive
          || (waitMilliseconds ?? 0) >= 1_000 || (holdMilliseconds ?? 0) >= 1_000
      default: false
      }
    }

    var line: String {
      var fields = ["runtime_trace", "session=\(RuntimeTrace.session)",
        "app_version=\(RuntimeTrace.version)", "app_build=\(RuntimeTrace.build)",
        "component=\(component.rawValue)", "phase=\(phase.rawValue)",
        "app_state=\(appState.rawValue)"]
      if let protectedDataAvailable { fields.append("protected_data=\(protectedDataAvailable)") }
      if let operation { fields.append("operation=\(operation.rawValue)") }
      if let id { fields.append("operation_id=\(id)") }
      for (key, value) in [("elapsed_ms", elapsedMilliseconds), ("wait_ms", waitMilliseconds),
        ("hold_ms", holdMilliseconds)] {
        if let value { fields.append("\(key)=\(String(format: "%.3f", value))") }
      }
      for (key, value) in [("queued_submissions", queued), ("retries", retries), ("dropped", dropped),
        ("uncertain", uncertain)] {
        if let value { fields.append("\(key)=\(value)") }
      }
      return fields.joined(separator: " ")
    }
  }

  package static let live = RuntimeTrace { event in
    if event.persisted {
      logger.notice("\(event.line, privacy: .public)")
    } else if logger.isEnabled(type: .debug) {
      logger.debug("\(event.line, privacy: .public)")
    }
  }
  package let sink: @Sendable (Event) -> Void
  package let now: @Sendable () -> TimeInterval

  package init(
    sink: @escaping @Sendable (Event) -> Void,
    now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.sink = sink
    self.now = now
  }

  package func emit(_ value: Event) {
    var event = value
    let context = Self.context.withLock { $0 }
    event.appState = context.state
    event.protectedDataAvailable = context.protectedDataAvailable
    sink(event)
  }

  package func span(_ component: Component, operation: Operation = .access) -> Span {
    Span(trace: self, component: component, operation: operation)
  }

  package final class Span: Sendable {
    private let trace: RuntimeTrace
    private let component: Component
    private let operation: Operation
    private let id: UInt64
    private let started: TimeInterval
    private struct LockTimes: Sendable {
      var waiting: TimeInterval?
      var acquired: TimeInterval?
    }
    private let lockTimes = Mutex(LockTimes())

    init(trace: RuntimeTrace, component: Component, operation: Operation) {
      self.trace = trace
      self.component = component
      self.operation = operation
      id = RuntimeTrace.sequence.withLock { $0 &+= 1; return $0 }
      started = trace.now()
    }

    package func health(_ phase: Phase, queued: Int, retries: Int, dropped: Int, uncertain: Int) {
      trace.emit(.init(component: component, phase: phase, operation: operation, id: id,
        elapsedMilliseconds: max(0, trace.now() - started) * 1_000,
        queued: queued, retries: retries, dropped: dropped, uncertain: uncertain))
    }

    package func mark(_ phase: Phase) {
      trace.emit(.init(component: component, phase: phase, operation: operation, id: id,
        elapsedMilliseconds: max(0, trace.now() - started) * 1_000))
    }

    package func waitingForLock() {
      let now = trace.now()
      lockTimes.withLock { $0.waiting = now }
      mark(.lockWaiting)
    }

    package func acquiredLock() {
      let now = trace.now()
      let waiting = lockTimes.withLock { times in
        times.acquired = now
        return times.waiting ?? now
      }
      trace.emit(.init(component: component, phase: .lockAcquired, operation: operation, id: id,
        elapsedMilliseconds: max(0, now - started) * 1_000,
        waitMilliseconds: max(0, now - waiting) * 1_000))
    }

    package func releasedLock() {
      let now = trace.now()
      let acquired = lockTimes.withLock { $0.acquired ?? now }
      trace.emit(.init(component: component, phase: .lockReleased, operation: operation, id: id,
        elapsedMilliseconds: max(0, now - started) * 1_000,
        holdMilliseconds: max(0, now - acquired) * 1_000))
    }
  }
}
