import Foundation

/// Publishes CLI admission only after the app has checked and adopted its active library.
@MainActor
public final class SnipCLIAppLifecycle {
  public typealias Reconcile = @MainActor @Sendable () async throws -> String
  public typealias ScheduleSync = @MainActor @Sendable () async -> Void

  private struct Handlers {
    let reconcile: Reconcile
    let scheduleSync: ScheduleSync
  }

  private enum Phase {
    case awaitingStart
    /// The app session marker is not written yet, or writing it failed.
    case started(Handlers)
    case inAppSession(Handlers)
    case terminated

    var handlers: Handlers? {
      switch self {
      case .started(let handlers), .inAppSession(let handlers): handlers
      case .awaitingStart, .terminated: nil
      }
    }
  }

  private enum ReadinessCheck {
    case idle
    case running(id: UUID, task: Task<Void, any Error>, rerunRequested: Bool)

    var task: Task<Void, any Error>? {
      guard case .running(_, let task, _) = self else { return nil }
      return task
    }

    /// Asks the running check for another pass and returns the task to join.
    mutating func requestRerun() -> Task<Void, any Error>? {
      guard case .running(let id, let task, _) = self else { return nil }
      self = .running(id: id, task: task, rerunRequested: true)
      return task
    }

    mutating func beginPass(_ id: UUID) {
      guard case .running(id, let task, _) = self else { return }
      self = .running(id: id, task: task, rerunRequested: false)
    }

    func isRerunRequested(_ id: UUID) -> Bool {
      guard case .running(id, _, let rerunRequested) = self else { return false }
      return rerunRequested
    }

    mutating func end(_ id: UUID) {
      guard case .running(id, _, _) = self else { return }
      self = .idle
    }
  }

  private enum SyncScheduling {
    case idle
    case scheduling(id: UUID, task: Task<Void, Never>)

    var task: Task<Void, Never>? {
      guard case .scheduling(_, let task) = self else { return nil }
      return task
    }

    mutating func end(_ id: UUID) {
      guard case .scheduling(id, _) = self else { return }
      self = .idle
    }
  }

  private let store: SnipCLIRequestStore
  private let instance: SnipCLIAppInstance
  private var phase = Phase.awaitingStart
  private var readinessCheck = ReadinessCheck.idle
  private var syncScheduling = SyncScheduling.idle

  private var isTerminated: Bool {
    if case .terminated = phase { true } else { false }
  }

  public init(store: SnipCLIRequestStore, instance: SnipCLIAppInstance) {
    self.store = store
    self.instance = instance
  }

  public func start(reconcile: @escaping Reconcile, scheduleSync: @escaping ScheduleSync) async throws {
    guard case .awaitingStart = phase else { throw SnipCLIAppReadinessError.unavailable }
    phase = .started(Handlers(reconcile: reconcile, scheduleSync: scheduleSync))
    try await refresh()
  }

  public func refresh() async throws {
    guard let handlers = phase.handlers else { throw SnipCLIAppReadinessError.unavailable }
    if let joined = readinessCheck.requestRerun() {
      try await store.suspendActiveScope()
      try await joined.value
      return
    }
    // Read before the task runs: termination may replace the phase first.
    let needsAppSession = if case .started = phase { true } else { false }
    let id = UUID()
    let task = Task { @MainActor [self] in
      defer { readinessCheck.end(id) }
      if needsAppSession {
        try await store.beginAppSession(instance)
        if case .started(let handlers) = phase { phase = .inAppSession(handlers) }
      }
      while true {
        try Task.checkCancellation()
        guard !isTerminated else { throw SnipCLIAppReadinessError.unavailable }
        readinessCheck.beginPass(id)
        let revision = try await store.beginReadinessCheck()
        let token = try await handlers.reconcile()
        try Task.checkCancellation()
        guard !isTerminated else { throw SnipCLIAppReadinessError.unavailable }
        if readinessCheck.isRerunRequested(id) { continue }
        let published = try await store.publishActiveScopeToken(token, ifUnchangedSince: revision)
        if readinessCheck.isRerunRequested(id) || !published { continue }
        break
      }
      guard !isTerminated, case .idle = syncScheduling else { return }
      let syncID = UUID()
      let syncWork = Task { @MainActor [self] in
        defer { syncScheduling.end(syncID) }
        guard !isTerminated, !Task.isCancelled else { return }
        await handlers.scheduleSync()
      }
      syncScheduling = .scheduling(id: syncID, task: syncWork)
    }
    readinessCheck = .running(id: id, task: task, rerunRequested: false)
    try await task.value
  }

  public func beginTermination() {
    phase = .terminated
    readinessCheck.task?.cancel()
    syncScheduling.task?.cancel()
  }

  public func stop() async throws {
    beginTermination()
    try await store.endAppSession()
  }
}
