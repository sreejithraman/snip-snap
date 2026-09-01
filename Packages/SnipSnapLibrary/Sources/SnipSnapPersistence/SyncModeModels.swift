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
}

package enum SyncModeStoreKind: String, Codable, Equatable, Sendable {
  case localOnly
  case iCloudSync
}

package enum SyncModeStoreLifecycle: String, Codable, Equatable, Sendable {
  case creating, ready, recovery, isolated, retired, deleting
}

package enum ICloudAccountIsolationReason: String, Codable, Equatable, Sendable {
  case signedOut, accountChanged
}

package enum ICloudAccountIsolationChoice: String, Codable, Equatable, Sendable {
  case keepLocalCopy, remove
}

package enum ICloudAccountIsolationResolution: String, Codable, Equatable, Sendable {
  case undecided, keepingLocalCopy, removing
}

package struct ICloudAccountIsolation: Codable, Equatable, Sendable {
  package let id: UUID
  package let storeID: UUID
  package let replacementStoreID: UUID
  package let namespace: ICloudSyncNamespaceBinding
  package let reason: ICloudAccountIsolationReason
  package var resolution: ICloudAccountIsolationResolution

  package init(
    id: UUID,
    storeID: UUID,
    replacementStoreID: UUID,
    namespace: ICloudSyncNamespaceBinding,
    reason: ICloudAccountIsolationReason,
    resolution: ICloudAccountIsolationResolution = .undecided
  ) {
    self.id = id
    self.storeID = storeID
    self.replacementStoreID = replacementStoreID
    self.namespace = namespace
    self.reason = reason
    self.resolution = resolution
  }

  private enum CodingKeys: String, CodingKey {
    case id, storeID, replacementStoreID, namespace, reason, resolution
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    storeID = try values.decode(UUID.self, forKey: .storeID)
    replacementStoreID = try values.decode(UUID.self, forKey: .replacementStoreID)
    namespace = try values.decode(ICloudSyncNamespaceBinding.self, forKey: .namespace)
    reason = try values.decode(ICloudAccountIsolationReason.self, forKey: .reason)
    resolution = try values.decodeIfPresent(
      ICloudAccountIsolationResolution.self,
      forKey: .resolution
    ) ?? .undecided
  }
}

package enum SyncModeSyncProtocol: String, Codable, Equatable, Sendable {
  case legacyTextV1
  case fullRecordV1
}

package struct SyncModeStore: Codable, Equatable, Sendable {
  package let id: UUID
  package let kind: SyncModeStoreKind
  package let namespace: ICloudSyncNamespaceBinding?
  package let relativeRoot: String
  package let syncProtocol: SyncModeSyncProtocol
  /// The exact cloud collection whose data this local-only store may rejoin.
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
    syncProtocol = try values.decodeIfPresent(
      SyncModeSyncProtocol.self,
      forKey: .syncProtocol
    ) ?? .legacyTextV1
    quarantinedNamespace = try values.decodeIfPresent(
      ICloudSyncNamespaceBinding.self,
      forKey: .quarantinedNamespace
    )
    revision = try values.decode(UInt64.self, forKey: .revision)
    lifecycle = try values.decode(SyncModeStoreLifecycle.self, forKey: .lifecycle)
  }
}

package enum SyncModeTransitionPhase: String, Codable, Equatable, Sendable {
  case candidateDeclared, candidateReady, remoteFetched, sourceFrozen
  case recordsMerged, enrollmentApproved, firstSendStarted, firstSendComplete, pointerSwapped
}

package struct SyncModeWriteReservation: Codable, Equatable, Sendable {
  package let id: UUID
  package let storeID: UUID
  package let reservedRevision: UInt64
}

package struct SyncModeFreezeToken: Codable, Equatable, Sendable {
  package let id: UUID
  package let sourceStoreID: UUID
  package let revision: UInt64
}

