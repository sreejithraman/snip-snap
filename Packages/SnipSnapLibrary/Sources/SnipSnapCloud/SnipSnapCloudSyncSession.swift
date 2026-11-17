import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// Orders app requests and coalesces normal sync work before it reaches CloudKit.
public actor SnipSnapCloudSyncSession {
  package typealias DeleteAction = @Sendable () async throws -> SyncedContentDeleteOutcome
  package typealias SynchronizeAction = @Sendable () async throws -> SnipSnapCloudSyncResult
  package typealias DeliveryAction = @Sendable () async throws -> SnipSnapCloudSyncDelivery
  package typealias ScheduleAction = @Sendable () async throws -> Void
  package typealias LibraryAction = @Sendable () async throws -> SnipSnapCloudActiveLibrary

  private let synchronizeAction: DeliveryAction
  private let retryAction: DeliveryAction
  private let scheduleAction: ScheduleAction
  private let enableDeliveryAction: (@Sendable () async throws -> SnipSnapCloudEnableDelivery)?
  private let enableAction: SyncedContentSettingsModel.EnableAction
  private let cancelEnableAction: SyncedContentSettingsModel.CancelEnableAction
  private let disableAction: SyncedContentSettingsModel.DisableAction
  private let deleteAction: DeleteAction
  private let libraryAction: LibraryAction
  private let applicationTargetAction: (@Sendable () async throws -> SnipSnapCloudApplicationTarget?)?
  private let automaticErrorHandler: @Sendable (any Error) async -> Void
  private enum RequestKind: Int {
    case schedule, synchronize, retry
  }
  private typealias RequestWaiter = CheckedContinuation<SnipSnapCloudSyncDelivery, any Error>
  private struct SyncRequest {
    let id: UUID
    let kind: RequestKind
    /// Scheduled sync has no caller to answer.
    let waiter: RequestWaiter?
  }
  /// One run of sync work and the callers it answers.
  private struct RequestBatch {
    let kind: RequestKind
    /// Scheduled sync joined this run, so a failure also goes to the automatic error handler.
    let includesAutomaticSync: Bool
    var waiting: [SyncRequest]
  }
  /// One drain runs at a time. Requests that arrive during a batch wait together for the next one.
  private enum RequestQueue {
    case idle
    case draining(queued: [SyncRequest])
    case running(RequestBatch, queued: [SyncRequest])

    /// Returns true when this request starts a drain.
    mutating func enqueue(_ request: SyncRequest) -> Bool {
      switch self {
      case .idle:
        self = .draining(queued: [request])
        return true
      case .draining(var queued):
        queued.append(request)
        self = .draining(queued: queued)
        return false
      case .running(let batch, var queued):
        queued.append(request)
        self = .running(batch, queued: queued)
        return false
      }
    }

    /// Releases a waiting caller. Work already running continues for the rest of its batch.
    mutating func cancel(_ id: UUID) -> RequestWaiter? {
      switch self {
      case .idle:
        return nil
      case .draining(var queued):
        let waiter = Self.removeWaiter(id, from: &queued)
        self = .draining(queued: queued)
        return waiter
      case .running(var batch, var queued):
        if let waiter = Self.removeWaiter(id, from: &batch.waiting) {
          self = .running(batch, queued: queued)
          return waiter
        }
        let waiter = Self.removeWaiter(id, from: &queued)
        self = .running(batch, queued: queued)
        return waiter
      }
    }

    /// Takes every queued request into one batch, or ends the drain when none remain.
    mutating func startBatch() -> RequestBatch? {
      guard case .draining(let queued) = self else { return nil }
      guard let kind = queued.map(\.kind).max(by: { $0.rawValue < $1.rawValue }) else {
        self = .idle
        return nil
      }
      let batch = RequestBatch(
        kind: kind,
        includesAutomaticSync: queued.contains { $0.kind == .schedule },
        waiting: queued.filter { $0.waiter != nil }
      )
      self = .running(batch, queued: [])
      return batch
    }

    /// Returns the batch's remaining waiters in queue order.
    mutating func finishBatch() -> [RequestWaiter] {
      guard case .running(let batch, let queued) = self else { return [] }
      self = .draining(queued: queued)
      return batch.waiting.compactMap(\.waiter)
    }

    var queuedCount: Int {
      switch self {
      case .idle: 0
      case .draining(let queued), .running(_, let queued): queued.count
      }
    }

    private static func removeWaiter(
      _ id: UUID, from requests: inout [SyncRequest]
    ) -> RequestWaiter? {
      guard let index = requests.firstIndex(where: { $0.id == id }) else { return nil }
      return requests.remove(at: index).waiter
    }
  }
  private var requestQueue = RequestQueue.idle
  private let operationGate: AsyncOperationGate
  public nonisolated let automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult>
  public nonisolated let automaticSyncDeliveries: AsyncStream<SnipSnapCloudSyncDelivery>

  package init(
    coordinator: CloudCollectionCoordinator,
    persistence: SwiftDataSyncModePersistence,
    operationGate: AsyncOperationGate = AsyncOperationGate(),
    automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult> = AsyncStream { $0.finish() }
  ) {
    self.operationGate = operationGate
    self.automaticSyncResults = automaticSyncResults
    automaticSyncDeliveries = AsyncStream { $0.finish() }
    automaticErrorHandler = { _ in }
    applicationTargetAction = {
      let selected = try await persistence.snapshot().activeStore
      return SnipSnapCloudApplicationTarget(persistence: persistence, store: selected)
    }
    enableDeliveryAction = {
      let delivery = try await coordinator.enableSyncWithTarget()
      return SnipSnapCloudEnableDelivery(outcome: .enabled, target: delivery.target)
    }
    synchronizeAction = {
      let delivery = try await coordinator.synchronizeWithTarget()
      return SnipSnapCloudSyncDelivery(result: syncResult(for: delivery.status), target: delivery.target)
    }
    retryAction = {
      let delivery = try await coordinator.retrySynchronizationWithTarget()
      return SnipSnapCloudSyncDelivery(result: syncResult(for: delivery.status), target: delivery.target)
    }
    scheduleAction = {}
    enableAction = {
      _ = try await coordinator.enableSync()
      return .enabled
    }
    cancelEnableAction = {}
    disableAction = { _ in throw CloudCollectionError.noActiveCollection }
    deleteAction = { deleteOutcome(for: try await coordinator.deleteSyncedContent()) }
    libraryAction = {
      let snapshot = try await persistence.snapshot()
      return SnipSnapCloudActiveLibrary(
        library: try await persistence.activeLibrary(),
        recoveryScope: SnipRecoveryScopeFactory.scope(
          forActiveCloudNamespace: snapshot.activeStore.namespace
        )
      )
    }
  }

  package init(
    synchronize: @escaping SynchronizeAction,
    retry: SynchronizeAction? = nil,
    synchronizeWithTarget: DeliveryAction? = nil,
    retryWithTarget: DeliveryAction? = nil,
    scheduleAutomaticSync: @escaping ScheduleAction = {},
    enable: @escaping SyncedContentSettingsModel.EnableAction,
    enableWithTarget: (@Sendable () async throws -> SnipSnapCloudEnableDelivery)? = nil,
    cancelEnable: @escaping SyncedContentSettingsModel.CancelEnableAction = {},
    disable: @escaping SyncedContentSettingsModel.DisableAction = { _ in
      throw CloudCollectionError.noActiveCollection
    },
    delete: @escaping DeleteAction,
    activeLibrary: @escaping LibraryAction,
    applicationTarget: (@Sendable () async throws -> SnipSnapCloudApplicationTarget?)? = nil,
    operationGate: AsyncOperationGate = AsyncOperationGate(),
    automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult> = AsyncStream { $0.finish() },
    automaticSyncDeliveries: AsyncStream<SnipSnapCloudSyncDelivery>? = nil,
    automaticErrorHandler: @escaping @Sendable (any Error) async -> Void = { _ in }
  ) {
    self.operationGate = operationGate
    if let automaticSyncDeliveries {
      self.automaticSyncDeliveries = automaticSyncDeliveries
      let projection = LegacyAutomaticResults(automaticSyncDeliveries)
      self.automaticSyncResults = AsyncStream(unfolding: { await projection.next() })
    } else {
      self.automaticSyncResults = automaticSyncResults
      self.automaticSyncDeliveries = AsyncStream { $0.finish() }
    }
    let actualSync: DeliveryAction = synchronizeWithTarget ?? { .unavailable(try await synchronize()) }
    synchronizeAction = actualSync
    if let retryWithTarget { retryAction = retryWithTarget }
    else if let retry { retryAction = { .unavailable(try await retry()) } }
    else { retryAction = actualSync }
    scheduleAction = scheduleAutomaticSync
    enableAction = enable
    enableDeliveryAction = enableWithTarget
    cancelEnableAction = cancelEnable
    disableAction = disable
    deleteAction = delete
    libraryAction = activeLibrary
    applicationTargetAction = applicationTarget
    self.automaticErrorHandler = automaticErrorHandler
  }

  public func synchronize() async throws -> SnipSnapCloudSyncResult {
    try await request(.synchronize).result
  }

  public func retrySynchronization() async throws -> SnipSnapCloudSyncResult {
    try await request(.retry).result
  }

  public func synchronizeWithTarget() async throws -> SnipSnapCloudSyncDelivery {
    try await request(.synchronize)
  }

  public func retrySynchronizationWithTarget() async throws -> SnipSnapCloudSyncDelivery {
    try await request(.retry)
  }

  public func scheduleAutomaticSync() {
    enqueue(SyncRequest(id: UUID(), kind: .schedule, waiter: nil))
  }

  public func enableICloudSync() async throws -> SyncedContentEnableOutcome {
    try await operationGate.withLease(enableAction)
  }

  public func enableICloudSyncWithTarget() async throws -> SnipSnapCloudEnableDelivery {
    guard let enableDeliveryAction else {
      return SnipSnapCloudEnableDelivery(outcome: try await operationGate.withLease(enableAction), target: nil)
    }
    return try await operationGate.withLease(enableDeliveryAction)
  }

  public func cancelICloudSyncSetup() async throws {
    try await operationGate.withLease(cancelEnableAction)
  }

  public func disableICloudSync(_ choice: SyncedContentDisableChoice) async throws {
    try await operationGate.withLease { [disableAction] in try await disableAction(choice) }
  }

  public func deleteSyncedContent() async throws -> SyncedContentDeleteOutcome {
    try await operationGate.withLease(deleteAction)
  }

  public func activeLibrary() async throws -> SnipSnapCloudActiveLibrary {
    try await operationGate.withLease(libraryAction)
  }

  public func currentApplicationTarget() async throws -> SnipSnapCloudApplicationTarget? {
    guard let applicationTargetAction else { return nil }
    return try await operationGate.withLease(applicationTargetAction)
  }

  /// Requests waiting for the next batch, not counting the batch that is running.
  var queuedRequestCount: Int { requestQueue.queuedCount }

  private func request(_ kind: RequestKind) async throws -> SnipSnapCloudSyncDelivery {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { waiter in
        enqueue(SyncRequest(id: id, kind: kind, waiter: waiter))
      }
    } onCancel: {
      Task { await self.cancelRequest(id) }
    }
  }

  private func enqueue(_ request: SyncRequest) {
    guard requestQueue.enqueue(request) else { return }
    Task { await drainRequests() }
  }

  private func cancelRequest(_ id: UUID) {
    requestQueue.cancel(id)?.resume(throwing: CancellationError())
  }

  private func drainRequests() async {
    while let batch = requestQueue.startBatch() {
      let kind = batch.kind
      let result: Result<SnipSnapCloudSyncDelivery, any Error>
      do {
        let value = try await operationGate.withLease { [synchronizeAction, retryAction, scheduleAction] in
          switch kind {
          case .schedule:
            try await scheduleAction()
            return SnipSnapCloudSyncDelivery.unavailable(.noChange)
          case .synchronize:
            return try await synchronizeAction()
          case .retry:
            return try await retryAction()
          }
        }
        result = .success(value)
      } catch {
        result = .failure(error)
        if batch.includesAutomaticSync {
          await automaticErrorHandler(error)
        }
      }
      for waiter in requestQueue.finishBatch() {
        waiter.resume(with: result)
      }
    }
  }

}

// Pull projection over the same stream; no second buffer, producer task, or backend queue.
private actor LegacyAutomaticResults {
  private var iterator: AsyncStream<SnipSnapCloudSyncDelivery>.Iterator?
  init(_ stream: AsyncStream<SnipSnapCloudSyncDelivery>) { iterator = stream.makeAsyncIterator() }
  func next() async -> SnipSnapCloudSyncResult? {
    guard var current = iterator else { return nil }
    iterator = nil
    let value = await current.next(isolation: self)
    iterator = current
    return value?.result
  }
}
