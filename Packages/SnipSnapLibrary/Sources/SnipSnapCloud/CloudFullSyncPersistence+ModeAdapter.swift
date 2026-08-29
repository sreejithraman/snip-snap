import Foundation
import SnipSnapCore
import SnipSnapPersistence

package enum CloudFullReenableError: Error, Equatable, Sendable {
  case deferredDependencies
}

private struct CloudModeRecoveryPayload: Codable, Equatable {
  let storageVersion: Int
  let sourceID: UUID
  let recoveredID: UUID?
  let deletedListID: UUID?
  let recoveredList: CloudListMergeFields?

  init(
    sourceID: UUID,
    recoveredID: UUID? = nil,
    deletedListID: UUID? = nil,
    recoveredList: CloudListMergeFields? = nil
  ) {
    storageVersion = 1
    self.sourceID = sourceID
    self.recoveredID = recoveredID
    self.deletedListID = deletedListID
    self.recoveredList = recoveredList
  }
}

extension CloudFullSyncPersistence {
  package func approveEnrollment(references: Set<CloudEntityReference>) async throws {
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let dependencies = Dictionary(uniqueKeysWithValues: local.snips.map { ($0.id, $0.listID) })
    try await library.setCloudEnrollment(
      namespaceKey: namespaceKey,
      references: references,
      localDependencies: dependencies
    )
  }

  package func approveModeMerge(snipIDs: Set<UUID>) async throws {
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let availableSnips = Dictionary(uniqueKeysWithValues: local.snips.map { ($0.id, $0) })
    guard snipIDs.allSatisfy({ availableSnips[$0] != nil }) else {
      throw CloudNamespaceEnrollmentError.invalidSeedSelection
    }
    var references = Set(local.lists.map {
      CloudEntityReference(kind: .list, domainID: $0.id)
    })
    references.insert(CloudEntityReference(kind: .list, domainID: SnipList.inbox.id))
    references.formUnion(snipIDs.map { CloudEntityReference(kind: .snip, domainID: $0) })
    try await approveEnrollment(references: references)
  }

  package func currentModeSeedSettlement(
    candidates: [SyncModeSeedSettlementCandidate],
    namespace expectedNamespace: ICloudSyncNamespaceBinding
  ) async throws -> SyncModeSeedSettlementProof {
    let actual = Self.binding(namespace)
    guard actual == expectedNamespace else { throw SyncModePersistenceError.namespaceMismatch }
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let localByID = Dictionary(uniqueKeysWithValues: local.snips.map { ($0.id, $0) })
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let accepted = Dictionary(uniqueKeysWithValues:
      (stored.readyEntities + stored.deferredEntities).map { ($0.reference, $0) }
    )
    var values: [UUID: SyncModeSeedSettlementValue] = [:]
    for candidate in candidates {
      let reference = CloudEntityReference(kind: .snip, domainID: candidate.snipID)
      if let entity = accepted[reference], let local = localByID[candidate.snipID],
        candidate.acceptedRecordIdentity == nil
          || candidate.acceptedRecordIdentity == entity.identity,
        try Self.snipFields(Self.snipRecord(entity)).text == local.content,
        !stored.conflicts.contains(where: { $0.reference == reference })
      {
        values[candidate.snipID] = .saved(
          recordIdentity: entity.identity,
          acceptedText: local.content
        )
      } else if localByID[candidate.snipID] == nil,
        accepted[reference] == nil,
        let identity = candidate.acceptedRecordIdentity
      {
        values[candidate.snipID] = .deleted(recordIdentity: identity)
      }
    }
    return SyncModeSeedSettlementProof(namespace: actual, values: values)
  }

  package func prepareModeRetry(snipIDs: Set<UUID>) async throws {
    _ = snipIDs
  }

