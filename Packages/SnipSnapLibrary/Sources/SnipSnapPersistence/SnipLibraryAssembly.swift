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
  public let userActionsRebinder: SnipLibraryUserActionsRebinder
  public let recoveryScope: SnipRecoveryScope?
  public let syncModeStore: SnipSyncModeStore?

  public init(
    library: any SnipLibrary,
    activeCloudNamespace: ICloudSyncNamespaceBinding?
  ) {
    self.library = library
    let rebinder = Self.makeUserActionsRebinder()
    userActionsRebinder = rebinder
    userActions = rebinder.actions(for: library)
    recoveryScope = SnipRecoveryScopeFactory.scope(
      forActiveCloudNamespace: activeCloudNamespace
    )
    syncModeStore = nil
  }

  public init(
    library: any SnipLibrary,
    syncModeRootURL: URL,
    initializeSyncModeStore: Bool = false
  ) {
    let namespace = SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: syncModeRootURL
    )
    recoveryScope = SnipRecoveryScopeFactory.scope(forActiveCloudNamespace: namespace)
    let manifestURL = syncModeRootURL.appendingPathComponent(
      "activation.json", isDirectory: false
    )
    let resolvedLibrary: any SnipLibrary
    if (initializeSyncModeStore || FileManager.default.fileExists(atPath: manifestURL.path)),
      let persistence = try? SwiftDataSyncModePersistence(rootURL: syncModeRootURL)
    {
      resolvedLibrary = persistence.activeLibrary(fallback: library)
      syncModeStore = SnipSyncModeStore(persistence)
    } else {
      resolvedLibrary = library
      syncModeStore = nil
    }
    self.library = resolvedLibrary
    let rebinder = Self.makeUserActionsRebinder()
    userActionsRebinder = rebinder
    userActions = rebinder.actions(for: resolvedLibrary)
  }

  private static func makeUserActionsRebinder() -> SnipLibraryUserActionsRebinder {
    SnipLibraryUserActionsRebinder { library in
      DirectSnipLibraryUserActions(
        library: library,
        previewBackupImport: { backupURL, target in
          try await SnipLibraryImport.preview(backupURL: backupURL, target: target)
        }
      )
    }
  }
}
