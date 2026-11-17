import Foundation
import SnipSnapCore

/// Publishes CLI admission only after the app has checked and adopted its active library.
@MainActor
public final class SnipCLIAppLifecycle {
  public typealias Reconcile = @MainActor @Sendable () async throws -> String
  public typealias CheckedReconcile = @MainActor @Sendable () async throws -> (scope: String, publication: SnipLibraryReadPublication?)
  public typealias ScheduleSync = @MainActor @Sendable () async -> Void

  private struct Handlers {
    let reconcile: CheckedReconcile
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

  private struct ReadinessCompletion: Sendable {
    let result: Result<String, any Error>
    let target: SnipLibraryApplicationTarget?

    func scope(for requested: SnipLibraryApplicationTarget? = nil) throws -> String {
      if let requested, target !== requested { throw SnipLibraryReadPublicationError.revoked }
      return try result.get()
    }
  }

  private enum ReadinessCheck {
    case idle
    case running(id: UUID, task: Task<ReadinessCompletion, Never>, rerunRequested: Bool)

    var task: Task<ReadinessCompletion, Never>? {
      guard case .running(_, let task, _) = self else { return nil }
      return task
    }

    /// Asks the running check for another pass and returns the task to join.
    mutating func requestRerun() -> (id: UUID, task: Task<ReadinessCompletion, Never>)? {
      guard case .running(let id, let task, _) = self else { return nil }
      self = .running(id: id, task: task, rerunRequested: true)
      return (id, task)
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
  private var requestedReconcile: CheckedReconcile?
  private var requestedTarget: SnipLibraryApplicationTarget?
  private var activeTarget: SnipLibraryApplicationTarget?
  private var readinessWaiters: [UUID: (check: UUID, target: SnipLibraryApplicationTarget?, continuation: AsyncThrowingStream<String, any Error>.Continuation)] = [:]
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
    phase = .started(Handlers(reconcile: { (try await reconcile(), nil) }, scheduleSync: scheduleSync))
    try await refresh()
  }

  public func start(reconcileChecked: @escaping CheckedReconcile, scheduleSync: @escaping ScheduleSync) async throws {
    guard case .awaitingStart = phase else { throw SnipCLIAppReadinessError.unavailable }
    phase = .started(Handlers(reconcile: reconcileChecked, scheduleSync: scheduleSync))
    try await refresh()
  }

  public func refresh() async throws {
    let check = try await requestReadinessCheck()
    _ = try await check.task.value.scope()
  }

  public func refreshAndReturnScope() async throws -> String {
    try Task.checkCancellation()
    let check = try await requestReadinessCheck()
    return try await waitForReadiness(id: check.id, task: check.task)
  }

  public func refreshAndReturnScope(reconcile: @escaping CheckedReconcile) async throws -> String {
    try Task.checkCancellation()
    requestedReconcile = reconcile
    requestedTarget = nil
    let check = try await requestReadinessCheck()
    return try await waitForReadiness(id: check.id, task: check.task)
  }

  public func refreshAndReturnScope(
    for target: SnipLibraryApplicationTarget, reconcile: @escaping CheckedReconcile
  ) async throws -> String {
    try Task.checkCancellation()
    if (activeTarget === target && requestedReconcile == nil) || requestedTarget === target,
      case .running(let id, let task, _) = readinessCheck {
      return try await waitForReadiness(id: id, task: task, target: target)
    }
    requestedTarget = target
    requestedReconcile = reconcile
    let check = try await requestReadinessCheck()
    return try await waitForReadiness(id: check.id, task: check.task, target: target)
  }