  package func modeSendAttempt(
    for outbound: CloudOutboundBatch,
    namespace expectedNamespace: ICloudSyncNamespaceBinding
  ) async throws -> SyncModeSendAttempt {
    let actual = Self.binding(namespace)
    guard actual == expectedNamespace else { throw SyncModePersistenceError.namespaceMismatch }
    var operations: [SyncModeSendOperation] = []
    for operation in outbound.operations {
      let id = operation.id
      guard namespace.zones.contains(id.zone),
        let reference = Self.reference(for: id)
      else { throw SyncModePersistenceError.namespaceMismatch }
      operations.append(
        SyncModeSendOperation(
          reference: reference,
          recordIdentity: Self.storageIdentity(id),
          kind: {
            switch operation {
            case .save: .save
            case .delete: .delete
            }
          }()
        )
      )
    }
    guard Set(operations.map(\.recordIdentity)).count == operations.count else {
      throw SyncModePersistenceError.invalidManifest
    }
    return SyncModeSendAttempt(namespace: actual, operations: operations)
  }
  package func enrollmentEvidence() async throws -> CloudTextEnrollmentEvidence {
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let recovery = try await library.cloudFullRecoveryEvents(namespaceKey: namespaceKey)
    let retryable = recovery.filter(Self.isRetryableRecovery)
    let pending = try await pendingChanges()
    return CloudTextEnrollmentEvidence(
      phase: stored.namespaceState.phase,
      hasPendingChanges: !pending.operations.isEmpty || !pending.zonesToSave.isEmpty,
      hasRetryableRecordFailures: !retryable.isEmpty,
      retryableEventKeys: Set(retryable.map(Self.recoveryKey)),
      needsAttention: stored.namespaceState.phase == .blocked
        || recovery.contains { !Self.isRetryableRecovery($0) }
        || !stored.conflicts.isEmpty
        || !stored.quarantines.isEmpty
    )
  }

  package func statusEvidence() async throws -> CloudTextEnrollmentEvidence {
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let recovery = try await library.cloudFullRecoveryEvents(namespaceKey: namespaceKey)
    let retryable = recovery.filter(Self.isRetryableRecovery)
    return CloudTextEnrollmentEvidence(
      phase: stored.namespaceState.phase,
      hasPendingChanges: false,
      hasRetryableRecordFailures: !retryable.isEmpty,
      retryableEventKeys: Set(retryable.map(Self.recoveryKey)),
      needsAttention: stored.namespaceState.phase == .blocked
        || recovery.contains { !Self.isRetryableRecovery($0) }
        || !stored.conflicts.isEmpty
        || !stored.quarantines.isEmpty
    )
  }

  package func acceptedSnipTextValues() async throws -> [UUID: String] {
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    var values: [UUID: String] = [:]
    for entity in stored.readyEntities + stored.deferredEntities
      where entity.reference.kind == .snip
    {
      let text = try Self.snipFields(Self.snipRecord(entity)).text
      guard values.updateValue(text, forKey: entity.reference.domainID) == nil else {
        throw CloudFullStorageError.invalidLegacyRecord
      }
    }
    return values
  }

  package func dormantAcceptedBaseTransferPayload() async throws -> Data {
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let prior = try await library.dormantCloudBases()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let priorBundle = try CloudDormantAcceptedBaseBundle(entries: prior.map {
      CloudDormantAcceptedBaseBundle.Entry(
        namespaceKey: $0.namespaceKey,
        reference: $0.reference,
        identity: $0.identity,
        payload: $0.payload
      )
    })
    let acceptedBundle = try CloudDormantAcceptedBaseBundle(entries:
      (stored.readyEntities + stored.deferredEntities).map { entity in
        CloudDormantAcceptedBaseBundle.Entry(
          namespaceKey: namespaceKey,
          reference: entity.reference,
          identity: entity.identity,
          payload: try encoder.encode(Self.acceptedInput(entity))
        )
      }
    )
    return try priorBundle.merging(acceptedBundle).encoded()
  }

  package func isReenableReady() async throws -> Bool {
    try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
      .deferredEntities.isEmpty
  }

