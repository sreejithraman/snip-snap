import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// Orders app requests and coalesces normal sync work before it reaches CloudKit.
public actor SnipSnapCloudSyncSession {
  package typealias DeleteAction = @Sendable () async throws -> SyncedContentDeleteOutcome
  package typealias SynchronizeAction = @Sendable () async throws -> SnipSnapCloudSyncResult
  package typealias ScheduleAction = @Sendable () async throws -> Void
  package typealias LibraryAction = @Sendable () async throws -> SnipSnapCloudActiveLibrary

  private let synchronizeAction: SynchronizeAction
  private let retryAction: SynchronizeAction
  private let scheduleAction: ScheduleAction
  private let enableAction: SyncedContentSettingsModel.EnableAction
  private let acknowledgeEnableAction: @Sendable (ICloudSyncNamespaceBinding) async throws -> Void
  private let cancelEnableAction: SyncedContentSettingsModel.CancelEnableAction
  private let disableAction: SyncedContentSettingsModel.DisableAction
  private let deleteAction: DeleteAction
  private let libraryAction: LibraryAction
  private let automaticErrorHandler: @Sendable (any Error) async -> Void
  private enum RequestKind: Int {
    case schedule, synchronize, retry
  }
  private typealias RequestWaiter = CheckedContinuation<SnipSnapCloudSyncResult, any Error>
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

  package init(
    coordinator: CloudCollectionCoordinator,
    persistence: SwiftDataSyncModePersistence,
    operationGate: AsyncOperationGate = AsyncOperationGate(),
    automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult> = AsyncStream { $0.finish() }
  ) {
    self.operationGate = operationGate
    self.automaticSyncResults = automaticSyncResults
    automaticErrorHandler = { _ in }
    synchronizeAction = {
      syncResult(for: try await coordinator.synchronize())
    }
    retryAction = {
      syncResult(for: try await coordinator.retrySynchronization())
    }
    scheduleAction = {}
    enableAction = {
      _ = try await coordinator.enableSync()
      return .enabled
    }
    acknowledgeEnableAction = { _ in }
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
    scheduleAutomaticSync: @escaping ScheduleAction = {},
    enable: @escaping SyncedContentSettingsModel.EnableAction,
    acknowledgeEnable: @escaping @Sendable (ICloudSyncNamespaceBinding) async throws -> Void = { _ in },
    cancelEnable: @escaping SyncedContentSettingsModel.CancelEnableAction = {},
    disable: @escaping SyncedContentSettingsModel.DisableAction = { _ in
      throw CloudCollectionError.noActiveCollection
    },
    delete: @escaping DeleteAction,
    activeLibrary: @escaping LibraryAction,
    operationGate: AsyncOperationGate = AsyncOperationGate(),
    automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult> = AsyncStream { $0.finish() },
    automaticErrorHandler: @escaping @Sendable (any Error) async -> Void = { _ in }
  ) {
    self.operationGate = operationGate
    self.automaticSyncResults = automaticSyncResults
    synchronizeAction = synchronize
    retryAction = retry ?? synchronize
    scheduleAction = scheduleAutomaticSync
    enableAction = enable
    acknowledgeEnableAction = acknowledgeEnable
    cancelEnableAction = cancelEnable
    disableAction = disable
    deleteAction = delete
    libraryAction = activeLibrary
    self.automaticErrorHandler = automaticErrorHandler
  }

  public func synchronize() async throws -> SnipSnapCloudSyncResult {
    try await request(.synchronize)
  }

  public func retrySynchronization() async throws -> SnipSnapCloudSyncResult {
    try await request(.retry)
  }

  public func scheduleAutomaticSync() {
    enqueue(SyncRequest(id: UUID(), kind: .schedule, waiter: nil))
  }

  public func enableICloudSync() async throws -> SyncedContentEnableOutcome {
    try await operationGate.withLease(enableAction)
  }

  public func acknowledgeDeferredEnableCompletion(for binding: ICloudSyncNamespaceBinding) async throws {
    try await operationGate.withLease { [acknowledgeEnableAction] in try await acknowledgeEnableAction(binding) }
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

  /// Requests waiting for the next batch, not counting the batch that is running.
  var queuedRequestCount: Int { requestQueue.queuedCount }

  private func request(_ kind: RequestKind) async throws -> SnipSnapCloudSyncResult {
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
      let result: Result<SnipSnapCloudSyncResult, any Error>
      do {
        let value = try await operationGate.withLease { [synchronizeAction, retryAction, scheduleAction] in
          switch kind {
          case .schedule:
            try await scheduleAction()
            return SnipSnapCloudSyncResult.noChange
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
