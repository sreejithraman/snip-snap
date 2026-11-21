import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

@MainActor
public struct SnipSnapCloudAppServices {
  public let syncedContentSettings: SyncedContentSettingsModel
  public let syncSession: SnipSnapCloudSyncSession?
  package typealias SyncHandlerFactory = @MainActor (
    SnipSnapCloudSyncHandler.SyncAction?,
    SnipSnapCloudSyncHandler.SyncAction?,
    SnipSnapCloudSyncHandler.SyncAction?
  ) -> SnipSnapCloudSyncHandler
  private let syncHandlerFactory: SyncHandlerFactory?

  package init(
    syncedContentSettings: SyncedContentSettingsModel,
    syncSession: SnipSnapCloudSyncSession?,
    syncHandlerFactory: SyncHandlerFactory? = nil
  ) {
    self.syncedContentSettings = syncedContentSettings
    self.syncSession = syncSession
    self.syncHandlerFactory = syncHandlerFactory
  }

  public func makeCloudSyncHandler(
    syncWhenPossible: @escaping SnipSnapCloudSyncHandler.SyncAction,
    retrySyncWhenPossible: @escaping SnipSnapCloudSyncHandler.SyncAction,
    scheduleSyncAfterLocalChange: @escaping SnipSnapCloudSyncHandler.SyncAction
  ) -> SnipSnapCloudSyncHandler? {
    syncHandlerFactory?(syncWhenPossible, retrySyncWhenPossible, scheduleSyncAfterLocalChange)
  }
}

/// Main-app sync wiring. A blank container keeps a contributor build local-only.
public enum SnipSnapCloudAppAssembly {
  @MainActor
  public static func services(
    rootURL: URL,
    attachmentCacheRootURL: URL? = nil,
    sourceLibrary: (any SnipLibrary)? = nil,
    syncModeStore: SnipSyncModeStore?,
    containerIdentifier: String?
  ) -> SnipSnapCloudAppServices {
    let identifier = containerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !identifier.isEmpty, !identifier.contains("$("), let sourceLibrary else {
      return SnipSnapCloudAppServices(
        syncedContentSettings: SyncedContentSettingsModel(mode: .localOnly),
        syncSession: nil
      )
    }
    let startupState = SyncModeActivationManifestReader.iCloudStartupState(
      atSyncModeRootURL: rootURL
    )
    let settingsStartup = settingsStartupState(rootURL: rootURL, startupState: startupState)
    let namespace = startupState.namespace
    let container = CKContainer(identifier: identifier)
    let database = container.privateCloudDatabase
    let accountStateSource = CloudKitICloudAccountStateSource(container: container)
    let automaticResults = AsyncStream.makeStream(of: SnipSnapCloudSyncResult.self)
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: rootURL,
      attachmentCacheRootURL: attachmentCacheRootURL,
      sourceLibrary: sourceLibrary,
      syncModeStore: syncModeStore,
      cloudScope: namespace?.scope ?? "private",
      accountLineage: namespace?.accountLineage ?? identifier,
      accountStateSource: accountStateSource,
      ownerName: CKCurrentUserDefaultName,
      controlTransport: CloudKitCollectionControlTransport(
        database: database,
        controlID: CloudCollectionAssembly.productionControlID
      ),
      makeRecordTransport: { context in
        CloudKitRecordTransport(
          database: database,
          namespace: context.namespace,
          automaticallyFetchedZones: [context.metadataZone]
        )
      },
      makeDescriptor: {
        CloudCollectionDescriptor.fresh(ownerName: CKCurrentUserDefaultName)
      },
      reservedZones: [CloudCollectionAssembly.productionControlID.zone],
      operationGate: CloudCollectionAssembly.productionOperationGate,
      automaticResultHandler: { result in
        automaticResults.continuation.yield(result)
      }
    )
    let appOperationGate = AsyncOperationGate()
    let session = SnipSnapCloudSyncSession(
      checkActiveAccount: { try await lifecycle.checkActiveAccount() },
      synchronize: { try await lifecycle.synchronize() },
      retry: { try await lifecycle.retrySynchronization() },
      scheduleAutomaticSync: { try await lifecycle.scheduleAutomaticSync() },
      enable: { try await lifecycle.enableICloudSync() },
      cancelEnable: { try await lifecycle.cancelPendingEnable() },
      disable: { choice in try await lifecycle.disableICloudSync(choice) },
      delete: { try await lifecycle.deleteSyncedContent() },
      activeLibrary: { try await lifecycle.activeLibrary() },
      operationGate: appOperationGate,
      automaticSyncResults: automaticResults.stream,
      automaticErrorHandler: { error in
        automaticResults.continuation.yield(automaticSyncResult(for: error))
      }
    )
    let syncHandlerFactory: SnipSnapCloudAppServices.SyncHandlerFactory = { sync, retry, schedule in
      lifecycle.makeCloudSyncHandler(operationGate: appOperationGate,
        syncWhenPossible: sync, retrySyncWhenPossible: retry,
        scheduleSyncAfterLocalChange: schedule)
    }
    return SnipSnapCloudAppServices(
      syncedContentSettings: SyncedContentSettingsModel(
        mode: settingsStartup.mode,
        initialState: settingsStartup.state,
        issueMapper: SnipSnapCloudSyncIssueMapper.issue(for:),
        enableAction: { try await session.enableICloudSync() },
        cancelEnableAction: { try await session.cancelICloudSyncSetup() },
        hasFailedPendingEnable: { hasPendingSetup(rootURL: rootURL) },
        disableAction: { choice in try await session.disableICloudSync(choice) },
        deleteAction: { try await session.deleteSyncedContent() }
      ),
      syncSession: session,
      syncHandlerFactory: syncHandlerFactory
    )
  }

  private static func hasPendingSetup(rootURL: URL) -> Bool {
    switch SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: rootURL) {
    case .settingUp, .needsAttention: true
    case .localOnly: PendingICloudSyncEnable.needsAttention(at: rootURL)
    case .active: false
    }
  }

  package static func settingsStartupState(
    rootURL: URL,
    startupState: SyncModeActivationManifestReader.ICloudStartupState
  ) -> (mode: SyncedContentMode, state: SyncedContentSettingsState) {
    if case .active = startupState { return (.iCloudSync, .ready) }
    if PendingICloudSyncEnable.needsAttention(at: rootURL) {
      return (
        .localOnly,
        .failed(PendingICloudSyncEnable.failureIssue(at: rootURL) ?? .appDataIssue)
      )
    }
    switch startupState {
    case .settingUp:
      return (.localOnly, .enabling(PendingICloudSyncEnable.retryIssue(at: rootURL)))
    case .needsAttention:
      return (.localOnly, .failed(.appDataIssue))
    case .localOnly, .active:
      return (
        .localOnly,
        PendingICloudSyncEnable.exists(at: rootURL)
          ? .enabling(PendingICloudSyncEnable.retryIssue(at: rootURL)) : .ready
      )
    }
  }