  package func makeReenableApplyPlan(
    source: SnipLibraryTransferSnapshot,
    transitionID: UUID,
    targetRevision: UInt64
  ) async throws -> CloudFullReenableApplyPlan? {
    let sourceBundle = try CloudDormantAcceptedBaseBundle.decode(source.opaqueSyncStatePayload)
    let exactEntries = sourceBundle.entries.filter { $0.namespaceKey == namespaceKey }
    guard !exactEntries.isEmpty else { return nil }
    let allowedZones = Set(namespace.zones.map { "\($0.ownerName)|\($0.name)" })
    var bases: [CloudEntityReference: CloudAcceptedEntity] = [:]
    for entry in exactEntries {
      guard allowedZones.contains("\(entry.identity.ownerName)|\(entry.identity.zoneName)"),
        let input = try? JSONDecoder().decode(CloudAcceptedEntityInput.self, from: entry.payload),
        input.reference == entry.reference,
        input.identity == entry.identity
      else { continue }
      bases[entry.reference] = Self.materializedEntity(input)
    }
    guard !bases.isEmpty else { return nil }

    let target = try await library.transferSnapshot(revision: targetRevision)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    guard stored.deferredEntities.isEmpty else {
      throw CloudFullReenableError.deferredDependencies
    }
    let acceptedValues = stored.readyEntities + stored.deferredEntities
    let accepted = Dictionary(uniqueKeysWithValues: acceptedValues.map { ($0.reference, $0) })
    var adjustedLists = source.lists
    var adjustedSnips = source.snips
    var replacingLists: Set<UUID> = []
    var replacingSnips: Set<UUID> = []
    var deletedLists: Set<UUID> = []
    var conflicts: [CloudConflictInput] = []
    var recoveryInputs: [CloudFullRecoveryInput] = []
    var recoveredSourceIDs: Set<UUID> = []
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    for index in adjustedLists.indices.reversed() {
      let local = adjustedLists[index]
      let reference = CloudEntityReference(kind: .list, domainID: local.id)
      guard let base = bases[reference] else { continue }
      guard let server = accepted[reference], server.identity == base.identity else {
        let baseFields = try Self.listFields(Self.listRecord(base))
        let localFields = Self.listFields(local, updatedAt: baseFields.updatedAt)
        if !Self.sameListFields(baseFields, localFields) {
          recoveryInputs.append(try Self.modeRecovery(
            transitionID: transitionID,
            namespaceKey: namespaceKey,
            sourceID: local.id,
            kind: .modeRecoveredList,
            payload: CloudModeRecoveryPayload(
              sourceID: local.id,
              deletedListID: local.id,
              recoveredList: localFields
            )
          ))
        }
        adjustedLists.remove(at: index)
        deletedLists.insert(local.id)
        continue
      }
      let baseFields = try Self.listFields(Self.listRecord(base))
      let serverFields = try Self.listFields(Self.listRecord(server))
      let result = try CloudThreeWayMerge.list(
        base: baseFields,
        local: Self.listFields(local, updatedAt: serverFields.updatedAt),
        server: serverFields
      )
      adjustedLists[index] = Self.localList(result.merged)
      replacingLists.insert(local.id)
      if let payload = result.conflict {
        let key = CloudConflictKey.make(
          namespaceKey: namespaceKey,
          recordID: Self.recordID(server.identity),
          ancestorSystemFields: base.systemFields,
          serverSystemFields: server.systemFields
        )
        conflicts.append(CloudConflictInput(
          key: key,
          reference: reference,
          format: .listMergeV1,
          payload: try encoder.encode(payload),
          recovery: .list(Self.recoveredList(payload, key: key))
        ))
      }
    }

    for index in adjustedSnips.indices.reversed() {
      var local = adjustedSnips[index]
      let reference = CloudEntityReference(kind: .snip, domainID: local.id)
      if deletedLists.contains(local.listID) {
        let deletedListID = local.listID
        local = Self.replacing(local, listID: SnipList.inbox.id)
        adjustedSnips[index] = local
        recoveryInputs.append(try Self.modeRecovery(
          transitionID: transitionID,
          namespaceKey: namespaceKey,
          sourceID: local.id,
          kind: .modeDeletedListPlacement,
          payload: CloudModeRecoveryPayload(sourceID: local.id, deletedListID: deletedListID)
        ))
      }
      guard let base = bases[reference] else { continue }
      guard let server = accepted[reference], server.identity == base.identity else {
        let baseFields = try Self.snipFields(Self.snipRecord(base))
        let localFields = Self.snipFields(local, accepted: try Self.snipRecord(base))
        if Self.sameSnipFields(baseFields, localFields), local.attachments.isEmpty {
          adjustedSnips.remove(at: index)
          continue
        }
        let recoveredID = SnipLibraryTransferPlanner.derivedUUID(
          transitionID: transitionID,
          sourceID: local.id
        )
        let recovered = Self.recovered(local, id: recoveredID, listID: SnipList.inbox.id)
        adjustedSnips[index] = recovered
        recoveredSourceIDs.insert(local.id)
        recoveryInputs.append(try Self.modeRecovery(
          transitionID: transitionID,
          namespaceKey: namespaceKey,
          sourceID: local.id,
          kind: .modeRecoveredSnip,
          payload: CloudModeRecoveryPayload(sourceID: local.id, recoveredID: recoveredID)
        ))
        continue
      }
      let baseRecord = try Self.snipRecord(base)
      let result = try CloudThreeWayMerge.snip(
        base: try Self.snipFields(baseRecord),
        local: Self.snipFields(local, accepted: baseRecord),
        server: try Self.snipFields(Self.snipRecord(server))
      )
      adjustedSnips[index] = Self.snip(result.merged, attachments: local.attachments)
      replacingSnips.insert(local.id)
      if let payload = result.conflict {
        let key = CloudConflictKey.make(
          namespaceKey: namespaceKey,
          recordID: Self.recordID(server.identity),
          ancestorSystemFields: base.systemFields,
          serverSystemFields: server.systemFields
        )
        let recoveredID = SnipLibraryTransferPlanner.derivedUUID(
          transitionID: transitionID,
          sourceID: local.id
        )
        let recovered = Self.recovered(
          local,
          id: recoveredID,
          listID: adjustedLists.contains(where: { $0.id == local.listID })
            ? local.listID : SnipList.inbox.id
        )
        let review = RecoveredSnip(
          id: recoveredID,
          currentSnipID: local.id,
          recovered: recovered,
          conflictingFields: Set(payload.fields.map { field in
            switch field {
            case .text: .text
            case .source: .source
            case .isDone: .done
            case .placement: .placement
            }
          })
        )
        conflicts.append(CloudConflictInput(
          key: key,
          reference: reference,
          format: .snipMergeV1,
          payload: try encoder.encode(payload),
          recovery: .snip(review)
        ))
        adjustedSnips.append(recovered)
        recoveredSourceIDs.insert(local.id)
        recoveryInputs.append(try Self.modeRecovery(
          transitionID: transitionID,
          namespaceKey: namespaceKey,
          sourceID: local.id,
          kind: .modeRecoveredSnip,
          payload: CloudModeRecoveryPayload(sourceID: local.id, recoveredID: recoveredID)
        ))
      }
    }

    let adjusted = SnipLibraryTransferSnapshot(
      revision: source.revision,
      snips: adjustedSnips,
      lists: adjustedLists,
      attachmentData: source.attachmentData,
      legacyManualPositions: source.legacyManualPositions,
      opaqueSyncStateDigest: source.opaqueSyncStateDigest,
      opaqueSyncStatePayload: source.opaqueSyncStatePayload
    )
    let transfer = try SnipLibraryTransferPlanner.plan(
      source: adjusted,
      target: target,
      transitionID: transitionID,
      replacingTargetSnipIDs: replacingSnips,
      replacingTargetListIDs: replacingLists
    )
    return try CloudFullReenableApplyPlan(
      transitionID: transitionID,
      namespaceKey: namespaceKey,
      expectedNamespaceRevision: stored.namespaceState.revision,
      targetRevision: transfer.targetRevision,
      targetDigest: transfer.targetDigest,
      snips: transfer.snips,
      lists: transfer.lists,
      attachmentData: transfer.attachmentData,
      dormantPayload: transfer.opaqueSyncStatePayload,
      acceptedCAS: acceptedValues.map(CloudFullReenableAcceptedCAS.init),
      conflicts: conflicts,
      recoveryInputs: recoveryInputs,
      result: SnipLibraryTransferResult(
        approvedSnipIDs: transfer.result.approvedSnipIDs,
        recoveredSourceSnipIDs: transfer.result.recoveredSourceSnipIDs.union(recoveredSourceIDs)
      )
    )
  }

