import Foundation
import SnipSnapCore
import SnipSnapPersistence

struct CloudFullBatchPlanner {
  let namespaceKey: CloudSyncNamespaceKey
  let dataZone: CloudZoneID
  let payloadZone: CloudZoneID?
  private let expectedEngine: Data?
  private let local: SnipLibrarySnapshot
  private let stored: CloudFullStorageSnapshot
  let attachmentStorage: CloudAttachmentStorageSnapshot

  init(
    namespaceKey: CloudSyncNamespaceKey,
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID?,
    expectedEngine: Data?,
    local: SnipLibrarySnapshot,
    stored: CloudFullStorageSnapshot,
    attachmentStorage: CloudAttachmentStorageSnapshot
  ) {
    self.namespaceKey = namespaceKey
    self.dataZone = dataZone
    self.payloadZone = payloadZone
    self.expectedEngine = expectedEngine
    self.local = local
    self.stored = stored
    self.attachmentStorage = attachmentStorage
  }

  struct NormalizedBatch {
    let results: [CloudFetchItemResult]
    let nextEngine: CloudEngineStateEnvelope?
    let attachmentOperationIDs: Set<CloudRecordID>
    let outboundBindings: [CloudFullOutboundBinding]
    let recoveryInputs: [CloudFullRecoveryInput]
    let outboundOperations: [CloudRecordID: CloudOutboundOperation]
    let sentItemResults: [CloudRecordID: CloudSendItemResult]
  }

