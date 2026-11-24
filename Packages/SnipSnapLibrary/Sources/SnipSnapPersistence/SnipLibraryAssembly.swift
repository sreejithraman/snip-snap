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
  /// Sync mode holds this device's library but couldn't open it. `library` is unavailable,
  /// so the app shows an error instead of an older copy.
  public let libraryUnavailable: Bool

  public init(
    library: any SnipLibrary,
    syncModeRootURL: URL,
    attachmentCacheRootURL: URL? = nil,
    initializeSyncModeStore: Bool = false
  ) {
    let resolvedLibrary: any SnipLibrary
    let initialLocalLibrary = initializeSyncModeStore ? nil : library as? SwiftDataSnipLibrary
    let hasManifest = SyncModeActivationManifestReader.hasActivationManifest(
      atSyncModeRootURL: syncModeRootURL
    )
    if (initializeSyncModeStore || initialLocalLibrary != nil || hasManifest),
      let persistence = try? SwiftDataSyncModePersistence(
        rootURL: syncModeRootURL,
        attachmentCacheRootURL: attachmentCacheRootURL,
        initialLocalLibrary: initialLocalLibrary
      )
    {
      resolvedLibrary = persistence.lazyActiveLibrary()
      syncModeStore = SnipSyncModeStore(persistence)
      libraryUnavailable = false
    } else if hasManifest {
      // This device moved its library into sync mode, so the root store is out of date.
      // Open nothing rather than show or edit it; the manifest stays as it was.
      resolvedLibrary = SwiftDataSnipLibrary.unavailable(
        storeURL: (library as? SwiftDataSnipLibrary)?.lockURL.deletingPathExtension()
          ?? SwiftDataSnipLibrary.defaultStoreURL()
      )
      syncModeStore = nil
      libraryUnavailable = true
    } else {
      resolvedLibrary = library
      syncModeStore = nil
      libraryUnavailable = false
    }
    let namespace = SyncModeActivationManifestReader.recoveryNamespace(at: syncModeRootURL)
    recoveryScope = SnipRecoveryScopeFactory.scope(forActiveCloudNamespace: namespace)
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
