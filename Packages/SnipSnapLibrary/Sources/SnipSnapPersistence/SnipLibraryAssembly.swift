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
    namespace.map { SnipRecoveryScope(namespaceKey($0)) }
  }

  static func namespaceKey(_ namespace: ICloudSyncNamespaceBinding) -> String {
    var data = Data()
    func append(_ value: String) {
      let bytes = Data(value.utf8)
      var count = UInt64(bytes.count).bigEndian
      withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
      data.append(bytes)
    }
    append("snipsnap-cloud-namespace-v1")
    append(namespace.scope)
    append(namespace.accountLineage)
    append(namespace.generation.uuidString.lowercased())
    for zone in namespace.zones.sorted(by: {
      ($0.ownerName, $0.name) < ($1.ownerName, $1.name)
    }) {
      append(zone.ownerName)
      append(zone.name)
    }
    return data.base64EncodedString()
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
