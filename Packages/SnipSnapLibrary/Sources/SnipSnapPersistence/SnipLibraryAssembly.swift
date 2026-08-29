import CryptoKit
import Foundation
import SnipSnapCore

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
  public let recoveryScope: SnipRecoveryScope?

  public init(
    library: any SnipLibrary,
    activeCloudNamespace: ICloudSyncNamespaceBinding?
  ) {
    self.library = library
    userActions = DirectSnipLibraryUserActions(library: library)
    recoveryScope = SnipRecoveryScopeFactory.scope(
      forActiveCloudNamespace: activeCloudNamespace
    )
  }

  public init(
    library: any SnipLibrary,
    syncModeRootURL: URL,
    actionJournalURL: URL? = nil
  ) {
    self.library = library
    recoveryScope = SnipRecoveryScopeFactory.scope(
      forActiveCloudNamespace: SyncModeActivationManifestReader.activeCloudNamespace(
        atSyncModeRootURL: syncModeRootURL
      )
    )
    let collectionRootURL = syncModeRootURL.deletingLastPathComponent()
    userActions = SnipLibraryDeviceActions(
      library: library,
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
