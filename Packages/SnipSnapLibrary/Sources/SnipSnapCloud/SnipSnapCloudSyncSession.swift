import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// One app-owned lane for normal sync, enabling sync, and deleting synced content.
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
  private var automaticScheduleRequested = false
  private var automaticScheduleTask: Task<Void, Never>?
  public nonisolated let automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult>

  package init(
    coordinator: CloudCollectionCoordinator,
    persistence: SwiftDataSyncModePersistence,
    automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult> = AsyncStream { $0.finish() }
  ) {
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
    automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult> = AsyncStream { $0.finish() },
    automaticErrorHandler: @escaping @Sendable (any Error) async -> Void = { _ in }
  ) {
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
    try await synchronizeAction()
  }
  public func retrySynchronization() async throws -> SnipSnapCloudSyncResult {
    try await retryAction()
  }
  public func scheduleAutomaticSync() {
    automaticScheduleRequested = true
    guard automaticScheduleTask == nil else { return }
    automaticScheduleTask = Task { [weak self] in
      await self?.runAutomaticScheduleLoop()
    }
  }
  public func enableICloudSync() async throws -> SyncedContentEnableOutcome {
    try await enableAction()
  }
  public func cancelICloudSyncSetup() async throws {
    try await cancelEnableAction()
  }
  public func disableICloudSync(_ choice: SyncedContentDisableChoice) async throws {
    try await disableAction(choice)
  }
  public func deleteSyncedContent() async throws -> SyncedContentDeleteOutcome {
    try await deleteAction()
  }
  public func activeLibrary() async throws -> SnipSnapCloudActiveLibrary {
    try await libraryAction()
  }
  private func runAutomaticScheduleLoop() async {
    while automaticScheduleRequested {
      automaticScheduleRequested = false
      do {
        try await scheduleAction()
      } catch {
        await automaticErrorHandler(error)
      }
    }
    automaticScheduleTask = nil
  }
}
