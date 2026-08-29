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
  case creating, ready, retired, deleting
}

package struct SyncModeStore: Codable, Equatable, Sendable {
  package let id: UUID
  package let kind: SyncModeStoreKind
  package let namespace: ICloudSyncNamespaceBinding?
  package let relativeRoot: String
  package var revision: UInt64
  package var lifecycle: SyncModeStoreLifecycle

  package init(
    id: UUID,
    kind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?,
    relativeRoot: String,
    revision: UInt64 = 0,
    lifecycle: SyncModeStoreLifecycle = .creating
  ) {
    self.id = id
    self.kind = kind
    self.namespace = namespace
    self.relativeRoot = relativeRoot
    self.revision = revision
    self.lifecycle = lifecycle
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

  package init(
    sourceSnipID: UUID,
    candidateSnipID: UUID,
    candidateRequestID: UUID,
    baseDigest: Data,
    baseRemoteDigest: Data,
    acceptedRecordIdentity: CloudTextStorageIdentity? = nil
  ) {
    self.sourceSnipID = sourceSnipID
    self.candidateSnipID = candidateSnipID
    self.candidateRequestID = candidateRequestID
    self.baseDigest = baseDigest
    self.baseRemoteDigest = baseRemoteDigest
    self.acceptedRecordIdentity = acceptedRecordIdentity
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
  package let snipID: UUID
  package let recordIdentity: CloudTextStorageIdentity
  package let kind: SyncModeSendOperationKind

  package init(
    snipID: UUID,
    recordIdentity: CloudTextStorageIdentity,
    kind: SyncModeSendOperationKind
  ) {
    self.snipID = snipID
    self.recordIdentity = recordIdentity
    self.kind = kind
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
}

package struct SyncModeTransition: Codable, Equatable, Sendable {
  package let id: UUID
  package let sourceStoreID: UUID
  package let candidateStoreID: UUID
  package let targetKind: SyncModeStoreKind
  package let namespace: ICloudSyncNamespaceBinding?
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
}

package enum ICloudSyncAttentionReason: String, Codable, Equatable, Sendable {
  case enrollmentBlocked, firstSyncFailed, namespaceChanged, transferConflict, storageFailure
  case storeReadFailed, terminalFetchFailure, transitionFailure
}

package struct SyncModeStorageSnapshot: Equatable, Sendable {
  package let activeStore: SyncModeStore
  package let transition: SyncModeTransition?
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

  fileprivate init(persistence: SwiftDataSyncModePersistence, storeID: UUID) {
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
  case beforePointerSwap
  case afterPointerSwap
  case afterRetiredCleanupDeclared
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

  private struct Manifest: Codable, Equatable {
    let version: Int
    var activeStoreID: UUID
    var stores: [SyncModeStore]
    var transition: SyncModeTransition?
    var attentionReason: ICloudSyncAttentionReason?
    var writeReservation: SyncModeWriteReservation?
  }

  private let rootURL: URL
  private let manifestURL: URL
  private let crashHook: @Sendable (SyncModeCrashPoint) throws -> Void
  private let manifestWriter: ManifestWriter
  private let writeHook: WriteHook
  private let readHook: ReadHook
  private var manifest: Manifest
  private var writeAdmissionInProgress = false

  package init(
    rootURL: URL,
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
      var store = Self.newStore(kind: .localOnly, namespace: nil)
      let declared = Manifest(
        version: 2,
        activeStoreID: store.id,
        stores: [store],
        transition: nil,
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
        attentionReason: nil,
        writeReservation: nil
      )
      try Self.write(manifest, to: manifestURL, using: manifestWriter)
    }
  }

  package func snapshot() throws -> SyncModeStorageSnapshot {
    guard let active = manifest.stores.first(where: { $0.id == manifest.activeStoreID }) else {
      throw SyncModePersistenceError.missingStore
    }
    return SyncModeStorageSnapshot(
      activeStore: active,
      transition: manifest.transition,
      attentionReason: manifest.attentionReason,
      hasActiveMutationReservation: manifest.writeReservation != nil
    )
  }

  /// The only library later app assembly should retain.
  package func activeLibrary() async throws -> any SnipLibrary {
    try reconcileWriteReservation()
    let initial = try await managedSnapshot(sortedBy: .chronological)
    return ModeManagedSnipLibrary(persistence: self, lastKnown: initial)
  }

  package func libraryForTransition(storeID: UUID) throws -> SwiftDataSnipLibrary {
    guard let store = manifest.stores.first(where: { $0.id == storeID }) else {
      throw SyncModePersistenceError.missingStore
    }
    guard store.lifecycle != .creating else { throw SyncModePersistenceError.missingStore }
    return try SwiftDataSnipLibrary(storeURL: storeURL(store).appendingPathComponent("snips.store"))
  }

  package func activeCloudMutationLease(storeID: UUID) throws -> SyncModeActiveMutationLease {
    guard storeID == manifest.activeStoreID, store(id: storeID)?.kind == .iCloudSync else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    return SyncModeActiveMutationLease(persistence: self, storeID: storeID)
  }

  package func beginTransition(
    to targetKind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?
  ) throws -> SyncModeTransition {
    guard manifest.writeReservation == nil, !writeAdmissionInProgress else {
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
    let candidate = Self.newStore(kind: targetKind, namespace: namespace)
    let transition = SyncModeTransition(
      id: UUID(),
      sourceStoreID: manifest.activeStoreID,
      candidateStoreID: candidate.id,
      targetKind: targetKind,
      namespace: namespace
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
  package func reserveActiveMutation(storeID: UUID? = nil) throws -> SyncModeWriteReservation {
    guard !writeAdmissionInProgress, manifest.writeReservation == nil,
      manifest.transition == nil
    else { throw SyncModePersistenceError.transitionInProgress }
    let activeID = manifest.activeStoreID
    guard storeID == nil || storeID == activeID else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    let revision = manifest.stores[try storeIndex(id: activeID)].revision + 1
    let reservation = SyncModeWriteReservation(
      id: UUID(),
      storeID: activeID,
      reservedRevision: revision
    )
    var next = manifest
    next.stores[try storeIndex(id: activeID)].revision = revision
    next.writeReservation = reservation
    try commit(next)
    return reservation
  }

  package func finishActiveMutation(_ reservation: SyncModeWriteReservation) throws {
    guard manifest.writeReservation == reservation else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.writeReservation = nil
    try commit(next)
  }

  package func recordPreparationComplete() throws {
    guard manifest.transition?.phase == .candidateReady else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.transition?.phase = .remoteFetched
    next.attentionReason = nil
    try commit(next)
  }

  package func freezeSource() throws -> SyncModeFreezeToken {
    guard manifest.writeReservation == nil, !writeAdmissionInProgress else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    guard var transition = next.transition, transition.phase == .remoteFetched,
      transition.sourceStoreID == next.activeStoreID,
      let source = next.stores.first(where: { $0.id == transition.sourceStoreID })
    else { throw SyncModePersistenceError.transitionInProgress }
    let token = SyncModeFreezeToken(id: UUID(), sourceStoreID: source.id, revision: source.revision)
    transition.phase = .sourceFrozen
    transition.freezeToken = token
    transition.freezeSnapshotTaken = false
    next.transition = transition
    try commit(next)
    return token
  }

  package func finalSnapshot(using token: SyncModeFreezeToken) async throws -> SnipLibraryTransferSnapshot {
    var next = manifest
    guard var transition = next.transition, transition.phase == .sourceFrozen,
      transition.freezeToken == token, !transition.freezeSnapshotTaken,
      store(id: token.sourceStoreID)?.revision == token.revision
    else { throw SyncModePersistenceError.invalidFreezeToken }
    transition.freezeSnapshotTaken = true
    next.transition = transition
    try commit(next)
    try readHook()
    return try await libraryForTransition(storeID: token.sourceStoreID)
      .transferSnapshot(revision: token.revision)
  }

  package func mergeFinalSnapshot(
    _ source: SnipLibraryTransferSnapshot,
    using token: SyncModeFreezeToken
  ) async throws -> SnipLibraryTransferResult {
    guard let transition = manifest.transition, transition.phase == .sourceFrozen,
      transition.freezeToken == token, transition.freezeSnapshotTaken,
      source.revision == token.revision,
      let candidateStore = store(id: transition.candidateStoreID)
    else { throw SyncModePersistenceError.invalidFreezeToken }
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    let candidateBefore = try await candidate.transferSnapshot(revision: candidateStore.revision)
    let acceptedTextBySnipID = try await candidate.acceptedCloudTextValues()
    let accepted = Set(acceptedTextBySnipID.keys)
    let plan = try SnipLibraryTransferPlanner.plan(
      source: source,
      target: candidateBefore,
      transitionID: transition.id,
      acceptedTargetSnipIDs: accepted,
      acceptedTargetTextBySnipID: acceptedTextBySnipID,
      priorSeedProvenance: transition.seedProvenance,
      priorServerAcceptedSnipIDs: transition.serverAcceptedSeedSnipIDs,
      priorSeededListIDs: transition.seededListIDs
    )
    let plannedCandidate = SnipLibraryTransferSnapshot(
      revision: candidateStore.revision,
      snips: plan.snips,
      lists: plan.lists,
      attachmentData: plan.attachmentData
    )
    let provenance = try Self.seedProvenance(
      approvedSnipIDs: plan.result.approvedSnipIDs,
      prior: transition.seedProvenance,
      source: source,
      candidate: plannedCandidate,
      transitionID: transition.id
    )
    let priorCandidateListIDs = Set(candidateBefore.lists.map(\.id))
    let seededListIDs = transition.seededListIDs.union(
      source.lists.map(\.id).filter { !priorCandidateListIDs.contains($0) }
    )
    let intent = SyncModeMergeIntent(
      id: UUID(),
      sourceRevision: source.revision,
      planDigest: plan.digest,
      approvedSnipIDs: plan.result.approvedSnipIDs,
      recoveredSourceSnipIDs: plan.result.recoveredSourceSnipIDs,
      seedProvenance: provenance,
      seededListIDs: seededListIDs
    )
    var intended = manifest
    intended.transition?.mergeIntent = intent
    try commit(intended)
    try crashHook(.beforeCandidateMergeDurability)
    _ = try await candidate.applyTransferPlan(plan, currentRevision: candidateStore.revision)
    try crashHook(.afterCandidateMergeDurability)
    guard manifest.transition?.mergeIntent == intent else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.transition?.phase = .recordsMerged
    next.transition?.approvedSnipIDs = intent.approvedSnipIDs
    next.transition?.pendingSettlementSnipIDs = []
    next.transition?.sendAttempt = nil
    next.transition?.seedProvenance = intent.seedProvenance
    next.transition?.seededListIDs = intent.seededListIDs
    next.transition?.mergeIntent = nil
    try commit(next)
    return SnipLibraryTransferResult(
      approvedSnipIDs: intent.approvedSnipIDs,
      recoveredSourceSnipIDs: intent.recoveredSourceSnipIDs
    )
  }

  package func recordEnrollmentApproved(expected: Set<UUID>) throws {
    guard manifest.transition?.phase == .recordsMerged,
      manifest.transition?.approvedSnipIDs == expected
    else { throw SyncModePersistenceError.transitionInProgress }
    try crashHook(.afterEnrollmentApproval)
    try changeTransition(from: .recordsMerged, to: .enrollmentApproved)
  }

  package func recordFirstSendStarted() throws {
    try crashHook(.afterFirstSendStarted)
    guard manifest.transition?.phase == .enrollmentApproved else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.transition?.phase = .firstSendStarted
    next.transition?.pendingSettlementSnipIDs = []
    next.transition?.sendAttempt = nil
    try commit(next)
  }

  package func recordSendAttempt(_ attempt: SyncModeSendAttempt) throws {
    guard let transition = manifest.transition,
      transition.phase == .firstSendStarted,
      transition.namespace == attempt.namespace
    else { throw SyncModePersistenceError.namespaceMismatch }
    let allowedZones = attempt.namespace.zones
    guard attempt.operations.allSatisfy({ operation in
      allowedZones.contains(
        ICloudSyncZoneBinding(
          name: operation.recordIdentity.zoneName,
          ownerName: operation.recordIdentity.ownerName
        )
      )
    }) else { throw SyncModePersistenceError.namespaceMismatch }

    var operations = transition.sendAttempt?.operations ?? []
    for operation in attempt.operations {
      if let existing = operations.first(where: { $0.snipID == operation.snipID }) {
        guard existing == operation else { throw SyncModePersistenceError.invalidManifest }
      } else {
        operations.append(operation)
      }
    }
    operations.sort {
      if $0.snipID != $1.snipID { return $0.snipID.uuidString < $1.snipID.uuidString }
      return $0.recordIdentity.key < $1.recordIdentity.key
    }
    var next = manifest
    let saved = SyncModeSendAttempt(namespace: attempt.namespace, operations: operations)
    next.transition?.sendAttempt = saved
    next.transition?.pendingSettlementSnipIDs = Set(operations.map(\.snipID))
    try crashHook(.beforeSendAttemptManifest)
    try commit(next)
  }

  package func recordFirstSendComplete() throws {
    try crashHook(.afterFirstSendComplete)
    try changeTransition(from: .firstSendStarted, to: .firstSendComplete)
  }

  package func recordNoSendRequired() throws {
    guard manifest.transition?.targetKind == .localOnly else {
      throw SyncModePersistenceError.transitionInProgress
    }
    try changeTransition(from: .enrollmentApproved, to: .firstSendComplete)
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

  package func restartAfterFirstSendFailure(
    reason: ICloudSyncAttentionReason?,
    settlement: SyncModeSeedSettlementProof?
  ) async throws {
    guard let transition = manifest.transition,
      transition.sourceStoreID == manifest.activeStoreID,
      [.enrollmentApproved, .firstSendStarted, .firstSendComplete].contains(transition.phase)
    else { return }
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    let accepted = try await candidate.acceptedCloudTextSnipIDs()
    let seedIDs = Set(transition.seedProvenance.map(\.candidateSnipID))
    let settled = try await settledSeedProvenance(
      transition: transition,
      accepted: accepted,
      settlement: settlement
    )
    var next = manifest
    next.transition?.supersededApprovedSnipIDs.formUnion(transition.approvedSnipIDs)
    next.transition?.serverAcceptedSeedSnipIDs.formUnion(accepted.intersection(seedIDs))
    next.transition?.seedProvenance = settled
    next.transition?.pendingSettlementSnipIDs = []
    next.transition?.sendAttempt = nil
    next.transition?.captureAcceptedServerProvenance = false
    next.transition?.phase = .candidateReady
    next.transition?.freezeToken = nil
    next.transition?.freezeSnapshotTaken = false
    next.transition?.approvedSnipIDs = []
    next.attentionReason = reason
    try commit(next)
  }

  package func prepareRetryFetch(settlement: SyncModeSeedSettlementProof) async throws {
    guard let transition = manifest.transition, transition.phase == .candidateReady,
      transition.captureAcceptedServerProvenance
    else { return }
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    let accepted = try await candidate.acceptedCloudTextSnipIDs()
    let seedIDs = Set(transition.seedProvenance.map(\.candidateSnipID))
    let settled = try await settledSeedProvenance(
      transition: transition,
      accepted: accepted,
      settlement: settlement
    )
    var next = manifest
    next.transition?.serverAcceptedSeedSnipIDs.formUnion(accepted.intersection(seedIDs))
    next.transition?.seedProvenance = settled
    next.transition?.pendingSettlementSnipIDs = []
    next.transition?.sendAttempt = nil
    next.transition?.captureAcceptedServerProvenance = false
    try commit(next)
  }

  package func recordAttention(_ reason: ICloudSyncAttentionReason) throws {
    var next = manifest
    next.attentionReason = reason
    try commit(next)
  }

  package func requireActiveNamespace(_ namespace: ICloudSyncNamespaceBinding) throws {
    guard let active = store(id: manifest.activeStoreID), active.kind == .iCloudSync,
      active.namespace == namespace
    else { throw SyncModePersistenceError.namespaceMismatch }
  }

  package func cleanupRetiredStores(limit: Int = 2) throws {
    let protected = Set([
      Optional(manifest.activeStoreID),
      manifest.transition?.sourceStoreID,
      manifest.transition?.candidateStoreID,
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

  fileprivate func managedSnapshot(sortedBy: SnipSortMode) async throws -> SnipLibrarySnapshot {
    try readHook()
    return try await libraryForTransition(storeID: manifest.activeStoreID)
      .checkedSnapshot(sortedBy: sortedBy)
  }

  fileprivate func managedPerform(
    _ command: SnipLibraryCommand,
    sortedBy: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    guard !writeAdmissionInProgress, manifest.writeReservation == nil else {
      throw SnipLibraryError.modeTransitionInProgress
    }
    if let transition = manifest.transition,
      transition.sourceStoreID == manifest.activeStoreID,
      [
        .sourceFrozen, .recordsMerged, .enrollmentApproved, .firstSendStarted,
        .firstSendComplete,
      ].contains(transition.phase)
    { throw SnipLibraryError.modeTransitionInProgress }
    writeAdmissionInProgress = true
    defer { writeAdmissionInProgress = false }
    let activeID = manifest.activeStoreID
    let reservedRevision = manifest.stores[try storeIndex(id: activeID)].revision + 1
    var reserved = manifest
    reserved.stores[try storeIndex(id: activeID)].revision = reservedRevision
    reserved.writeReservation = SyncModeWriteReservation(
      id: UUID(),
      storeID: activeID,
      reservedRevision: reservedRevision
    )
    try commit(reserved)
    try await writeHook(.afterRevisionReserved)
    do {
      let update = try await libraryForTransition(storeID: activeID)
        .perform(command, sortedBy: sortedBy)
      try await writeHook(.beforeReservationCleared)
      var completed = manifest
      completed.writeReservation = nil
      try commit(completed)
      return update
    } catch {
      guard error is SnipLibraryError || error is SyncModePersistenceError else {
        // Test crash hooks model process loss. Leave the durable reservation for reopen.
        throw error
      }
      var cleared = manifest
      cleared.writeReservation = nil
      try? commit(cleared)
      throw error
    }
  }

  fileprivate func recordStoreReadFailure() {
    try? recordAttention(.storeReadFailed)
  }

  private func changeTransition(from: SyncModeTransitionPhase, to: SyncModeTransitionPhase) throws {
    guard manifest.transition?.phase == from else { throw SyncModePersistenceError.transitionInProgress }
    var next = manifest
    next.transition?.phase = to
    try commit(next)
  }

  private func reconcileWriteReservation() throws {
    guard manifest.writeReservation != nil else { return }
    var next = manifest
    next.writeReservation = nil
    try commit(next)
  }

  private func settledSeedProvenance(
    transition: SyncModeTransition,
    accepted: Set<UUID>,
    settlement: SyncModeSeedSettlementProof?
  ) async throws -> [SyncModeSeedProvenance] {
    guard settlement?.namespace == transition.namespace else { return transition.seedProvenance }
    let source = try await libraryForTransition(storeID: transition.sourceStoreID)
      .transferSnapshot(revision: 0)
    let candidate = try await libraryForTransition(storeID: transition.candidateStoreID)
      .transferSnapshot(revision: 0)
    let sourceIDs = Set(source.snips.map(\.id))
    let candidateByID = Dictionary(uniqueKeysWithValues: candidate.snips.map { ($0.id, $0) })
    let knownAccepted = transition.serverAcceptedSeedSnipIDs.union(accepted)
    return transition.seedProvenance.map { value in
      if transition.pendingSettlementSnipIDs.contains(value.candidateSnipID),
        case .saved(let identity, let acceptedText) = settlement?.values[value.candidateSnipID],
        accepted.contains(value.candidateSnipID),
        let snip = candidateByID[value.candidateSnipID],
        snip.content == acceptedText
      {
        return SyncModeSeedProvenance(
          sourceSnipID: value.sourceSnipID,
          candidateSnipID: value.candidateSnipID,
          candidateRequestID: value.candidateRequestID,
          baseDigest: SnipLibraryTransferPlanner.digest(
            snip: snip,
            attachmentData: candidate.attachmentData
          ),
          baseRemoteDigest: SnipLibraryTransferPlanner.remoteDigest(snip: snip),
          acceptedRecordIdentity: identity
        )
      }
      if !sourceIDs.contains(value.sourceSnipID),
        candidateByID[value.candidateSnipID] == nil,
        knownAccepted.contains(value.candidateSnipID),
        !accepted.contains(value.candidateSnipID),
        case .deleted(let identity) = settlement?.values[value.candidateSnipID],
        identity == value.acceptedRecordIdentity
      {
        return SyncModeSeedProvenance(
          sourceSnipID: value.sourceSnipID,
          candidateSnipID: value.candidateSnipID,
          candidateRequestID: value.candidateRequestID,
          baseDigest: SnipLibraryTransferPlanner.digest(snip: nil, attachmentData: [:]),
          baseRemoteDigest: SnipLibraryTransferPlanner.remoteDigest(snip: nil),
          acceptedRecordIdentity: identity
        )
      }
      return value
    }
  }

  private func currentTransition() throws -> SyncModeTransition {
    guard let transition = manifest.transition else { throw SyncModePersistenceError.transitionInProgress }
    return transition
  }

  private func abortUnactivatedCandidate(reason: ICloudSyncAttentionReason) throws {
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

  private func store(id: UUID) -> SyncModeStore? {
    manifest.stores.first { $0.id == id }
  }

  private func storeIndex(id: UUID) throws -> Int {
    guard let index = manifest.stores.firstIndex(where: { $0.id == id }) else {
      throw SyncModePersistenceError.missingStore
    }
    return index
  }

  private func storeURL(_ store: SyncModeStore) -> URL {
    rootURL.appendingPathComponent(store.relativeRoot, isDirectory: true)
  }

  private func commit(_ next: Manifest) throws {
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
    namespace: ICloudSyncNamespaceBinding?
  ) -> SyncModeStore {
    let id = UUID()
    return SyncModeStore(
      id: id,
      kind: kind,
      namespace: namespace,
      relativeRoot: "stores/\(kind.rawValue)-\(id.uuidString.lowercased())",
      revision: 0,
      lifecycle: .creating
    )
  }

  private static func seedProvenance(
    approvedSnipIDs: Set<UUID>,
    prior: [SyncModeSeedProvenance],
    source: SnipLibraryTransferSnapshot,
    candidate: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) throws -> [SyncModeSeedProvenance] {
    let sourceByID = Dictionary(uniqueKeysWithValues: source.snips.map { ($0.id, $0) })
    let candidateByID = Dictionary(uniqueKeysWithValues: candidate.snips.map { ($0.id, $0) })
    var valuesByCandidate = Dictionary(
      uniqueKeysWithValues: prior.map { ($0.candidateSnipID, $0) }
    )
    let priorCandidateIDs = Set(valuesByCandidate.keys)
    for candidateID in approvedSnipIDs.subtracting(priorCandidateIDs) {
      guard let candidateSnip = candidateByID[candidateID] else {
        throw SyncModePersistenceError.storageFailure
      }
      let sourceID: UUID
      if sourceByID[candidateID] != nil {
        sourceID = candidateID
      } else if let recoveredSource = source.snips.first(where: {
        SnipLibraryTransferPlanner.derivedUUID(transitionID: transitionID, sourceID: $0.id)
          == candidateID
      }) {
        sourceID = recoveredSource.id
      } else {
        throw SyncModePersistenceError.storageFailure
      }
      valuesByCandidate[candidateID] = SyncModeSeedProvenance(
        sourceSnipID: sourceID,
        candidateSnipID: candidateID,
        candidateRequestID: candidateSnip.requestID,
        baseDigest: SnipLibraryTransferPlanner.digest(
          snip: candidateSnip,
          attachmentData: candidate.attachmentData
        ),
        baseRemoteDigest: SnipLibraryTransferPlanner.remoteDigest(snip: candidateSnip)
      )
    }
    return valuesByCandidate.values.sorted {
      $0.candidateSnipID.uuidString < $1.candidateSnipID.uuidString
    }
  }

  private static func recover(_ value: inout Manifest, rootURL: URL) throws {
    // The revision advances before the store write starts. A leftover reservation means the
    // write may or may not have reached SwiftData, so keep that revision and reopen writes.
    value.writeReservation = nil
    if let activeIndex = value.stores.firstIndex(where: { $0.id == value.activeStoreID }),
      value.stores[activeIndex].lifecycle == .creating
    {
      let root = rootURL.appendingPathComponent(value.stores[activeIndex].relativeRoot, isDirectory: true)
      _ = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("snips.store"))
      value.stores[activeIndex].lifecycle = .ready
    }
    let removable = value.stores.filter {
      $0.id != value.activeStoreID && ($0.lifecycle == .creating || $0.lifecycle == .deleting)
    }.prefix(2)
    for store in removable {
      let storeRoot = rootURL.appendingPathComponent(store.relativeRoot, isDirectory: true)
      do {
        if FileManager.default.fileExists(atPath: storeRoot.path) {
          try FileManager.default.removeItem(at: storeRoot)
        }
        value.stores.removeAll { $0.id == store.id }
        if value.transition?.candidateStoreID == store.id { value.transition = nil }
      } catch {
        value.attentionReason = .storageFailure
      }
    }
    if var transition = value.transition,
      [
        SyncModeTransitionPhase.sourceFrozen, .recordsMerged, .enrollmentApproved,
        .firstSendStarted, .firstSendComplete,
      ].contains(transition.phase)
    {
      absorbMergeIntent(&transition)
      value.transition = transition
      value.transition?.supersededApprovedSnipIDs.formUnion(transition.approvedSnipIDs)
      value.transition?.captureAcceptedServerProvenance = true
      value.transition?.phase = .candidateReady
      value.transition?.freezeToken = nil
      value.transition?.freezeSnapshotTaken = false
      value.transition?.approvedSnipIDs = []
    }
  }

  private static func absorbMergeIntent(_ transition: inout SyncModeTransition) {
    guard let intent = transition.mergeIntent else { return }
    transition.seedProvenance = intent.seedProvenance
    transition.seededListIDs = intent.seededListIDs
    transition.supersededApprovedSnipIDs.formUnion(intent.approvedSnipIDs)
    transition.pendingSettlementSnipIDs = []
    transition.sendAttempt = nil
    transition.mergeIntent = nil
  }

  private static func validate(_ value: Manifest) throws {
    guard value.version == 2,
      let active = value.stores.first(where: { $0.id == value.activeStoreID }),
      active.lifecycle == .ready || active.lifecycle == .retired,
      Set(value.stores.map(\.id)).count == value.stores.count
    else { throw SyncModePersistenceError.invalidManifest }
    for store in value.stores {
      guard (store.kind == .iCloudSync) == (store.namespace != nil),
        !store.relativeRoot.contains(".."), store.relativeRoot.hasPrefix("stores/")
      else { throw SyncModePersistenceError.invalidManifest }
    }
    if let reservation = value.writeReservation {
      guard let store = value.stores.first(where: { $0.id == reservation.storeID }),
        store.id == value.activeStoreID,
        store.revision == reservation.reservedRevision
      else { throw SyncModePersistenceError.invalidManifest }
    }
    if let transition = value.transition {
      if let intent = transition.mergeIntent {
        guard transition.phase == .sourceFrozen,
          transition.freezeSnapshotTaken,
          transition.freezeToken?.revision == intent.sourceRevision,
          intent.planDigest.count == 32,
          intent.approvedSnipIDs.isSubset(of: Set(intent.seedProvenance.map(\.candidateSnipID)))
        else { throw SyncModePersistenceError.invalidManifest }
      }
      if let attempt = transition.sendAttempt {
        let operationIDs = Set(attempt.operations.map(\.snipID))
        let operationIdentities = Set(attempt.operations.map(\.recordIdentity))
        guard attempt.namespace == transition.namespace,
          transition.pendingSettlementSnipIDs == operationIDs,
          operationIdentities.count == attempt.operations.count,
          attempt.operations.allSatisfy({ operation in
            attempt.namespace.zones.contains(
              ICloudSyncZoneBinding(
                name: operation.recordIdentity.zoneName,
                ownerName: operation.recordIdentity.ownerName
              )
            )
          })
        else { throw SyncModePersistenceError.invalidManifest }
      } else if !transition.pendingSettlementSnipIDs.isEmpty {
        throw SyncModePersistenceError.invalidManifest
      }
    }
  }

  private static func write(
    _ manifest: Manifest,
    to url: URL,
    using writer: ManifestWriter
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try writer(encoder.encode(manifest), url)
  }
}

private actor ModeManagedSnipLibrary: SnipLibrary {
  let persistence: SwiftDataSyncModePersistence
  private var lastKnown: SnipLibrarySnapshot

  init(persistence: SwiftDataSyncModePersistence, lastKnown: SnipLibrarySnapshot) {
    self.persistence = persistence
    self.lastKnown = lastKnown
  }

  func snapshot(sortedBy sortMode: SnipSortMode) async -> SnipLibrarySnapshot {
    do {
      return try await checkedSnapshot(sortedBy: sortMode)
    } catch {
      return lastKnown
    }
  }

  func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot {
    do {
      let snapshot = try await persistence.managedSnapshot(sortedBy: sortMode)
      lastKnown = snapshot
      return snapshot
    } catch {
      await persistence.recordStoreReadFailure()
      throw error
    }
  }

  func perform(
    _ command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    let update = try await persistence.managedPerform(command, sortedBy: sortMode)
    lastKnown = update.snapshot
    return update
  }

  func transferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot {
    throw SnipLibraryError.transferUnsupported
  }

  func mergeTransferSnapshot(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) async throws -> SnipLibraryTransferResult {
    throw SnipLibraryError.transferUnsupported
  }
}
