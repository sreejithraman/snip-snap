import CryptoKit
import Foundation
import SnipSnapCore

package struct ICloudSyncZoneBinding: Codable, Equatable, Hashable, Sendable {
  package let name: String
  package let ownerName: String

  package init(name: String, ownerName: String) {
    self.name = name
    self.ownerName = ownerName
  }
}

package struct ICloudSyncNamespaceBinding: Codable, Equatable, Sendable {
  package let scope: String
  package let accountLineage: String
  package let generation: UUID
  package let zones: Set<ICloudSyncZoneBinding>

  package init(
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
}

package enum SyncModeStoreKind: String, Codable, Equatable, Sendable {
  case localOnly
  case iCloudSync
}

package enum SyncModeStoreLifecycle: String, Codable, Equatable, Sendable {
  case creating, ready, isolated, retired, deleting
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

package actor SyncModeActiveMutationLease {
  private let persistence: SwiftDataSyncModePersistence
  private let storeID: UUID

  init(persistence: SwiftDataSyncModePersistence, storeID: UUID) {
    self.persistence = persistence
    self.storeID = storeID
  }

  package func run<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let reservation = try await persistence.reserveActiveMutation(storeID: storeID)
    do {
      let value = try await operation()
      try await persistence.finishActiveMutation(reservation)
      return value
    } catch {
      // A failed clear leaves a durable reservation that reopen can clear conservatively.
      try? await persistence.finishActiveMutation(reservation)
      throw error
    }
  }
}

package enum SyncModeCrashPoint: Equatable, Sendable {
  case afterCandidateManifest
  case beforeCandidateDurability
  case afterCandidateDurability
  case beforeCandidateMergeDurability
  case afterCandidateMergeDurability
  case afterEnrollmentApproval
  case afterFirstSendStarted
  case beforeSendAttemptManifest
  case afterFirstSendComplete
  case afterRetryBasePromotion
  case duringRetryBasePromotionStaging
  case beforePointerSwap
  case afterPointerSwap
  case afterRetiredCleanupDeclared
  case afterAccountIsolationManifest
  case beforeAccountIsolationDurability
  case afterAccountIsolationDurability
  case beforeAccountIsolationPointerSwap
  case afterAccountIsolationPointerSwap
  case afterAccountResolutionIntent
  case afterAccountLocalCopyMerge
  case beforeAccountIsolationRemovalCommit
  case afterAccountIsolationRemovalCommit
  case afterAccountIsolationRootRemoval
}


package enum SyncModeWritePoint: Equatable, Sendable {
  case afterRevisionReserved
  case beforeReservationCleared
}

/// Owns mode-store roots and the one atomic file that selects the active root.
package actor SwiftDataSyncModePersistence {
  package typealias ManifestWriter = @Sendable (Data, URL) throws -> Void
  package typealias WriteHook = @Sendable (SyncModeWritePoint) async throws -> Void
  package typealias ReadHook = @Sendable () throws -> Void

  struct Manifest: Codable, Equatable {
    let version: Int
    var activeStoreID: UUID
    var stores: [SyncModeStore]
    var transition: SyncModeTransition?
    var accountIsolation: ICloudAccountIsolation?
    var attentionReason: ICloudSyncAttentionReason?
    var writeReservation: SyncModeWriteReservation?

    private enum CodingKeys: String, CodingKey {
      case version, activeStoreID, stores, transition, accountIsolation
      case attentionReason, writeReservation
    }

    init(
      version: Int,
      activeStoreID: UUID,
      stores: [SyncModeStore],
      transition: SyncModeTransition?,
      accountIsolation: ICloudAccountIsolation? = nil,
      attentionReason: ICloudSyncAttentionReason?,
      writeReservation: SyncModeWriteReservation?
    ) {
      self.version = version
      self.activeStoreID = activeStoreID
      self.stores = stores
      self.transition = transition
      self.accountIsolation = accountIsolation
      self.attentionReason = attentionReason
      self.writeReservation = writeReservation
    }

    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      version = try values.decode(Int.self, forKey: .version)
      activeStoreID = try values.decode(UUID.self, forKey: .activeStoreID)
      stores = try values.decode([SyncModeStore].self, forKey: .stores)
      transition = try values.decodeIfPresent(SyncModeTransition.self, forKey: .transition)
      accountIsolation = try values.decodeIfPresent(
        ICloudAccountIsolation.self,
        forKey: .accountIsolation
      )
      attentionReason = try values.decodeIfPresent(
        ICloudSyncAttentionReason.self,
        forKey: .attentionReason
      )
      writeReservation = try values.decodeIfPresent(
        SyncModeWriteReservation.self,
        forKey: .writeReservation
      )
    }
  }

  let rootURL: URL
  let manifestURL: URL
  let crashHook: @Sendable (SyncModeCrashPoint) throws -> Void
  let manifestWriter: ManifestWriter
  let writeHook: WriteHook
  let readHook: ReadHook
  let defaultSyncProtocol: SyncModeSyncProtocol
  var manifest: Manifest
  var writeAdmissionInProgress = false

  package init(
    rootURL: URL,
    defaultSyncProtocol: SyncModeSyncProtocol = .fullRecordV1,
    crashHook: @escaping @Sendable (SyncModeCrashPoint) throws -> Void = { _ in },
    manifestWriter: @escaping ManifestWriter = { try DurableFile.write($0, to: $1) },
    writeHook: @escaping WriteHook = { _ in },
    readHook: @escaping ReadHook = {}
  ) throws {
    self.rootURL = rootURL
    manifestURL = rootURL.appendingPathComponent("activation.json", isDirectory: false)
    self.crashHook = crashHook
    self.manifestWriter = manifestWriter
    self.writeHook = writeHook
    self.readHook = readHook
    self.defaultSyncProtocol = defaultSyncProtocol
    try DurableFile.createDirectory(rootURL)
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      do {
        var loaded = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        try Self.recover(&loaded, rootURL: rootURL)
        try Self.validate(loaded)
        manifest = loaded
        try Self.write(loaded, to: manifestURL, using: manifestWriter)
      } catch {
        throw SyncModePersistenceError.invalidManifest
      }
    } else {
      var store = Self.newStore(
        kind: .localOnly,
        namespace: nil,
        syncProtocol: defaultSyncProtocol
      )
      let declared = Manifest(
        version: 2,
        activeStoreID: store.id,
        stores: [store],
        transition: nil,
        accountIsolation: nil,
        attentionReason: nil,
        writeReservation: nil
      )
      try Self.write(declared, to: manifestURL, using: manifestWriter)
      let storeURL = rootURL.appendingPathComponent(store.relativeRoot, isDirectory: true)
      _ = try SwiftDataSnipLibrary(
        storeURL: storeURL.appendingPathComponent("snips.store", isDirectory: false)
      )
      try DurableFile.syncDirectory(storeURL)
      store.lifecycle = .ready
      manifest = Manifest(
        version: 2,
        activeStoreID: store.id,
        stores: [store],
        transition: nil,
        accountIsolation: nil,
        attentionReason: nil,
        writeReservation: nil
      )
      try Self.write(manifest, to: manifestURL, using: manifestWriter)
    }
  }

  package nonisolated static func existingCloudNamespace(
    rootURL: URL
  ) throws -> ICloudSyncNamespaceBinding? {
    let manifestURL = rootURL.appendingPathComponent("activation.json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
    let stored = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    return stored.accountIsolation?.namespace
      ?? stored.transition?.namespace
      ?? stored.stores.first(where: { $0.id == stored.activeStoreID })?.namespace
  }

  package func snapshot() throws -> SyncModeStorageSnapshot {
    guard let active = manifest.stores.first(where: { $0.id == manifest.activeStoreID }) else {
      throw SyncModePersistenceError.missingStore
    }
    return SyncModeStorageSnapshot(
      activeStore: active,
      transition: manifest.transition,
      accountIsolation: manifest.accountIsolation,
      attentionReason: manifest.attentionReason,
      hasActiveMutationReservation: manifest.writeReservation != nil
    )
  }

  package func isolateActiveCloudStore(
    reason: ICloudAccountIsolationReason
  ) throws -> ICloudAccountIsolation {
    if let isolation = manifest.accountIsolation { return isolation }
    guard manifest.writeReservation == nil, !writeAdmissionInProgress,
      let active = store(id: manifest.activeStoreID),
      active.kind == .iCloudSync,
      let namespace = active.namespace
    else { throw SyncModePersistenceError.transitionInProgress }
    if let transition = manifest.transition {
      guard transition.sourceStoreID == active.id,
        transition.targetKind == .localOnly,
        transition.phase != .pointerSwapped
      else { throw SyncModePersistenceError.transitionInProgress }
    }

    let replacement = Self.newStore(
      kind: .localOnly,
      namespace: nil,
      syncProtocol: active.syncProtocol
    )
    let isolation = ICloudAccountIsolation(
      id: UUID(),
      storeID: active.id,
      replacementStoreID: replacement.id,
      namespace: namespace,
      reason: reason
    )
    var declared = manifest
    if let transition = declared.transition {
      declared.stores[try storeIndex(id: transition.candidateStoreID)].lifecycle = .deleting
      declared.transition = nil
    }
    declared.stores.append(replacement)
    declared.accountIsolation = isolation
    declared.attentionReason = reason == .signedOut ? .accountSignedOut : .accountChanged
    try commit(declared)
    try crashHook(.afterAccountIsolationManifest)

    let replacementRoot = storeURL(replacement)
    try crashHook(.beforeAccountIsolationDurability)
    _ = try SwiftDataSnipLibrary(
      storeURL: replacementRoot.appendingPathComponent("snips.store", isDirectory: false)
    )
    try DurableFile.syncDirectory(replacementRoot)
    try DurableFile.syncDirectory(replacementRoot.deletingLastPathComponent())
    try crashHook(.afterAccountIsolationDurability)

    var isolated = manifest
    isolated.activeStoreID = replacement.id
    isolated.stores[try storeIndex(id: replacement.id)].lifecycle = .ready
    isolated.stores[try storeIndex(id: active.id)].lifecycle = .isolated
    try crashHook(.beforeAccountIsolationPointerSwap)
    try commit(isolated)
    try crashHook(.afterAccountIsolationPointerSwap)
    return isolation
  }

  package func resolveAccountIsolation(
    _ choice: ICloudAccountIsolationChoice
  ) async throws {
    guard var isolation = manifest.accountIsolation else {
      throw SyncModePersistenceError.transitionInProgress
    }
    let requested: ICloudAccountIsolationResolution = choice == .keepLocalCopy
      ? .keepingLocalCopy : .removing
    guard isolation.resolution == .undecided || isolation.resolution == requested else {
      throw SyncModePersistenceError.transitionInProgress
    }
    if isolation.resolution == .undecided {
      isolation.resolution = requested
      var intended = manifest
      intended.accountIsolation = isolation
      try commit(intended)
      try crashHook(.afterAccountResolutionIntent)
    }
    try await reconcileAccountIsolationResolution()
  }

  package func reconcileAccountIsolationResolution() async throws {
    guard let isolation = manifest.accountIsolation,
      isolation.resolution != .undecided
    else { return }
    if isolation.resolution == .keepingLocalCopy {
      let sourceStore = try storeForIsolation(id: isolation.storeID)
      let source = try await libraryForTransition(storeID: sourceStore.id)
        .transferSnapshot(revision: sourceStore.revision)
      let target = try libraryForTransition(storeID: manifest.activeStoreID)
      _ = try await target.mergeTransferSnapshot(source, transitionID: isolation.id)
      try crashHook(.afterAccountLocalCopyMerge)
    }
    try finishAccountIsolationResolution(isolation)
  }

  private func finishAccountIsolationResolution(
    _ isolation: ICloudAccountIsolation
  ) throws {
    guard manifest.accountIsolation == isolation,
      isolation.resolution != .undecided,
      isolation.storeID != manifest.activeStoreID
    else { throw SyncModePersistenceError.transitionInProgress }
    let roots = try Self.validatedStoreRoots(manifest.stores, rootURL: rootURL)
    guard let isolatedRoot = roots[isolation.storeID] else {
      throw SyncModePersistenceError.invalidManifest
    }
    var deleting = manifest
    deleting.stores[try storeIndex(id: isolation.storeID)].lifecycle = .deleting
    let activeIndex = try storeIndex(id: manifest.activeStoreID)
    deleting.stores[activeIndex].revision += 1
    if isolation.resolution == .keepingLocalCopy {
      deleting.stores[activeIndex].quarantinedNamespace = isolation.namespace
    }
    deleting.accountIsolation = nil
    deleting.attentionReason = nil
    try crashHook(.beforeAccountIsolationRemovalCommit)
    try commit(deleting)
    try crashHook(.afterAccountIsolationRemovalCommit)
    do {
      if FileManager.default.fileExists(atPath: isolatedRoot.path) {
        try FileManager.default.removeItem(at: isolatedRoot)
      }
    } catch {
      try? recordAttention(.storageFailure)
      throw error
    }
    try crashHook(.afterAccountIsolationRootRemoval)
    var removed = manifest
    removed.stores.removeAll { $0.id == isolation.storeID }
    try commit(removed)
  }

  private func storeForIsolation(id: UUID) throws -> SyncModeStore {
    guard let value = store(id: id), value.lifecycle == .isolated else {
      throw SyncModePersistenceError.missingStore
    }
    return value
  }

  /// The only library later app assembly should retain.
  package func libraryForTransition(storeID: UUID) throws -> SwiftDataSnipLibrary {
    guard let store = manifest.stores.first(where: { $0.id == storeID }) else {
      throw SyncModePersistenceError.missingStore
    }
    guard store.lifecycle != .creating else { throw SyncModePersistenceError.missingStore }
    return try SwiftDataSnipLibrary(storeURL: storeURL(store).appendingPathComponent("snips.store"))
  }

  package func candidateRevision(transitionID: UUID) throws -> UInt64 {
    guard let transition = manifest.transition, transition.id == transitionID,
      let candidate = store(id: transition.candidateStoreID)
    else { throw SyncModePersistenceError.transitionInProgress }
    return candidate.revision
  }

  package func beginTransition(
    to targetKind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?
  ) throws -> SyncModeTransition {
    guard manifest.writeReservation == nil, !writeAdmissionInProgress,
      manifest.accountIsolation == nil
    else {
      throw SyncModePersistenceError.transitionInProgress
    }
    if let transition = manifest.transition {
      guard transition.targetKind == targetKind, transition.namespace == namespace else {
        throw SyncModePersistenceError.transitionInProgress
      }
      return transition
    }
    guard (targetKind == .iCloudSync) == (namespace != nil) else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    if targetKind == .iCloudSync,
      let quarantine = store(id: manifest.activeStoreID)?.quarantinedNamespace,
      quarantine != namespace
    {
      throw SyncModePersistenceError.namespaceMismatch
    }
    let syncProtocol = targetKind == .iCloudSync
      ? defaultSyncProtocol
      : try currentTransitionProtocolForOptOut()
    let candidate = Self.newStore(
      kind: targetKind,
      namespace: namespace,
      syncProtocol: syncProtocol
    )
    let transition = SyncModeTransition(
      id: UUID(),
      sourceStoreID: manifest.activeStoreID,
      candidateStoreID: candidate.id,
      targetKind: targetKind,
      namespace: namespace,
      syncProtocol: syncProtocol
    )
    var declared = manifest
    declared.stores.append(candidate)
    declared.transition = transition
    declared.attentionReason = nil
    try commit(declared)
    try crashHook(.afterCandidateManifest)
    do {
      try crashHook(.beforeCandidateDurability)
      let candidateRoot = storeURL(candidate)
      _ = try SwiftDataSnipLibrary(
        storeURL: candidateRoot.appendingPathComponent("snips.store", isDirectory: false)
      )
      try DurableFile.syncDirectory(candidateRoot)
      try DurableFile.syncDirectory(candidateRoot.deletingLastPathComponent())
      try crashHook(.afterCandidateDurability)
      var ready = manifest
      ready.stores[try storeIndex(id: candidate.id)].lifecycle = .ready
      ready.transition?.phase = .candidateReady
      try commit(ready)
      return try currentTransition()
    } catch {
      try? abortUnactivatedCandidate(reason: .storageFailure)
      throw error
    }
  }

  /// Fences an active-store mutation performed by a store-specific adapter.
  package func recordPreparationComplete() throws {
    guard manifest.transition?.phase == .candidateReady else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.transition?.phase = .remoteFetched
    next.attentionReason = nil
    try commit(next)
  }

  package func retryRemoteFetch() throws {
    guard let transition = manifest.transition,
      transition.phase == .remoteFetched,
      transition.sourceStoreID == manifest.activeStoreID,
      transition.freezeToken == nil,
      !transition.freezeSnapshotTaken,
      transition.mergeIntent == nil
    else { throw SyncModePersistenceError.transitionInProgress }
    var next = manifest
    next.transition?.phase = .candidateReady
    if next.attentionReason == .enrollmentBlocked {
      next.attentionReason = nil
    }
    try commit(next)
  }

  package func swapPointer() throws {
    guard let transition = manifest.transition, transition.phase == .firstSendComplete,
      store(id: transition.candidateStoreID)?.lifecycle == .ready
    else { throw SyncModePersistenceError.transitionInProgress }
    try crashHook(.beforePointerSwap)
    var next = manifest
    next.activeStoreID = transition.candidateStoreID
    next.stores[try storeIndex(id: transition.sourceStoreID)].lifecycle = .retired
    next.transition?.phase = .pointerSwapped
    next.transition?.freezeToken = nil
    try commit(next)
    try crashHook(.afterPointerSwap)
  }

  package func finishTransition() throws {
    guard manifest.transition?.phase == .pointerSwapped else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.transition = nil
    next.attentionReason = nil
    for index in next.stores.indices where next.stores[index].lifecycle == .retired {
      next.stores[index].lifecycle = .deleting
    }
    try commit(next)
    try crashHook(.afterRetiredCleanupDeclared)
  }

  package func unfreezeBeforePointerSwap(reason: ICloudSyncAttentionReason? = nil) throws {
    guard let transition = manifest.transition,
      transition.sourceStoreID == manifest.activeStoreID,
      [
        .sourceFrozen, .recordsMerged, .enrollmentApproved, .firstSendStarted,
        .firstSendComplete,
      ].contains(transition.phase)
    else { return }
    var next = manifest
    if next.transition?.mergeIntent != nil {
      Self.absorbMergeIntent(&next.transition!)
      next.transition?.phase = .candidateReady
    } else {
      next.transition?.phase = .remoteFetched
    }
    next.transition?.freezeToken = nil
    next.transition?.freezeSnapshotTaken = false
    next.transition?.approvedSnipIDs = []
    next.attentionReason = reason
    try commit(next)
  }
  package func recordAttention(_ reason: ICloudSyncAttentionReason) throws {
    var next = manifest
    next.attentionReason = reason
    try commit(next)
  }

  package func cleanupRetiredStores(limit: Int = 2) throws {
    let protected = Set([
      Optional(manifest.activeStoreID),
      manifest.transition?.sourceStoreID,
      manifest.transition?.candidateStoreID,
      manifest.accountIsolation?.storeID,
      manifest.accountIsolation?.replacementStoreID,
    ].compactMap { $0 })
    for value in manifest.stores
      .filter({ [.retired, .deleting].contains($0.lifecycle) && !protected.contains($0.id) })
      .prefix(limit)
    {
      if value.lifecycle == .retired {
        var deleting = manifest
        deleting.stores[try storeIndex(id: value.id)].lifecycle = .deleting
        try commit(deleting)
      }
      do {
        try FileManager.default.removeItem(at: storeURL(value))
        var removed = manifest
        removed.stores.removeAll { $0.id == value.id }
        try commit(removed)
      } catch {
        try? recordAttention(.storageFailure)
        throw error
      }
    }
  }

  private func currentTransition() throws -> SyncModeTransition {
    guard let transition = manifest.transition else { throw SyncModePersistenceError.transitionInProgress }
    return transition
  }

  func abortUnactivatedCandidate(reason: ICloudSyncAttentionReason) throws {
    guard let transition = manifest.transition, manifest.activeStoreID == transition.sourceStoreID else { return }
    var next = manifest
    if let candidate = store(id: transition.candidateStoreID) {
      do {
        if FileManager.default.fileExists(atPath: storeURL(candidate).path) {
          try FileManager.default.removeItem(at: storeURL(candidate))
        }
        next.stores.removeAll { $0.id == transition.candidateStoreID }
      } catch {
        next.stores[try storeIndex(id: candidate.id)].lifecycle = .deleting
      }
    }
    next.transition = nil
    next.attentionReason = reason
    try commit(next)
  }

  func store(id: UUID) -> SyncModeStore? {
    manifest.stores.first { $0.id == id }
  }

  func storeIndex(id: UUID) throws -> Int {
    guard let index = manifest.stores.firstIndex(where: { $0.id == id }) else {
      throw SyncModePersistenceError.missingStore
    }
    return index
  }

  func storeURL(_ store: SyncModeStore) -> URL {
    rootURL.appendingPathComponent(store.relativeRoot, isDirectory: true)
  }

  func commit(_ next: Manifest) throws {
    try Self.validate(next)
    do {
      try Self.write(next, to: manifestURL, using: manifestWriter)
    } catch {
      throw SyncModePersistenceError.storageFailure
    }
    manifest = next
  }

  private static func newStore(
    kind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?,
    syncProtocol: SyncModeSyncProtocol
  ) -> SyncModeStore {
    let id = UUID()
    return SyncModeStore(
      id: id,
      kind: kind,
      namespace: namespace,
      relativeRoot: "stores/\(kind.rawValue)-\(id.uuidString.lowercased())",
      syncProtocol: syncProtocol,
      revision: 0,
      lifecycle: .creating
    )
  }

  private func currentTransitionProtocolForOptOut() throws -> SyncModeSyncProtocol {
    guard let active = store(id: manifest.activeStoreID), active.kind == .iCloudSync else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    return active.syncProtocol
  }

}
