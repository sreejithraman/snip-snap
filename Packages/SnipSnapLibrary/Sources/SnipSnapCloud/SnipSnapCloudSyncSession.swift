import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// One app-owned lane for normal sync, enabling sync, and deleting synced content.
public actor SnipSnapCloudSyncSession {
  package typealias DeleteAction = @Sendable () async throws -> SyncedContentDeleteOutcome
  package typealias SynchronizeAction = @Sendable () async throws -> SnipSnapCloudSyncResult
  package typealias LibraryAction = @Sendable () async throws -> SnipSnapCloudActiveLibrary
  package typealias EncryptedDataResetAction = @Sendable (
    EncryptedDataResetChoice
  ) async throws -> SnipSnapCloudSyncResult

  private let synchronizeAction: SynchronizeAction
  private let enableAction: SyncedContentSettingsModel.EnableAction
  private let cancelEnableAction: SyncedContentSettingsModel.CancelEnableAction
  private let disableAction: SyncedContentSettingsModel.DisableAction
  private let deleteAction: DeleteAction
  private let libraryAction: LibraryAction
  private let encryptedDataResetAction: EncryptedDataResetAction

  package init(
    coordinator: CloudCollectionCoordinator,
    persistence: SwiftDataSyncModePersistence
  ) {
    synchronizeAction = {
      syncResult(for: try await coordinator.synchronize())
    }
    enableAction = {
      _ = try await coordinator.enableSync()
      return .enabled
    }
    cancelEnableAction = {}
    disableAction = { _ in throw CloudCollectionError.noActiveCollection }
    deleteAction = { deleteOutcome(for: try await coordinator.deleteSyncedContent()) }
    encryptedDataResetAction = { choice in
      syncResult(for: try await coordinator.resolveEncryptedDataReset(choice))
    }
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
    enable: @escaping SyncedContentSettingsModel.EnableAction,
    cancelEnable: @escaping SyncedContentSettingsModel.CancelEnableAction = {},
    disable: @escaping SyncedContentSettingsModel.DisableAction = { _ in
      throw CloudCollectionError.noActiveCollection
    },
    delete: @escaping DeleteAction,
    activeLibrary: @escaping LibraryAction,
    resolveEncryptedDataReset: @escaping EncryptedDataResetAction = { _ in
      throw CloudCollectionError.noActiveCollection
    }
  ) {
    synchronizeAction = synchronize
    enableAction = enable
    cancelEnableAction = cancelEnable
    disableAction = disable
    deleteAction = delete
    libraryAction = activeLibrary
    encryptedDataResetAction = resolveEncryptedDataReset
  }

  public func synchronize() async throws -> SnipSnapCloudSyncResult {
    try await synchronizeAction()
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
  public func resolveEncryptedDataReset(
    _ choice: EncryptedDataResetChoice
  ) async throws -> SnipSnapCloudSyncResult {
    try await encryptedDataResetAction(choice)
  }
}