package struct SyncModeSeedProvenance: Codable, Equatable, Sendable {
  package let sourceSnipID: UUID
  package let candidateSnipID: UUID
  package let candidateRequestID: UUID
  package let baseDigest: Data
  package let baseRemoteDigest: Data
  package let acceptedRecordIdentity: CloudTextStorageIdentity?
  package let digestVersion: Int

  package init(
    sourceSnipID: UUID,
    candidateSnipID: UUID,
    candidateRequestID: UUID,
    baseDigest: Data,
    baseRemoteDigest: Data,
    acceptedRecordIdentity: CloudTextStorageIdentity? = nil,
    digestVersion: Int = 2
  ) {
    self.sourceSnipID = sourceSnipID
    self.candidateSnipID = candidateSnipID
    self.candidateRequestID = candidateRequestID
    self.baseDigest = baseDigest
    self.baseRemoteDigest = baseRemoteDigest
    self.acceptedRecordIdentity = acceptedRecordIdentity
    self.digestVersion = digestVersion
  }

  private enum CodingKeys: String, CodingKey {
    case sourceSnipID, candidateSnipID, candidateRequestID
    case baseDigest, baseRemoteDigest, acceptedRecordIdentity, digestVersion
  }

  package init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    sourceSnipID = try values.decode(UUID.self, forKey: .sourceSnipID)
    candidateSnipID = try values.decode(UUID.self, forKey: .candidateSnipID)
    candidateRequestID = try values.decode(UUID.self, forKey: .candidateRequestID)
    baseDigest = try values.decode(Data.self, forKey: .baseDigest)
    baseRemoteDigest = try values.decode(Data.self, forKey: .baseRemoteDigest)
    acceptedRecordIdentity = try values.decodeIfPresent(
      CloudTextStorageIdentity.self,
      forKey: .acceptedRecordIdentity
    )
    digestVersion = try values.decodeIfPresent(Int.self, forKey: .digestVersion) ?? 1
  }
}

package struct SyncModeSeedSettlementCandidate: Equatable, Sendable {
  package let snipID: UUID
  package let acceptedRecordIdentity: CloudTextStorageIdentity?

  package init(snipID: UUID, acceptedRecordIdentity: CloudTextStorageIdentity?) {
    self.snipID = snipID
    self.acceptedRecordIdentity = acceptedRecordIdentity
  }
}

package enum SyncModeSeedSettlementValue: Equatable, Sendable {
  case saved(recordIdentity: CloudTextStorageIdentity, acceptedText: String)
  case deleted(recordIdentity: CloudTextStorageIdentity)
}

package struct SyncModeSeedSettlementProof: Equatable, Sendable {
  package let namespace: ICloudSyncNamespaceBinding
  package let values: [UUID: SyncModeSeedSettlementValue]

  package init(
    namespace: ICloudSyncNamespaceBinding,
    values: [UUID: SyncModeSeedSettlementValue]
  ) {
    self.namespace = namespace
    self.values = values
  }
}

package enum SyncModeSendOperationKind: String, Codable, Equatable, Sendable {
  case save, delete
}

package struct SyncModeSendOperation: Codable, Equatable, Sendable {
  package let reference: CloudEntityReference?
  package let recordIdentity: CloudTextStorageIdentity
  package let kind: SyncModeSendOperationKind

  package var snipID: UUID? { reference?.domainID }

  package init(
    snipID: UUID,
    recordIdentity: CloudTextStorageIdentity,
    kind: SyncModeSendOperationKind
  ) {
    reference = CloudEntityReference(kind: .snip, domainID: snipID)
    self.recordIdentity = recordIdentity
    self.kind = kind
  }

  package init(
    reference: CloudEntityReference?,
    recordIdentity: CloudTextStorageIdentity,
    kind: SyncModeSendOperationKind
  ) {
    self.reference = reference
    self.recordIdentity = recordIdentity
    self.kind = kind
  }

  private enum CodingKeys: String, CodingKey {
    case reference, snipID, recordIdentity, kind
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    if let reference = try values.decodeIfPresent(
      CloudEntityReference.self,
      forKey: .reference
    ) {
      self.reference = reference
    } else if let legacySnipID = try values.decodeIfPresent(UUID.self, forKey: .snipID) {
      reference = CloudEntityReference(kind: .snip, domainID: legacySnipID)
    } else {
      reference = nil
    }
    recordIdentity = try values.decode(CloudTextStorageIdentity.self, forKey: .recordIdentity)
    kind = try values.decode(SyncModeSendOperationKind.self, forKey: .kind)
  }

  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(reference, forKey: .reference)
    try values.encode(recordIdentity, forKey: .recordIdentity)
    try values.encode(kind, forKey: .kind)
  }
}