  package func clearRetryableEvents(_ keys: Set<String>) async throws {
    try await library.clearCloudFullRecoveryEvents(namespaceKey: namespaceKey, keys: keys)
  }
  private static func binding(_ namespace: CloudSyncNamespace) -> ICloudSyncNamespaceBinding {
    ICloudSyncNamespaceBinding(
      scope: namespace.cloudScope,
      accountLineage: namespace.accountLineage,
      generation: namespace.generation,
      zones: Set(namespace.zones.map {
        ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
      })
    )
  }

  private static func reference(for id: CloudRecordID) -> CloudEntityReference? {
    let kind: CloudEntityKind
    let suffix: Substring
    if id.name.hasPrefix("s-") {
      kind = .snip
      suffix = id.name.dropFirst(2)
    } else if id.name.hasPrefix("l-") {
      kind = .list
      suffix = id.name.dropFirst(2)
    } else {
      return nil
    }
    guard let domainID = UUID(uuidString: String(suffix)) else { return nil }
    return CloudEntityReference(kind: kind, domainID: domainID)
  }

  private static func recoveryKey(_ input: CloudFullRecoveryInput) -> String {
    "full-recovery-\(input.batchID.uuidString.lowercased())"
  }

  private static func isRetryableRecovery(_ input: CloudFullRecoveryInput) -> Bool {
    input.kind == .retryableFetch || input.kind == .retryableSend
  }
  private static func materializedEntity(_ input: CloudAcceptedEntityInput) -> CloudAcceptedEntity {
    CloudAcceptedEntity(
      reference: input.reference,
      identity: input.identity,
      schemaVersion: input.schemaVersion,
      acceptedData: input.acceptedData,
      presenceData: input.presenceData,
      shadowData: input.shadowData,
      systemFields: input.systemFields,
      dependencyListID: input.dependencyListID,
      isDeferred: false,
      localRevision: 0
    )
  }

