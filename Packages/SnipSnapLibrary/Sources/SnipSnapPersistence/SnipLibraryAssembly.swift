import Foundation
import SnipSnapCore

public struct SnipSyncModeStore: Sendable {
  package let persistence: SwiftDataSyncModePersistence

  package init(_ persistence: SwiftDataSyncModePersistence) {
    self.persistence = persistence
  }
}

public enum SnipRecoveryScopeFactory {
  public static func scope(
    forActiveCloudNamespace namespace: ICloudSyncNamespaceBinding?
  ) -> SnipRecoveryScope? {
    namespace.map { SnipRecoveryScope($0.namespaceKey.rawValue) }
  }
}

public struct SnipLibraryAssembly: Sendable {
  public let library: any SnipLibrary
  public let userActions: any SnipLibraryUserActions
  public let userActionsFactory: SnipLibraryUserActionsFactory
  public let recoveryScope: SnipRecoveryScope?
  public let syncModeStore: SnipSyncModeStore?

  public init(
    library: any SnipLibrary,
    activeCloudNamespace: ICloudSyncNamespaceBinding?
  ) {
    self.library = library
    let factory = Self.makeUserActionsFactory()
    userActionsFactory = factory
    userActions = factory(library)
    recoveryScope = SnipRecoveryScopeFactory.scope(
      forActiveCloudNamespace: activeCloudNamespace
    )
    syncModeStore = nil
  }

  public init(
    library: any SnipLibrary,
    syncModeRootURL: URL,
    attachmentCacheRootURL: URL? = nil,
    initializeSyncModeStore: Bool = false
  ) {
    let namespace = SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: syncModeRootURL
    )
    recoveryScope = SnipRecoveryScopeFactory.scope(forActiveCloudNamespace: namespace)
    let resolvedLibrary: any SnipLibrary
    if (
      initializeSyncModeStore
        || SyncModeActivationManifestReader.hasActivationManifest(
          atSyncModeRootURL: syncModeRootURL
        )
    ),
      let persistence = try? SwiftDataSyncModePersistence(
        rootURL: syncModeRootURL,
        attachmentCacheRootURL: attachmentCacheRootURL
      )
    {
      resolvedLibrary = persistence.activeLibrary(fallback: library)
      syncModeStore = SnipSyncModeStore(persistence)
    } else {
      resolvedLibrary = library
      syncModeStore = nil
    }
    self.library = resolvedLibrary
    let factory = Self.makeUserActionsFactory()
    userActionsFactory = factory
    userActions = factory(resolvedLibrary)
  }

  private static func makeUserActionsFactory() -> SnipLibraryUserActionsFactory {
    { library in
      DirectSnipLibraryUserActions(
        library: library,
        previewBackupImport: { backupURL, target in
          try await SnipLibraryImport.preview(backupURL: backupURL, target: target)
        }
      )
    }
  }
}
