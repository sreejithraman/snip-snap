import CryptoKit
import Foundation
import SnipSnapCore

public struct SnipSyncModeStore: Sendable {
  package let persistence: SwiftDataSyncModePersistence

  package init(_ persistence: SwiftDataSyncModePersistence) {
    self.persistence = persistence
  }
}

public struct SnipLibraryUserActionsFactory: Sendable {
  private let makeActions: @Sendable (any SnipLibrary) -> any SnipLibraryUserActions

  private init(
    makeActions: @escaping @Sendable (any SnipLibrary) -> any SnipLibraryUserActions
  ) {
    self.makeActions = makeActions
  }

  public static var direct: Self {
    Self { DirectSnipLibraryUserActions(library: $0) }
  }

  public static func durable(
    journalURL: URL,
    collectionIdentity: @escaping @Sendable () async -> SnipLibraryCollectionIdentity
  ) -> Self {
    Self { library in
      SnipLibraryDeviceActions(
        library: library,
        journalURL: journalURL,
        collectionIdentity: collectionIdentity
      )
    }
  }

  public func actions(for library: any SnipLibrary) -> any SnipLibraryUserActions {
    makeActions(library)
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
  public let userActionsFactory: SnipLibraryUserActionsFactory
  public let recoveryScope: SnipRecoveryScope?
  public let syncModeStore: SnipSyncModeStore?

  public init(
    library: any SnipLibrary,
    activeCloudNamespace: ICloudSyncNamespaceBinding?
  ) {
    self.library = library
    userActionsFactory = .direct
    userActions = userActionsFactory.actions(for: library)
    recoveryScope = SnipRecoveryScopeFactory.scope(
      forActiveCloudNamespace: activeCloudNamespace
    )
    syncModeStore = nil
  }

  public init(
    library: any SnipLibrary,
    syncModeRootURL: URL,
    initializeSyncModeStore: Bool = false,
    actionJournalURL: URL? = nil
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
    let collectionRootURL = syncModeRootURL.deletingLastPathComponent()
    userActionsFactory = .durable(
      journalURL: actionJournalURL ?? SnipLibraryDeviceActions.defaultJournalURL(
        nextTo: collectionRootURL.appendingPathComponent("snips.store")
      ),
      collectionIdentity: {
        SnipLibraryCollectionIdentityFactory.activeIdentity(
          atSyncModeRootURL: syncModeRootURL,
          standaloneRootURL: collectionRootURL
        )
      }
    )
    userActions = userActionsFactory.actions(for: resolvedLibrary)
  }
}

package enum SnipLibraryCollectionIdentityFactory {
  package static func identity(
    storeID: UUID,
    kind: String,
    namespace: ICloudSyncNamespaceBinding?
  ) -> SnipLibraryCollectionIdentity {
    var data = Data()
    append("snipsnap-active-collection-v1", to: &data)
    append(storeID.uuidString.lowercased(), to: &data)
    append(kind, to: &data)
    if let namespace {
      append(namespace.scope, to: &data)
      append(namespace.accountLineage, to: &data)
      append(namespace.generation.uuidString.lowercased(), to: &data)
      for zone in namespace.zones.sorted(by: {
        ($0.ownerName, $0.name) < ($1.ownerName, $1.name)
      }) {
        append(zone.ownerName, to: &data)
        append(zone.name, to: &data)
      }
    }
    return SnipLibraryCollectionIdentity(digest: Data(SHA256.hash(data: data)))
  }

  package static func standalone(rootURL: URL) -> SnipLibraryCollectionIdentity {
    hashed(domain: "snipsnap-standalone-collection-v1", value: rootURL.standardizedFileURL.path)
  }

  package static func unavailable(rootURL: URL) -> SnipLibraryCollectionIdentity {
    hashed(domain: "snipsnap-unavailable-collection-v1", value: rootURL.standardizedFileURL.path)
  }

  package static func activeIdentity(
    atSyncModeRootURL rootURL: URL,
    standaloneRootURL: URL
  ) -> SnipLibraryCollectionIdentity {
    let manifestURL = rootURL.appendingPathComponent("activation.json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      return standalone(rootURL: standaloneRootURL)
    }
    do {
      let values = try manifestURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        return unavailable(rootURL: rootURL)
      }
      let manifest = try JSONDecoder().decode(
        SwiftDataSyncModePersistence.Manifest.self,
        from: Data(contentsOf: manifestURL)
      )
      try SwiftDataSyncModePersistence.validate(manifest)
      _ = try SwiftDataSyncModePersistence.validatedStoreRoots(manifest.stores, rootURL: rootURL)
      guard let active = manifest.stores.first(where: { $0.id == manifest.activeStoreID }) else {
        return unavailable(rootURL: rootURL)
      }
      return identity(
        storeID: active.id,
        kind: active.kind.rawValue,
        namespace: active.namespace
      )
    } catch {
      return unavailable(rootURL: rootURL)
    }
  }

  private static func hashed(domain: String, value: String) -> SnipLibraryCollectionIdentity {
    var data = Data()
    append(domain, to: &data)
    append(value, to: &data)
    return SnipLibraryCollectionIdentity(digest: Data(SHA256.hash(data: data)))
  }

  private static func append(_ value: String, to data: inout Data) {
    let bytes = Data(value.utf8)
    var count = UInt64(bytes.count).bigEndian
    withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
    data.append(bytes)
  }
}