  private static func snip(
    _ value: CloudSnipMergeFields,
    attachments: [SnipAttachment]
  ) -> Snip {
    let mutation = localMutation(value)
    return Snip(
      id: mutation.snipID,
      requestID: mutation.requestID,
      createdAt: mutation.createdAt,
      updatedAt: mutation.updatedAt,
      content: mutation.content,
      origin: mutation.origin,
      source: mutation.source,
      listID: mutation.listID,
      isDone: mutation.isDone,
      manualSortKey: mutation.orderKey,
      attachments: attachments
    )
  }

  private static func replacing(_ value: Snip, listID: UUID) -> Snip {
    Snip(
      id: value.id,
      requestID: value.requestID,
      createdAt: value.createdAt,
      updatedAt: value.updatedAt,
      content: value.content,
      origin: value.origin,
      source: value.source,
      listID: listID,
      isDone: value.isDone,
      manualSortKey: value.manualSortKey,
      attachments: value.attachments
    )
  }

  private static func recovered(_ value: Snip, id: UUID, listID: UUID) -> Snip {
    Snip(
      id: id,
      requestID: SnipLibraryTransferPlanner.derivedUUID(
        transitionID: id,
        sourceID: value.requestID
      ),
      createdAt: value.createdAt,
      updatedAt: value.updatedAt,
      content: value.content,
      origin: value.origin,
      source: value.source,
      listID: listID,
      isDone: value.isDone,
      manualSortKey: value.manualSortKey,
      attachments: value.attachments
    )
  }

  private static func modeRecovery(
    transitionID: UUID,
    namespaceKey: String,
    sourceID: UUID,
    kind: CloudFullRecoveryKind,
    payload: CloudModeRecoveryPayload
  ) throws -> CloudFullRecoveryInput {
    let salt: UUID = switch kind {
    case .modeRecoveredSnip:
      UUID(uuidString: "11111111-1111-5111-8111-111111111111")!
    case .modeDeletedListPlacement:
      UUID(uuidString: "22222222-2222-5222-8222-222222222222")!
    case .modeRecoveredList:
      UUID(uuidString: "33333333-3333-5333-8333-333333333333")!
    default:
      UUID(uuidString: "44444444-4444-5444-8444-444444444444")!
    }
    return CloudFullRecoveryInput(
      namespaceKey: namespaceKey,
      batchID: SnipLibraryTransferPlanner.derivedUUID(
        transitionID: SnipLibraryTransferPlanner.derivedUUID(
          transitionID: transitionID,
          sourceID: salt
        ),
        sourceID: sourceID
      ),
      kind: kind,
      outboundData: Data(),
      resultData: try JSONEncoder().encode(payload)
    )
  }
}
