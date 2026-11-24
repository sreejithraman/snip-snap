import Foundation
import SnipSnapCore

package struct CloudSyncNamespaceKey: Codable, Equatable, Hashable, Sendable {
  package let rawValue: String

  package init(rawValue: String) {
    self.rawValue = rawValue
  }

  package init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ICloudSyncZoneBinding: Codable, Equatable, Hashable, Sendable {
  public let name: String
  public let ownerName: String

  public init(name: String, ownerName: String) {
    self.name = name
    self.ownerName = ownerName
  }
}

public struct ICloudSyncNamespaceBinding: Codable, Equatable, Sendable {
  public let scope: String
  public let accountLineage: String
  public let generation: UUID
  public let zones: Set<ICloudSyncZoneBinding>

  public init(
    scope: String,
    accountLineage: String,
    generation: UUID,
    zones: Set<ICloudSyncZoneBinding>
  ) {
    self.scope = scope
    self.accountLineage = accountLineage
    self.generation = generation
    self.zones = zones
  }

  package var namespaceKey: CloudSyncNamespaceKey {
    var data = Data()
    func append(_ value: String) {
      let bytes = Data(value.utf8)
      var count = UInt64(bytes.count).bigEndian
      withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
      data.append(bytes)
    }
    append("snipsnap-cloud-namespace-v1")
    append(scope)
    append(accountLineage)
    append(generation.uuidString.lowercased())
    for zone in zones.sorted(by: {
      ($0.ownerName, $0.name) < ($1.ownerName, $1.name)
    }) {
      append(zone.ownerName)
      append(zone.name)
    }
    return CloudSyncNamespaceKey(rawValue: data.base64EncodedString())
  }

  /// The inverse of `namespaceKey`. Returns nil for any string `namespaceKey` doesn't produce.
  package init?(namespaceKey: CloudSyncNamespaceKey) {
    guard var remaining = Data(base64Encoded: namespaceKey.rawValue) else { return nil }
    func readField() -> String? {
      guard remaining.count >= 8 else { return nil }
      let count = remaining.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      remaining = remaining.dropFirst(8)
      guard count <= UInt64(remaining.count) else { return nil }
      let field = remaining.prefix(Int(count))
      remaining = remaining.dropFirst(Int(count))
      return String(bytes: field, encoding: .utf8)
    }
    guard readField() == "snipsnap-cloud-namespace-v1",
      let scope = readField(),
      let accountLineage = readField(),
      let generation = readField().flatMap(UUID.init(uuidString:))
    else { return nil }
    var zones: Set<ICloudSyncZoneBinding> = []
    while !remaining.isEmpty {
      guard let ownerName = readField(), let name = readField() else { return nil }
      zones.insert(ICloudSyncZoneBinding(name: name, ownerName: ownerName))
    }
    self.init(scope: scope, accountLineage: accountLineage, generation: generation, zones: zones)
    guard self.namespaceKey == namespaceKey else { return nil }
  }
}

package enum SyncModeStoreKind: String, Codable, Equatable, Sendable {
  case localOnly
  case iCloudSync
}

/// Only earlier builds wrote `recovery`. Those read-only copies stay on disk, unused.
package enum SyncModeStoreLifecycle: String, Codable, Equatable, Sendable {
  case creating, ready, recovery, isolated, retired, deleting
}

package enum SyncModeSyncProtocol: String, Codable, Equatable, Sendable {
  case retiredText = "legacyTextV1"
  case fullRecordV1
}

package struct SyncModeStore: Codable, Equatable, Sendable {
  package let id: UUID
  package let kind: SyncModeStoreKind
  package let namespace: ICloudSyncNamespaceBinding?
  package let relativeRoot: String
  package var syncProtocol: SyncModeSyncProtocol
  /// The exact cloud collection whose data this local-only store may rejoin. A stopped cache keeps its original root.
  package var quarantinedNamespace: ICloudSyncNamespaceBinding?
  package var revision: UInt64
  package var lifecycle: SyncModeStoreLifecycle

  package init(
    id: UUID,
    kind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?,
    relativeRoot: String,
    syncProtocol: SyncModeSyncProtocol,
    quarantinedNamespace: ICloudSyncNamespaceBinding? = nil,
    revision: UInt64 = 0,
    lifecycle: SyncModeStoreLifecycle = .creating
  ) {
    self.id = id
    self.kind = kind
    self.namespace = namespace
    self.relativeRoot = relativeRoot
    self.syncProtocol = syncProtocol
    self.quarantinedNamespace = quarantinedNamespace
    self.revision = revision
    self.lifecycle = lifecycle
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, namespace, relativeRoot, syncProtocol, quarantinedNamespace
    case revision, lifecycle
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    kind = try values.decode(SyncModeStoreKind.self, forKey: .kind)
    namespace = try values.decodeIfPresent(ICloudSyncNamespaceBinding.self, forKey: .namespace)
    relativeRoot = try values.decode(String.self, forKey: .relativeRoot)
    syncProtocol = try values.decode(SyncModeSyncProtocol.self, forKey: .syncProtocol)
    quarantinedNamespace = try values.decodeIfPresent(
      ICloudSyncNamespaceBinding.self,
      forKey: .quarantinedNamespace
    )
    revision = try values.decode(UInt64.self, forKey: .revision)
    lifecycle = try values.decode(SyncModeStoreLifecycle.self, forKey: .lifecycle)
  }
}

package enum SyncModeTransitionPhase: String, Codable, Equatable, Sendable {
  case declared, merged, swapped
}

package enum ICloudSyncAttentionReason: String, Codable, Equatable, Sendable {
  case enrollmentBlocked, firstSyncFailed, namespaceChanged, transferConflict, storageFailure
  case storeReadFailed, terminalFetchFailure, transitionFailure
  case accountTemporarilyUnavailable, accountStatusUnknown, accountSignedOut
  case accountRestricted, accountChanged
}

package struct SyncModeStorageSnapshot: Equatable, Sendable {
  package let activeStore: SyncModeStore
  package let transition: SyncModeTransition?
  package let attentionReason: ICloudSyncAttentionReason?

  package var keptAfterCloudReset: Bool {
    activeStore.kind == .localOnly && attentionReason == .namespaceChanged
  }
}

package enum SyncModePersistenceError: Error, Equatable, Sendable {
  case invalidManifest
  case transitionInProgress
  case missingStore
  case namespaceMismatch
  case storageFailure
}
