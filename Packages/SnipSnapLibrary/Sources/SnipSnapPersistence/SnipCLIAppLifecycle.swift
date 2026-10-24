import Foundation

/// Publishes CLI admission only after the app has checked and adopted its active library.
@MainActor
public final class SnipCLIAppLifecycle {
  public typealias Reconcile = @MainActor @Sendable () async throws -> String
  public typealias ScheduleSync = @MainActor @Sendable () async -> Void

  private let store: SnipCLIRequestStore
  private let instance: SnipCLIAppInstance
  private var reconcile: Reconcile?
  private var scheduleSync: ScheduleSync?
  private var refreshTask: Task<Void, any Error>?
  private var syncTask: Task<Void, Never>?
  private var needsAnotherRefresh = false
  private var sessionStarted = false
  private var stopped = false

  public init(store: SnipCLIRequestStore, instance: SnipCLIAppInstance) {
    self.store = store
    self.instance = instance
  }

  public func start(reconcile: @escaping Reconcile, scheduleSync: @escaping ScheduleSync) async throws {
    guard self.reconcile == nil, !stopped else { throw SnipCLIAppReadinessError.unavailable }
    self.reconcile = reconcile
    self.scheduleSync = scheduleSync
    try await refresh()
  }

  public func refresh() async throws {
    guard !stopped, let reconcile else { throw SnipCLIAppReadinessError.unavailable }
    if let refreshTask {
      needsAnotherRefresh = true
      try await store.suspendActiveScope()
      try await refreshTask.value
      return
    }
    let task = Task { @MainActor [self] in
      defer { refreshTask = nil }
      if !sessionStarted {
        try await store.beginAppSession(instance)
        sessionStarted = true
      }
      while true {
        try Task.checkCancellation()
        guard !stopped else { throw SnipCLIAppReadinessError.unavailable }
        needsAnotherRefresh = false
        let revision = try await store.beginReadinessCheck()
        let token = try await reconcile()
        try Task.checkCancellation()
        guard !stopped else { throw SnipCLIAppReadinessError.unavailable }
        if needsAnotherRefresh { continue }
        let published = try await store.publishActiveScopeToken(token, ifUnchangedSince: revision)
        if needsAnotherRefresh || !published { continue }
        break
      }
      guard !stopped, syncTask == nil else { return }
      syncTask = Task { @MainActor [self] in
        defer { syncTask = nil }
        guard !stopped, !Task.isCancelled else { return }
        await scheduleSync?()
      }
    }
    refreshTask = task
    try await task.value
  }

  public func beginTermination() {
    stopped = true
    refreshTask?.cancel()
    syncTask?.cancel()
  }

  public func stop() async throws {
    beginTermination()
    try await store.endAppSession()
  }
}