package struct SyncModeSendAttempt: Codable, Equatable, Sendable {
  package let namespace: ICloudSyncNamespaceBinding
  package let operations: [SyncModeSendOperation]

  package init(
    namespace: ICloudSyncNamespaceBinding,
    operations: [SyncModeSendOperation]
  ) {
    self.namespace = namespace
    self.operations = operations
  }
}

package struct SyncModeMergeIntent: Codable, Equatable, Sendable {
  package let id: UUID
  package let sourceRevision: UInt64
  package let planDigest: Data
  package let approvedSnipIDs: Set<UUID>
  package let recoveredSourceSnipIDs: Set<UUID>
  package let seedProvenance: [SyncModeSeedProvenance]
  package let seededListIDs: Set<UUID>
  package let fullReenablePlanID: UUID?

  package init(
    id: UUID,
    sourceRevision: UInt64,
    planDigest: Data,
    approvedSnipIDs: Set<UUID>,
    recoveredSourceSnipIDs: Set<UUID>,
    seedProvenance: [SyncModeSeedProvenance],
    seededListIDs: Set<UUID>,
    fullReenablePlanID: UUID? = nil
  ) {
    self.id = id
    self.sourceRevision = sourceRevision
    self.planDigest = planDigest
    self.approvedSnipIDs = approvedSnipIDs
    self.recoveredSourceSnipIDs = recoveredSourceSnipIDs
    self.seedProvenance = seedProvenance
    self.seededListIDs = seededListIDs
    self.fullReenablePlanID = fullReenablePlanID
  }

  private enum CodingKeys: String, CodingKey {
    case id, sourceRevision, planDigest, approvedSnipIDs, recoveredSourceSnipIDs
    case seedProvenance, seededListIDs, fullReenablePlanID
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    sourceRevision = try values.decode(UInt64.self, forKey: .sourceRevision)
    planDigest = try values.decode(Data.self, forKey: .planDigest)
    approvedSnipIDs = try values.decode(Set<UUID>.self, forKey: .approvedSnipIDs)
    recoveredSourceSnipIDs = try values.decode(Set<UUID>.self, forKey: .recoveredSourceSnipIDs)
    seedProvenance = try values.decode([SyncModeSeedProvenance].self, forKey: .seedProvenance)
    seededListIDs = try values.decode(Set<UUID>.self, forKey: .seededListIDs)
    fullReenablePlanID = try values.decodeIfPresent(UUID.self, forKey: .fullReenablePlanID)
  }
}