  func plan(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?,
    rawBatchData: Data
  ) throws -> CloudFullBatchCommit {
    let allAccepted = stored.readyEntities + stored.deferredEntities
    let byReference = Dictionary(uniqueKeysWithValues: allAccepted.map { ($0.reference, $0) })
    let byIdentity = Dictionary(uniqueKeysWithValues: allAccepted.map { ($0.identity, $0) })
    var items: [CloudFullBatchItem] = []
    let normalized = try normalize(batch, outbound: outbound, rawBatchData: rawBatchData)
    let attachmentPlanner = CloudFullAttachmentBatchPlanner(
      dataZone: dataZone,
      payloadZone: payloadZone,
      attachmentOperationIDs: normalized.attachmentOperationIDs,
      outboundOperations: normalized.outboundOperations,
      sentItemResults: normalized.sentItemResults,
      storage: attachmentStorage
    )
    var recoveryInputs = normalized.recoveryInputs
    var recoveryReviews: [CloudRecoveryReviewInput] = []
    var settledDeleteIdentities: [CloudTextStorageIdentity] = []
    let pendingDeletes = Dictionary(uniqueKeysWithValues:
      stored.pendingDeletes.map { ($0.reference, $0) }
    )
    var attachmentTransitions: [CloudAttachmentTransition] = []
    for result in normalized.results {
      switch try attachmentPlanner.reduce(result) {
      case .unhandled:
        break
      case .handled(let transition):
        if let transition { attachmentTransitions.append(transition) }
        continue
      }
      switch result {
      case .record(let snapshot):
        if let item = try Self.recordItem(
          snapshot,
          namespaceKey: namespaceKey,
          local: local,
          accepted: byReference,
          pendingDeleteReferences: Set(pendingDeletes.keys)
        ) {
          items.append(item)
        }
      case .deleted(let id):
        guard let accepted = byIdentity[CloudFullSyncPersistence.storageIdentity(id)] else {
          continue
        }
        let plan = try Self.deleteItem(
          accepted,
          namespaceKey: namespaceKey,
          local: local,
          hasPendingDelete: pendingDeletes[accepted.reference] != nil
        )
        items.append(plan.item)
        if pendingDeletes[accepted.reference]?.identity == accepted.identity {
          settledDeleteIdentities.append(accepted.identity)
        }
        if let review = plan.review { recoveryReviews.append(review) }
        if !plan.movedSnipIDs.isEmpty {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.sortedKeys]
          recoveryInputs.append(CloudFullRecoveryInput(
            namespaceKey: namespaceKey.rawValue,
            batchID: batch.id,
            kind: .deletedListPlacement,
            outboundData: try encoder.encode(accepted.reference.domainID),
            resultData: try encoder.encode(plan.movedSnipIDs.sorted {
              $0.uuidString < $1.uuidString
            })
          ))
        }
      case .failed:
        continue
      }
    }
    var enrollment = stored.enrolledEntities
    for item in items where item.acceptedAction == .remove {
      enrollment.remove(item.accepted.reference)
    }
    let incomingLists = Set(items.compactMap {
      $0.acceptedAction == .upsert && $0.accepted.reference.kind == .list
        ? $0.accepted.reference.domainID : nil
    })
    enrollment.formUnion(incomingLists.map { CloudEntityReference(kind: .list, domainID: $0) })
    var acceptedAfterBatch = Dictionary(uniqueKeysWithValues: allAccepted.map {
      ($0.reference, CloudFullSyncPersistence.acceptedInput($0))
    })
    for item in items {
      if item.acceptedAction == .upsert {
        acceptedAfterBatch[item.accepted.reference] = item.accepted
      } else if item.acceptedAction == .remove {
        acceptedAfterBatch.removeValue(forKey: item.accepted.reference)
      }
    }
    for accepted in acceptedAfterBatch.values where accepted.reference.kind == .snip {
      guard let listID = accepted.dependencyListID,
        enrollment.contains(CloudEntityReference(kind: .list, domainID: listID))
      else {
        enrollment.remove(accepted.reference)
        continue
      }
      enrollment.insert(accepted.reference)
    }
    return CloudFullBatchCommit(
      namespaceKey: namespaceKey.rawValue,
      batchID: batch.id,
      expectedEngineState: expectedEngine,
      nextEngineState: try normalized.nextEngine.map { try JSONEncoder().encode($0) },
      nextEnrollment: enrollment,
      expectedNamespaceRevision: stored.namespaceState.revision,
      nextNamespaceState: Self.nextNamespaceState(
        current: stored.namespaceState,
        batch: batch,
        dataZone: dataZone,
        attachmentOperationIDs: normalized.attachmentOperationIDs
      ),
      rawBatchData: rawBatchData,
      outboundBindings: normalized.outboundBindings,
      recoveryInputs: recoveryInputs,
      recoveryReviews: recoveryReviews,
      settledDeleteIdentities: settledDeleteIdentities,
      attachmentTransitions: attachmentTransitions,
      items: items
    )
  }

  private static func recordItem(
    _ snapshot: CloudRecordSnapshot,
    namespaceKey: CloudSyncNamespaceKey,
    local: SnipLibrarySnapshot,
    accepted: [CloudEntityReference: CloudAcceptedEntity],
    pendingDeleteReferences: Set<CloudEntityReference>
  ) throws -> CloudFullBatchItem? {
    if snapshot.recordType == "Snip" {
      let server = try CloudFullRecordCodec.snip(from: snapshot)
      let input = try acceptedInput(server, snapshot: snapshot)
      if server.binding != .canonical {
        return quarantineItem(input, snapshot: snapshot)
      }
      let base = accepted[input.reference]
      let current = local.snips.first { $0.id == server.domainID }
      if pendingDeleteReferences.contains(input.reference) {
        return CloudFullBatchItem(
          accepted: input,
          expectedLocalRevision: base?.localRevision,
          expectedSystemFields: base?.systemFields,
          localPrecondition: current.map { .exactSnip(CloudLocalSnipMutation($0)) } ?? .none,
          localMutation: .none,
          conflict: nil,
          quarantine: nil
        )
      }
      let serverFields = try CloudFullSyncPersistence.snipFields(server)
      var merged = serverFields
      var conflict: CloudConflictInput?
      if let current, let base {
        let baseRecord = try CloudFullSyncPersistence.snipRecord(base)
        let result = try CloudThreeWayMerge.snip(
          base: try CloudFullSyncPersistence.snipFields(baseRecord),
          local: CloudFullSyncPersistence.snipFields(current, accepted: baseRecord),
          server: serverFields
        )
        merged = result.merged
        conflict = try result.conflict.map {
          let key = CloudConflictKey.make(
            namespaceKey: namespaceKey,
            recordID: snapshot.id,
            ancestorSystemFields: base.systemFields,
            serverSystemFields: snapshot.shadow.systemFields
          )
          return CloudConflictInput(
            key: key,
            reference: input.reference,
            format: .snipMergeV1,
            payload: try JSONEncoder().encode($0),
            recovery: .snip(CloudFullSyncPersistence.recoveredSnip(
              $0,
              key: key,
              attachments: current.attachments
            ))
          )
        }
      } else if current == nil, let base {
        let baseFields = try CloudFullSyncPersistence.snipFields(
          CloudFullSyncPersistence.snipRecord(base)
        )
        if CloudFullSyncPersistence.sameSnipFields(baseFields, serverFields) {
          return CloudFullBatchItem(
            accepted: input,
            expectedLocalRevision: base.localRevision,
            expectedSystemFields: base.systemFields,
            localMutation: .none,
            conflict: nil,
            quarantine: nil
          )
        }
        return CloudFullBatchItem(
          accepted: input,
          expectedLocalRevision: base.localRevision,
          expectedSystemFields: base.systemFields,
          localMutation: .none,
          conflict: CloudConflictInput(
            key: CloudConflictKey.make(
              namespaceKey: namespaceKey,
              recordID: snapshot.id,
              ancestorSystemFields: base.systemFields,
              serverSystemFields: snapshot.shadow.systemFields
            ),
            reference: input.reference,
            format: .snipMergeV1,
            payload: try JSONEncoder().encode(CloudSnipDeleteConflictPayload(server: serverFields))
          ),
          quarantine: nil
        )
      } else if let current {
        let localFields = CloudFullSyncPersistence.snipFields(current, accepted: nil)
        if localFields != serverFields {
          let key = CloudConflictKey.make(
              namespaceKey: namespaceKey,
              recordID: snapshot.id,
              ancestorSystemFields: Data(),
              serverSystemFields: snapshot.shadow.systemFields
            )
          let payload = CloudSnipConflictPayload(
            fields: [.text, .source, .isDone, .placement],
            local: localFields,
            server: serverFields
          )
          conflict = CloudConflictInput(
            key: key,
            reference: input.reference,
            format: .snipMergeV1,
            payload: try JSONEncoder().encode(payload),
            recovery: .snip(CloudFullSyncPersistence.recoveredSnip(
              payload,
              key: key,
              attachments: current.attachments
            ))
          )
        }
      }
      return CloudFullBatchItem(
        accepted: input,
        expectedLocalRevision: base?.localRevision,
        expectedSystemFields: base?.systemFields,
        localPrecondition: current.map { .exactSnip(CloudLocalSnipMutation($0)) }
          ?? .requireMissing,
        localMutation: .upsertSnip(CloudFullSyncPersistence.localMutation(merged)),
        conflict: conflict,
        quarantine: nil
      )
    }
    guard snapshot.recordType == "List" else { return nil }
    let server = try CloudFullRecordCodec.list(from: snapshot)
    let input = try acceptedInput(server, snapshot: snapshot)
    if server.binding != .canonical { return quarantineItem(input, snapshot: snapshot) }
    let base = accepted[input.reference]
    let current = local.lists.first { $0.id == server.domainID }
    if pendingDeleteReferences.contains(input.reference) {
      return CloudFullBatchItem(
        accepted: input,
        expectedLocalRevision: base?.localRevision,
        expectedSystemFields: base?.systemFields,
        localPrecondition: current.map { .exactList(CloudLocalListMutation($0)) } ?? .none,
        localMutation: .none,
        conflict: nil,
        quarantine: nil
      )
    }
    let serverFields = try CloudFullSyncPersistence.listFields(server)
    var merged = serverFields
    var conflict: CloudConflictInput?
    if let current, let base {
      let result = try CloudThreeWayMerge.list(
        base: try CloudFullSyncPersistence.listFields(
          CloudFullSyncPersistence.listRecord(base)
        ),
        local: CloudFullSyncPersistence.listFields(current, updatedAt: serverFields.updatedAt),
        server: serverFields
      )
      merged = result.merged
      conflict = try result.conflict.map {
        let key = CloudConflictKey.make(
          namespaceKey: namespaceKey,
          recordID: snapshot.id,
          ancestorSystemFields: base.systemFields,
          serverSystemFields: snapshot.shadow.systemFields
        )
        return CloudConflictInput(
          key: key,
          reference: input.reference,
          format: .listMergeV1,
          payload: try JSONEncoder().encode($0),
          recovery: .list(CloudFullSyncPersistence.recoveredList($0, key: key))
        )
      }
    } else if current == nil, let base {
      let baseFields = try CloudFullSyncPersistence.listFields(
        CloudFullSyncPersistence.listRecord(base)
      )
      if CloudFullSyncPersistence.sameListFields(baseFields, serverFields) {
        return CloudFullBatchItem(
          accepted: input,
          expectedLocalRevision: base.localRevision,
          expectedSystemFields: base.systemFields,
          localMutation: .none,
          conflict: nil,
          quarantine: nil
        )
      }
      return CloudFullBatchItem(
        accepted: input,
        expectedLocalRevision: base.localRevision,
        expectedSystemFields: base.systemFields,
        localMutation: .none,
        conflict: CloudConflictInput(
          key: CloudConflictKey.make(
            namespaceKey: namespaceKey,
            recordID: snapshot.id,
            ancestorSystemFields: base.systemFields,
            serverSystemFields: snapshot.shadow.systemFields
          ),
          reference: input.reference,
          format: .listMergeV1,
          payload: try JSONEncoder().encode(CloudListDeleteConflictPayload(server: serverFields))
        ),
        quarantine: nil
      )
    }
    return CloudFullBatchItem(
      accepted: input,
      expectedLocalRevision: base?.localRevision,
      expectedSystemFields: base?.systemFields,
      localPrecondition: current.map { .exactList(CloudLocalListMutation($0)) }
        ?? .requireMissing,
      localMutation: .upsertList(CloudFullSyncPersistence.localList(merged)),
      conflict: conflict,
      quarantine: nil
    )
  }

  private struct DeletedRecordPlan {
    let item: CloudFullBatchItem
    let review: CloudRecoveryReviewInput?
    let movedSnipIDs: [UUID]
  }

  private static func deleteItem(
    _ accepted: CloudAcceptedEntity,
    namespaceKey: CloudSyncNamespaceKey,
    local: SnipLibrarySnapshot,
    hasPendingDelete: Bool
  ) throws -> DeletedRecordPlan {
    let input = CloudFullSyncPersistence.acceptedInput(accepted)
    switch accepted.reference.kind {
    case .snip:
      let current = local.snips.first { $0.id == accepted.reference.domainID }
      let acceptedRecord = try CloudFullSyncPersistence.snipRecord(accepted)
      let shouldRecover = try current.map { snip in
        if hasPendingDelete { return false }
        return !CloudFullSyncPersistence.sameSnipFields(
          try CloudFullSyncPersistence.snipFields(acceptedRecord),
          CloudFullSyncPersistence.snipFields(snip, accepted: acceptedRecord)
        )
          || !snip.attachments.isEmpty
      } ?? false
      let key = CloudConflictKey.make(
        namespaceKey: namespaceKey,
        recordID: CloudFullSyncPersistence.recordID(accepted.identity),
        ancestorSystemFields: accepted.systemFields,
        serverSystemFields: Data()
      )
      let recovered = current.flatMap { snip -> Snip? in
        guard shouldRecover else { return nil }
        let id = CloudConflictKey.recoveryID(for: key)
        return Snip(
          id: id,
          requestID: CloudConflictKey.recoveryID(for: "\(key)|request"),
          createdAt: snip.createdAt,
          updatedAt: snip.updatedAt,
          content: snip.content,
          origin: snip.origin,
          source: snip.source,
          listID: SnipList.inbox.id,
          isDone: snip.isDone,
          manualSortKey: snip.manualSortKey,
          attachments: snip.attachments
        )
      }
      return DeletedRecordPlan(item: CloudFullBatchItem(
        accepted: input,
        acceptedAction: .remove,
        expectedLocalRevision: accepted.localRevision,
        expectedSystemFields: accepted.systemFields,
        localPrecondition: current.map { .exactSnip(CloudLocalSnipMutation($0)) } ?? .none,
        localMutation: {
          guard let current else { return .none }
          guard let recovered else { return .removeSnip(accepted.reference.domainID) }
          return .recoverDeletedSnip(
            original: CloudLocalSnipMutation(current),
            recovered: CloudLocalSnipMutation(recovered),
            attachmentIDs: current.attachments.map(\.id)
          )
        }(),
        conflict: nil,
        quarantine: nil
      ), review: recovered.map { recovered in
        CloudRecoveryReviewInput(
          conflictKey: key,
          recovery: .snip(RecoveredSnip(
            id: recovered.id,
            currentSnipID: accepted.reference.domainID,
            recovered: recovered,
            conflictingFields: [.text, .source, .done, .placement],
            state: .promoted
          ))
        )
      }, movedSnipIDs: [])
    case .list:
      let current = local.lists.first { $0.id == accepted.reference.domainID }
      let moved = current.map { list in
        local.snips.filter { $0.listID == list.id }.map(CloudLocalSnipMutation.init)
      } ?? []
      return DeletedRecordPlan(item: CloudFullBatchItem(
        accepted: input,
        acceptedAction: .remove,
        expectedLocalRevision: accepted.localRevision,
        expectedSystemFields: accepted.systemFields,
        localPrecondition: current.map { .exactList(CloudLocalListMutation($0)) } ?? .none,
        localMutation: current.map { list in
          moved.isEmpty
            ? .removeList(list.id)
            : .removeListAndMoveSnips(list: CloudLocalListMutation(list), snips: moved)
        } ?? .none,
        conflict: nil,
        quarantine: nil
      ), review: nil, movedSnipIDs: moved.map(\.snipID))
    }
  }

  private static func quarantineItem(
    _ input: CloudAcceptedEntityInput,
    snapshot: CloudRecordSnapshot
  ) -> CloudFullBatchItem {
    CloudFullBatchItem(
      accepted: input,
      acceptedAction: .quarantine,
      expectedLocalRevision: nil,
      expectedSystemFields: nil,
      localMutation: .none,
      conflict: nil,
      quarantine: CloudQuarantineInput(
        key: "legacy|\(snapshot.id.zone.ownerName)|\(snapshot.id.zone.name)|\(snapshot.id.name)",
        reference: input.reference,
        identity: input.identity,
        payload: snapshot.shadow.data
      )
    )
  }

  private static func acceptedInput(
    _ record: CloudTypedSnipRecord,
    snapshot: CloudRecordSnapshot
  ) throws -> CloudAcceptedEntityInput {
    CloudAcceptedEntityInput(
      reference: CloudEntityReference(kind: .snip, domainID: record.domainID),
      identity: CloudFullSyncPersistence.storageIdentity(snapshot.id),
      schemaVersion: record.schemaVersion,
      acceptedData: try JSONEncoder().encode(record),
      presenceData: try JSONEncoder().encode(record),
      shadowData: snapshot.shadow.data,
      systemFields: snapshot.shadow.systemFields,
      dependencyListID: try CloudFullSyncPersistence.snipFields(record).placement.listID
    )
  }

  private static func acceptedInput(
    _ record: CloudTypedListRecord,
    snapshot: CloudRecordSnapshot
  ) throws -> CloudAcceptedEntityInput {
    CloudAcceptedEntityInput(
      reference: CloudEntityReference(kind: .list, domainID: record.domainID),
      identity: CloudFullSyncPersistence.storageIdentity(snapshot.id),
      schemaVersion: record.schemaVersion,
      acceptedData: try JSONEncoder().encode(record),
      presenceData: try JSONEncoder().encode(record),
      shadowData: snapshot.shadow.data,
      systemFields: snapshot.shadow.systemFields
    )
  }

}
