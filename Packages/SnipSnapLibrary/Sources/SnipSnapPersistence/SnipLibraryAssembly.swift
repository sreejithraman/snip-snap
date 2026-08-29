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
  public let recoveryScope: SnipRecoveryScope?

  public init(
    library: any SnipLibrary,
    activeCloudNamespace: ICloudSyncNamespaceBinding?
  ) {
    self.library = library
    recoveryScope = SnipRecoveryScopeFactory.scope(
      forActiveCloudNamespace: activeCloudNamespace
    )
  }

  public init(
    library: any SnipLibrary,
    syncModeRootURL: URL
  ) {
    self.init(
      library: library,
      activeCloudNamespace: SyncModeActivationManifestReader.activeCloudNamespace(
        atSyncModeRootURL: syncModeRootURL
      )
    )
  }
}
