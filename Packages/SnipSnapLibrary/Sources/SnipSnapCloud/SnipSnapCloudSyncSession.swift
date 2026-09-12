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
  private let cancelEnableAction: SyncedContentSettingsModel.CancelEnableAction
  private let disableAction: SyncedContentSettingsModel.DisableAction
  private let deleteAction: DeleteAction
  private let libraryAction: LibraryAction
  private let automaticErrorHandler: @Sendable (any Error) async -> Void
  private enum RequestKind: Int {
    case schedule, synchronize, retry
  }
  private struct Request {
    let id: UUID
    let kind: RequestKind
  }
  private var requests: [Request] = []
  private var requestWaiters: [UUID: CheckedContinuation<SnipSnapCloudSyncResult, any Error>] = [:]
  private var processingRequests = false
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
    enqueue(Request(id: UUID(), kind: .schedule))
  }

  public func enableICloudSync() async throws -> SyncedContentEnableOutcome {
    try await operationGate.withLease(enableAction)
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

  private func request(_ kind: RequestKind) async throws -> SnipSnapCloudSyncResult {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        requestWaiters[id] = continuation
        enqueue(Request(id: id, kind: kind))
      }
    } onCancel: {
      Task { await self.cancelRequest(id) }
    }
  }

  private func enqueue(_ request: Request) {
    requests.append(request)
    guard !processingRequests else { return }
    processingRequests = true
    Task { await runRequests() }
  }

  private func cancelRequest(_ id: UUID) {
    requests.removeAll { $0.id == id }
    requestWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  private func runRequests() async {
    while !requests.isEmpty {
      let batch = requests
      requests = []
      let kind = batch.map(\.kind).max { $0.rawValue < $1.rawValue }!
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
        if batch.contains(where: { $0.kind == .schedule }) {
          await automaticErrorHandler(error)
        }
      }
      for request in batch {
        requestWaiters.removeValue(forKey: request.id)?.resume(with: result)
      }
    }
    processingRequests = false
  }

}
