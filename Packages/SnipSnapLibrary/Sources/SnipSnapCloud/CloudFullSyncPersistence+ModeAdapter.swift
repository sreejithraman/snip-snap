import Foundation
import SnipSnapCore
import SnipSnapPersistence

package enum CloudFullReenableError: Error, Equatable, Sendable {
  case deferredDependencies
}

private struct ICloudSyncRecoveryPayload: Codable, Equatable {
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

private struct ICloudReenableMergeBasis<Fields> {
  // A missing pair means the send left us without trustworthy ancestry.
  let fields: (local: Fields, server: Fields)?
  let dormant: CloudAcceptedEntity?
  let conflictVersion: Data
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
    let actual = namespace.binding
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

  package func modeSendAttempt(
    for outbound: CloudOutboundBatch,
    namespace expectedNamespace: ICloudSyncNamespaceBinding
  ) async throws -> SyncModeSendAttempt {
    let actual = namespace.binding
    guard actual == expectedNamespace else { throw SyncModePersistenceError.namespaceMismatch }
    var operations: [SyncModeSendOperation] = []
    for operation in outbound.operations {
      let id = operation.id
      guard namespace.zones.contains(id.zone) else {
        throw SyncModePersistenceError.namespaceMismatch
      }
      operations.append(
        SyncModeSendOperation(
          reference: Self.reference(for: id),
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
        || corruptShadowRecovery(in: stored).needsAttention,
      blocksSending: stored.namespaceState.phase == .blocked
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
        || corruptShadowRecovery(in: stored).needsAttention,
      blocksSending: stored.namespaceState.phase == .blocked
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
          namespaceKey: namespaceKey.rawValue,
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
    targetRevision: UInt64,
    retryEvidence: CloudSetupRetryEvidence? = nil
  ) async throws -> CloudFullReenableApplyPlan? {
    let sourceBundle = try CloudDormantAcceptedBaseBundle.decode(source.opaqueSyncStatePayload)
    let exactEntries = sourceBundle.entries.filter { $0.namespaceKey == namespaceKey.rawValue }
    let hasRetryEvidence = retryEvidence?.isEmpty == false
    let decoder = JSONDecoder()
    var bases: [CloudEntityReference: CloudAcceptedEntity] = [:]
    for entry in exactEntries {
      guard namespace.zones.contains(Self.recordID(entry.identity).zone),
        let input = try? decoder.decode(CloudAcceptedEntityInput.self, from: entry.payload),
        input.reference == entry.reference,
        input.identity == entry.identity
      else { continue }
      bases[entry.reference] = Self.materializedEntity(input)
    }
    guard !bases.isEmpty || hasRetryEvidence else { return nil }

    let target = try await library.transferSnapshot(revision: targetRevision)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    guard stored.deferredEntities.isEmpty else {
      throw CloudFullReenableError.deferredDependencies
    }
    let acceptedValues = stored.readyEntities + stored.deferredEntities
    let accepted = Dictionary(uniqueKeysWithValues: acceptedValues.map { ($0.reference, $0) })
    let targetSnips = Dictionary(uniqueKeysWithValues: target.snips.map { ($0.id, $0) })
    let sourceSnipIDs = Set(source.snips.map(\.id))
    var adjustedLists = source.lists
    var adjustedSnips = source.snips
    var attachmentData = source.attachmentData
    var replacingLists: Set<UUID> = []
    var replacingSnips: Set<UUID> = []
    var deletedLists: Set<UUID> = []
    var conflicts: [CloudConflictInput] = []
    var recoveryInputs: [CloudFullRecoveryInput] = []
    var recoveredSourceIDs: Set<UUID> = []
    let retryVersion = Data("snipsnap-setup-retry|\(transitionID.uuidString)".utf8)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    for index in adjustedLists.indices.reversed() {
      let local = adjustedLists[index]
      let reference = CloudEntityReference(kind: .list, domainID: local.id)
      let remote = accepted[reference]
      guard let basis = try reenableBasis(
        reference: reference, server: remote, dormant: bases[reference],
        retryEvidence: retryEvidence, retryVersion: retryVersion, decoder: decoder,
        id: \CloudListMergeFields.id,
        dormantFields: { try Self.listFields(Self.listRecord($0)) }
      ) else {
        if hasRetryEvidence, remote == nil { replacingLists.insert(local.id) }
        continue
      }
      guard let server = remote,
        basis.dormant == nil || basis.dormant?.identity == server.identity
      else {
        if local.id == SnipList.inbox.id { continue }
        let localFields = Self.listFields(local, updatedAt: basis.fields?.local.updatedAt ?? .distantPast)
        if basis.fields.map({ !Self.sameListFields($0.local, localFields) }) ?? true {
          recoveryInputs.append(try Self.modeRecovery(
            transitionID: transitionID,
            namespaceKey: namespaceKey.rawValue,
            sourceID: local.id,
            kind: .modeRecoveredList,
            payload: ICloudSyncRecoveryPayload(
              sourceID: local.id,
              deletedListID: local.id,
              recoveredList: localFields
            )
          ))
        }
        adjustedLists.remove(at: index)
        if basis.dormant == nil { replacingLists.insert(local.id) }
        deletedLists.insert(local.id)
        continue
      }
      let serverFields = try Self.listFields(Self.listRecord(server))
      let localFields = Self.listFields(local, updatedAt: serverFields.updatedAt)
      let result = try basis.fields.map {
        try CloudThreeWayMerge.list(bases: $0, local: localFields, server: serverFields)
      }
      adjustedLists[index] = Self.localList(result?.merged ?? serverFields)
      replacingLists.insert(local.id)
      let conflict = result == nil
        ? Self.ambiguousListConflict(local: localFields, server: serverFields)
        : result?.conflict
      if let payload = conflict {
        let key = CloudConflictKey.make(
          namespaceKey: namespaceKey,
          recordID: Self.recordID(server.identity),
          ancestorSystemFields: basis.conflictVersion,
          serverSystemFields: server.systemFields
        )
        conflicts.append(CloudConflictInput(
          key: key,
          reference: reference,
          format: .listMergeV1,
          payload: try encoder.encode(payload),
          recovery: .list(Self.recoveredList(payload, key: key))
        ))
      } else if result == nil, !Self.sameListFields(localFields, serverFields) {
        recoveryInputs.append(try Self.modeRecovery(
          transitionID: transitionID,
          namespaceKey: namespaceKey.rawValue,
          sourceID: local.id,
          kind: .modeRecoveredList,
          payload: ICloudSyncRecoveryPayload(sourceID: local.id, recoveredList: localFields)
        ))
      }
    }

    for index in adjustedSnips.indices.reversed() {
      let sourceLocal = adjustedSnips[index]
      var local = sourceLocal
      let reference = CloudEntityReference(kind: .snip, domainID: local.id)
      if deletedLists.contains(local.listID) {
        let deletedListID = local.listID
        local = Self.replacing(local, listID: SnipList.inbox.id)
        adjustedSnips[index] = local
        recoveryInputs.append(try Self.modeRecovery(
          transitionID: transitionID,
          namespaceKey: namespaceKey.rawValue,
          sourceID: local.id,
          kind: .modeDeletedListPlacement,
          payload: ICloudSyncRecoveryPayload(sourceID: local.id, deletedListID: deletedListID)
        ))
      }
      let remote = accepted[reference]
      guard let basis = try reenableBasis(
        reference: reference, server: remote, dormant: bases[reference],
        retryEvidence: retryEvidence, retryVersion: retryVersion, decoder: decoder,
        id: \CloudSnipMergeFields.id,
        dormantFields: { try Self.snipFields(Self.snipRecord($0)) }
      ) else {
        if hasRetryEvidence, remote == nil { replacingSnips.insert(local.id) }
        continue
      }
      let localFields: CloudSnipMergeFields
      if let dormant = basis.dormant {
        localFields = Self.snipFields(local, accepted: try Self.snipRecord(dormant))
      } else {
        localFields = Self.snipFields(sourceLocal, accepted: nil)
      }
      guard let server = remote,
        basis.dormant == nil || basis.dormant?.identity == server.identity
      else {
        if basis.dormant == nil { replacingSnips.insert(local.id) }
        if let bases = basis.fields,
          Self.sameSnipFields(bases.local, localFields), local.attachments.isEmpty
        {
          adjustedSnips.remove(at: index)
          continue
        }
        let priorRecovery = basis.fields == nil
          ? Self.acceptedRecovery(
            for: local, listID: SnipList.inbox.id, target: target.snips, accepted: accepted
          )
          : nil
        let recoveredID = priorRecovery?.id
          ?? SnipLibraryTransferPlanner.derivedUUID(transitionID: transitionID, sourceID: local.id)
        let recovered = Self.recovered(local, id: recoveredID, listID: SnipList.inbox.id)
        if priorRecovery != nil, sourceSnipIDs.contains(recoveredID) {
          adjustedSnips.remove(at: index)
        } else {
          adjustedSnips[index] = recovered
          if priorRecovery != nil { replacingSnips.insert(recoveredID) }
        }
        recoveredSourceIDs.insert(local.id)
        recoveryInputs.append(try Self.modeRecovery(
          transitionID: transitionID,
            namespaceKey: namespaceKey.rawValue,
          sourceID: local.id,
          kind: .modeRecoveredSnip,
          payload: ICloudSyncRecoveryPayload(sourceID: local.id, recoveredID: recoveredID)
        ))
        continue
      }
      let serverFields = try Self.snipFields(Self.snipRecord(server))
      let result: CloudSnipMergeResult?
      if let bases = basis.fields {
        do {
          result = try CloudThreeWayMerge.snip(bases: bases, local: localFields, server: serverFields)
        } catch CloudMergeError.immutableMetadata where basis.dormant == nil {
          result = nil
        }
      } else {
        result = nil
      }
      var attachments = local.attachments
      if basis.dormant == nil {
        let localAttachmentIDs = Set(attachments.map(\.id))
        for attachment in targetSnips[local.id]?.attachments ?? []
          where !localAttachmentIDs.contains(attachment.id)
        {
          attachments.append(attachment)
          if attachmentData[attachment.id] == nil {
            attachmentData[attachment.id] = target.attachmentData[attachment.id]
          }
        }
      }
      let merged = Self.snip(result?.merged ?? serverFields, attachments: attachments)
      adjustedSnips[index] = deletedLists.contains(merged.listID)
        ? Self.replacing(merged, listID: SnipList.inbox.id) : merged
      replacingSnips.insert(local.id)
      if result == nil, !Self.sameSnipFields(localFields, serverFields) {
        let listID = local.listID
        let priorRecovery = Self.acceptedRecovery(
          for: local, listID: listID, target: target.snips, accepted: accepted
        )
        let recoveredID = priorRecovery?.id
          ?? SnipLibraryTransferPlanner.derivedUUID(transitionID: transitionID, sourceID: local.id)
        if priorRecovery == nil || !sourceSnipIDs.contains(recoveredID) {
          adjustedSnips.append(Self.recovered(local, id: recoveredID, listID: listID))
          if priorRecovery != nil { replacingSnips.insert(recoveredID) }
        }
        recoveredSourceIDs.insert(local.id)
      }
      if let payload = result?.conflict {
        let key = CloudConflictKey.make(
          namespaceKey: namespaceKey,
          recordID: Self.recordID(server.identity),
          ancestorSystemFields: basis.conflictVersion,
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
            namespaceKey: namespaceKey.rawValue,
          sourceID: local.id,
          kind: .modeRecoveredSnip,
          payload: ICloudSyncRecoveryPayload(sourceID: local.id, recoveredID: recoveredID)
        ))
      }
    }

    let adjusted = SnipLibraryTransferSnapshot(
      revision: source.revision,
      snips: adjustedSnips,
      lists: adjustedLists,
      attachmentData: attachmentData,
      legacyManualPositions: source.legacyManualPositions,
      opaqueSyncStateDigest: source.opaqueSyncStateDigest,
      opaqueSyncStatePayload: source.opaqueSyncStatePayload,
      additionalSeenRequestIDs: source.additionalSeenRequestIDs
    )
    let transfer = try SnipLibraryTransferPlanner.plan(
      source: adjusted,
      target: target,
      transitionID: transitionID,
      replacingTargetSnipIDs: replacingSnips,
      replacingTargetListIDs: replacingLists
    )
    let remainingListIDs = Set(transfer.lists.map(\.id))
    let snips = try transfer.snips.map { snip in
      guard deletedLists.contains(snip.listID), !remainingListIDs.contains(snip.listID) else {
        return snip
      }
      recoveryInputs.append(try Self.modeRecovery(
        transitionID: transitionID,
        namespaceKey: namespaceKey.rawValue,
        sourceID: snip.id,
        kind: .modeDeletedListPlacement,
        payload: ICloudSyncRecoveryPayload(sourceID: snip.id, deletedListID: snip.listID)
      ))
      return Self.replacing(snip, listID: SnipList.inbox.id)
    }
    return try CloudFullReenableApplyPlan(
      transitionID: transitionID,
      namespaceKey: namespaceKey.rawValue,
      expectedNamespaceRevision: stored.namespaceState.revision,
      targetRevision: transfer.targetRevision,
      targetDigest: transfer.targetDigest,
      snips: snips,
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
    let retained = try await library.cloudFullRecoveryEvents(namespaceKey: namespaceKey)
      .filter(Self.hasFailedFetchRecords).map(Self.recoveryKey)
    try await library.clearCloudFullRecoveryEvents(namespaceKey: namespaceKey, keys: keys.subtracting(retained))
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

  private func reenableBasis<Fields: Decodable>(
    reference: CloudEntityReference,
    server: CloudAcceptedEntity?,
    dormant: CloudAcceptedEntity?,
    retryEvidence: CloudSetupRetryEvidence?,
    retryVersion: Data,
    decoder: JSONDecoder,
    id: KeyPath<Fields, UUID>,
    dormantFields: (CloudAcceptedEntity) throws -> Fields
  ) throws -> ICloudReenableMergeBasis<Fields>? {
    if let retryEvidence, !retryEvidence.isEmpty {
      let canonicalID: CloudRecordID = switch reference.kind {
      case .snip: .snip(reference.domainID, in: dataZone)
      case .list: .list(reference.domainID, in: dataZone)
      }
      let identities = Set([
        Self.storageIdentity(canonicalID), server?.identity, dormant?.identity,
      ].compactMap { $0 })
      let keys = identities.map { CloudSetupRetryRecordKey(reference: reference, identity: $0) }
      let identity = server?.identity ?? Self.storageIdentity(canonicalID)
      let key = CloudSetupRetryRecordKey(reference: reference, identity: identity)
      let baseline = retryEvidence.baseline(for: key)
      // With no accepted version on either side, the initial seed can still use its original ID.
      if (server != nil || dormant != nil || baseline != nil),
        keys.contains(where: { retryEvidence.requiresRecovery(for: $0) })
      {
        return ICloudReenableMergeBasis(fields: nil, dormant: nil, conflictVersion: retryVersion)
      }
      if let baseline {
        guard let localFields = try? decoder.decode(Fields.self, from: baseline.sourceFields),
          let serverFields = try? decoder.decode(Fields.self, from: baseline.serverFields),
          localFields[keyPath: id] == reference.domainID,
          serverFields[keyPath: id] == reference.domainID
        else {
          return ICloudReenableMergeBasis(fields: nil, dormant: nil, conflictVersion: retryVersion)
        }
        return ICloudReenableMergeBasis(
          fields: (localFields, serverFields), dormant: nil,
          conflictVersion: retryVersion + baseline.serverFields
        )
      }
    }
    guard let dormant else { return nil }
    let fields = try dormantFields(dormant)
    return ICloudReenableMergeBasis(
      fields: (fields, fields), dormant: dormant, conflictVersion: dormant.systemFields
    )
  }

  private static func ambiguousListConflict(
    local: CloudListMergeFields,
    server: CloudListMergeFields
  ) -> CloudListConflictPayload? {
    var fields: Set<CloudListConflictField> = []
    if local.desiredName != server.desiredName { fields.insert(.desiredName) }
    if local.systemImage != server.systemImage { fields.insert(.systemImage) }
    if local.color != server.color { fields.insert(.color) }
    return fields.isEmpty ? nil : CloudListConflictPayload(fields: fields, local: local, server: server)
  }

  private static func acceptedRecovery(
    for local: Snip,
    listID: UUID,
    target: [Snip],
    accepted: [CloudEntityReference: CloudAcceptedEntity]
  ) -> Snip? {
    target.first { candidate in
      guard candidate.id != local.id,
        candidate.content == local.content,
        candidate.attachments.map(\.id) == local.attachments.map(\.id),
        accepted[CloudEntityReference(kind: .snip, domainID: candidate.id)] != nil
      else { return false }
      // The recovery request ID links this copy to its source even across a new transition.
      let recovered = Self.recovered(local, id: candidate.id, listID: listID)
      return sameSnipFields(snipFields(candidate, accepted: nil), snipFields(recovered, accepted: nil))
    }
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
      pinnedAt: mutation.pinnedAt,
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
      pinnedAt: value.pinnedAt,
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
      pinnedAt: value.pinnedAt,
      manualSortKey: value.manualSortKey,
      attachments: value.attachments
    )
  }

  private static func modeRecovery(
    transitionID: UUID,
    namespaceKey: String,
    sourceID: UUID,
    kind: CloudFullRecoveryKind,
    payload: ICloudSyncRecoveryPayload
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