  private func requestReadinessCheck() async throws -> (id: UUID, task: Task<ReadinessCompletion, Never>) {
    guard let handlers = phase.handlers else { throw SnipCLIAppReadinessError.unavailable }
    if let joined = readinessCheck.requestRerun() {
      try await store.suspendActiveScope()
      return joined
    }
    // Read before the task runs: termination may replace the phase first.
    let needsAppSession = if case .started = phase { true } else { false }
    let id = UUID()
    let task = Task { @MainActor [self] in
      let result: Result<String, any Error>
      do {
        result = .success(try await checkReadiness(id: id, handlers: handlers, needsAppSession: needsAppSession))
      } catch {
        result = .failure(error)
      }
      let completion = ReadinessCompletion(result: result, target: activeTarget)
      finishReadiness(id: id, completion: completion)
      return completion
    }
    readinessCheck = .running(id: id, task: task, rerunRequested: false)
    return (id, task)
  }

  private func checkReadiness(id: UUID, handlers: Handlers, needsAppSession: Bool) async throws -> String {
    if needsAppSession {
      try await store.beginAppSession(instance)
      if case .started(let handlers) = phase { phase = .inAppSession(handlers) }
    }
    let publishedScope: String
    while true {
      try Task.checkCancellation()
      guard !isTerminated else { throw SnipCLIAppReadinessError.unavailable }
      readinessCheck.beginPass(id)
      let reconcile = requestedReconcile ?? handlers.reconcile
      activeTarget = requestedTarget
      requestedTarget = nil
      requestedReconcile = nil
      let revision = try await store.beginReadinessCheck()
      let checked: (scope: String, publication: SnipLibraryReadPublication?)
      do { checked = try await reconcile() }
      catch {
        if readinessCheck.isRerunRequested(id) { continue }
        throw error
      }
      let token = checked.scope
      try Task.checkCancellation()
      guard !isTerminated else { throw SnipCLIAppReadinessError.unavailable }
      if readinessCheck.isRerunRequested(id) { continue }
      let accepted: Bool
      do {
        accepted = try await store.publishActiveScopeToken(token, ifUnchangedSince: revision, publication: checked.publication)
      } catch {
        if readinessCheck.isRerunRequested(id) { continue }
        throw error
      }
      if readinessCheck.isRerunRequested(id) || !accepted { continue }
      publishedScope = token
      break
    }
    if !isTerminated, case .idle = syncScheduling {
      let syncID = UUID()
      let syncWork = Task { @MainActor [self] in
        defer { syncScheduling.end(syncID) }
        guard !isTerminated, !Task.isCancelled else { return }
        await handlers.scheduleSync()
      }
      syncScheduling = .scheduling(id: syncID, task: syncWork)
    }
    return publishedScope
  }

  private func waitForReadiness(
    id: UUID, task: Task<ReadinessCompletion, Never>, target: SnipLibraryApplicationTarget? = nil
  ) async throws -> String {
    try Task.checkCancellation()
    guard case .running(id, _, _) = readinessCheck else { return try await task.value.scope(for: target) }
    let waiterID = UUID()
    let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
    readinessWaiters[waiterID] = (id, target, continuation)
    defer { readinessWaiters.removeValue(forKey: waiterID)?.continuation.finish() }
    var iterator = stream.makeAsyncIterator()
    let token = try await iterator.next()
    try Task.checkCancellation()
    guard let token else { throw SnipCLIAppReadinessError.unavailable }
    return token
  }

  private func finishReadiness(id: UUID, completion: ReadinessCompletion) {
    readinessCheck.end(id)
    activeTarget = nil
    let waiters = readinessWaiters.filter { $0.value.check == id }
    for (waiterID, waiter) in waiters {
      readinessWaiters.removeValue(forKey: waiterID)
      do {
        waiter.continuation.yield(try completion.scope(for: waiter.target))
        waiter.continuation.finish()
      } catch {
        waiter.continuation.finish(throwing: error)
      }
    }
  }

  public func beginTermination() {
    requestedReconcile = nil
    requestedTarget = nil
    phase = .terminated
    readinessCheck.task?.cancel()
    let waiters = readinessWaiters.values.map(\.continuation)
    readinessWaiters.removeAll()
    for waiter in waiters { waiter.finish(throwing: CancellationError()) }
    syncScheduling.task?.cancel()
  }

  public func stop() async throws {
    beginTermination()
    try await store.endAppSession()
  }
}