package struct SyncModeTransition: Codable, Equatable, Sendable {
  package let id: UUID
  package let sourceStoreID: UUID
  package let candidateStoreID: UUID
  package let targetKind: SyncModeStoreKind
  package let namespace: ICloudSyncNamespaceBinding?
  package let syncProtocol: SyncModeSyncProtocol
  package var phase: SyncModeTransitionPhase
  package var freezeToken: SyncModeFreezeToken?
  package var freezeSnapshotTaken: Bool
  package var approvedSnipIDs: Set<UUID>
  package var pendingSettlementSnipIDs: Set<UUID>
  package var sendAttempt: SyncModeSendAttempt?
  package var supersededApprovedSnipIDs: Set<UUID>
  package var seedProvenance: [SyncModeSeedProvenance]
  package var serverAcceptedSeedSnipIDs: Set<UUID>
  package var captureAcceptedServerProvenance: Bool
  package var seededListIDs: Set<UUID>
  package var mergeIntent: SyncModeMergeIntent?

  package init(
    id: UUID,
    sourceStoreID: UUID,
    candidateStoreID: UUID,
    targetKind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?,
    syncProtocol: SyncModeSyncProtocol,
    phase: SyncModeTransitionPhase = .candidateDeclared,
    freezeToken: SyncModeFreezeToken? = nil,
    freezeSnapshotTaken: Bool = false,
    approvedSnipIDs: Set<UUID> = [],
    pendingSettlementSnipIDs: Set<UUID> = [],
    sendAttempt: SyncModeSendAttempt? = nil,
    supersededApprovedSnipIDs: Set<UUID> = [],
    seedProvenance: [SyncModeSeedProvenance] = [],
    serverAcceptedSeedSnipIDs: Set<UUID> = [],
    captureAcceptedServerProvenance: Bool = false,
    seededListIDs: Set<UUID> = [],
    mergeIntent: SyncModeMergeIntent? = nil
  ) {
    self.id = id
    self.sourceStoreID = sourceStoreID
    self.candidateStoreID = candidateStoreID
    self.targetKind = targetKind
    self.namespace = namespace
    self.syncProtocol = syncProtocol
    self.phase = phase
    self.freezeToken = freezeToken
    self.freezeSnapshotTaken = freezeSnapshotTaken
    self.approvedSnipIDs = approvedSnipIDs
    self.pendingSettlementSnipIDs = pendingSettlementSnipIDs
    self.sendAttempt = sendAttempt
    self.supersededApprovedSnipIDs = supersededApprovedSnipIDs
    self.seedProvenance = seedProvenance
    self.serverAcceptedSeedSnipIDs = serverAcceptedSeedSnipIDs
    self.captureAcceptedServerProvenance = captureAcceptedServerProvenance
    self.seededListIDs = seededListIDs
    self.mergeIntent = mergeIntent
  }

  private enum CodingKeys: String, CodingKey {
    case id, sourceStoreID, candidateStoreID, targetKind, namespace, syncProtocol, phase
    case freezeToken, freezeSnapshotTaken, approvedSnipIDs, pendingSettlementSnipIDs
    case sendAttempt, supersededApprovedSnipIDs, seedProvenance, serverAcceptedSeedSnipIDs
    case captureAcceptedServerProvenance, seededListIDs, mergeIntent
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    sourceStoreID = try values.decode(UUID.self, forKey: .sourceStoreID)
    candidateStoreID = try values.decode(UUID.self, forKey: .candidateStoreID)
    targetKind = try values.decode(SyncModeStoreKind.self, forKey: .targetKind)
    namespace = try values.decodeIfPresent(ICloudSyncNamespaceBinding.self, forKey: .namespace)
    syncProtocol = try values.decodeIfPresent(
      SyncModeSyncProtocol.self,
      forKey: .syncProtocol
    ) ?? .legacyTextV1
    phase = try values.decode(SyncModeTransitionPhase.self, forKey: .phase)
    freezeToken = try values.decodeIfPresent(SyncModeFreezeToken.self, forKey: .freezeToken)
    freezeSnapshotTaken = try values.decode(Bool.self, forKey: .freezeSnapshotTaken)
    approvedSnipIDs = try values.decode(Set<UUID>.self, forKey: .approvedSnipIDs)
    pendingSettlementSnipIDs = try values.decode(Set<UUID>.self, forKey: .pendingSettlementSnipIDs)
    sendAttempt = try values.decodeIfPresent(SyncModeSendAttempt.self, forKey: .sendAttempt)
    supersededApprovedSnipIDs = try values.decode(
      Set<UUID>.self,
      forKey: .supersededApprovedSnipIDs
    )
    seedProvenance = try values.decode([SyncModeSeedProvenance].self, forKey: .seedProvenance)
    serverAcceptedSeedSnipIDs = try values.decode(
      Set<UUID>.self,
      forKey: .serverAcceptedSeedSnipIDs
    )
    captureAcceptedServerProvenance = try values.decode(
      Bool.self,
      forKey: .captureAcceptedServerProvenance
    )
    seededListIDs = try values.decode(Set<UUID>.self, forKey: .seededListIDs)
    mergeIntent = try values.decodeIfPresent(SyncModeMergeIntent.self, forKey: .mergeIntent)
  }
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
  package let accountIsolation: ICloudAccountIsolation?
  package let attentionReason: ICloudSyncAttentionReason?
  package let hasActiveMutationReservation: Bool
}

package enum SyncModePersistenceError: Error, Equatable, Sendable {
  case invalidManifest
  case transitionInProgress
  case missingStore
  case namespaceMismatch
  case invalidFreezeToken
  case storageFailure
}