#if DEBUG
  /// Runs the same UI action through a fake control server in UI tests.
  @MainActor
  public static func simulatedServices(
    rootURL: URL,
    syncModeStore: SnipSyncModeStore?,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> SnipSnapCloudAppServices {
    guard let syncModeStore else {
      return SnipSnapCloudAppServices(
        syncedContentSettings: SyncedContentSettingsModel(mode: .localOnly),
        syncSession: nil
      )
    }
    let simulateRemovalPending = environment["SNIP_SNAP_UI_TEST_REMOVAL_PENDING"] == "1"
    let reset = SimulatedCloudCollectionReset(
      rootURL: rootURL,
      persistence: syncModeStore.persistence,
      simulateEncryptedDataReset: environment["SNIP_SNAP_UI_TEST_ENCRYPTED_RESET"] == "1",
      simulateRemovalPending: simulateRemovalPending
    )
    let automaticResults = AsyncStream.makeStream(of: SnipSnapCloudSyncResult.self)
    let session = SnipSnapCloudSyncSession(
      synchronize: { try await reset.synchronize() },
      retry: { try await reset.retrySynchronization() },
      scheduleAutomaticSync: {
        automaticResults.continuation.yield(try await reset.synchronize())
      },
      enable: {
        try await reset.enableSync()
        return .enabled
      },
      disable: { choice in try await reset.disableICloudSync(choice) },
      delete: { try await reset.deleteSyncedContent() },
      activeLibrary: { try await reset.activeLibrary() },
      automaticSyncResults: automaticResults.stream,
      automaticErrorHandler: { error in
        automaticResults.continuation.yield(automaticSyncResult(for: error))
      }
    )
    return SnipSnapCloudAppServices(
      syncedContentSettings: SyncedContentSettingsModel(
        mode: .iCloudSync,
        // Automatic launch syncs don't report removal progress, so start where a request would.
        initialState: simulateRemovalPending ? .removalPending : .ready,
        issueMapper: SnipSnapCloudSyncIssueMapper.issue(for:),
        enableAction: { try await session.enableICloudSync() },
        disableAction: { choice in try await session.disableICloudSync(choice) },
        deleteAction: { try await session.deleteSyncedContent() }
      ),
      syncSession: session
    )
  }

  /// Starts local-only and runs explicit enable against the fake cloud in UI tests.
  @MainActor
  public static func simulatedLocalOnlyServices(
    rootURL: URL,
    attachmentCacheRootURL: URL? = nil,
    sourceLibrary: any SnipLibrary,
    syncModeStore: SnipSyncModeStore? = nil
  ) -> SnipSnapCloudAppServices {
    let server = FakeCloudServer()
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: rootURL,
      attachmentCacheRootURL: attachmentCacheRootURL,
      sourceLibrary: sourceLibrary,
      syncModeStore: syncModeStore,
      cloudScope: "private",
      accountLineage: "ui-test-account",
      ownerName: "ui-test-owner",
      controlTransport: FakeCloudControlTransport(server: server),
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: {
        CloudCollectionDescriptor.fresh(ownerName: "ui-test-owner")
      }
    )
    let appOperationGate = AsyncOperationGate()
    let session = SnipSnapCloudSyncSession(
      synchronize: { try await lifecycle.synchronize() },
      scheduleAutomaticSync: { try await lifecycle.scheduleAutomaticSync() },
      enable: { try await lifecycle.enableICloudSync() },
      disable: { choice in try await lifecycle.disableICloudSync(choice) },
      delete: { try await lifecycle.deleteSyncedContent() },
      activeLibrary: { try await lifecycle.activeLibrary() },
      operationGate: appOperationGate
    )
    return SnipSnapCloudAppServices(
      syncedContentSettings: SyncedContentSettingsModel(
        mode: .localOnly,
        issueMapper: SnipSnapCloudSyncIssueMapper.issue(for:),
        enableAction: { try await session.enableICloudSync() },
        disableAction: { choice in try await session.disableICloudSync(choice) },
        deleteAction: { try await session.deleteSyncedContent() }
      ),
      syncSession: session,
      syncHandlerFactory: { sync, retry, schedule in
        lifecycle.makeCloudSyncHandler(operationGate: appOperationGate,
          syncWhenPossible: sync, retrySyncWhenPossible: retry,
          scheduleSyncAfterLocalChange: schedule)
      }
    )
  }
#endif
}
