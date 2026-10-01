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
  let recoveryEvents: [CloudFullRecoveryInput]

  init(
    namespaceKey: CloudSyncNamespaceKey,
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID?,
    expectedEngine: Data?,
    local: SnipLibrarySnapshot,
    stored: CloudFullStorageSnapshot,
    attachmentStorage: CloudAttachmentStorageSnapshot,
    recoveryEvents: [CloudFullRecoveryInput]
  ) {
    self.namespaceKey = namespaceKey
    self.dataZone = dataZone
    self.payloadZone = payloadZone
    self.expectedEngine = expectedEngine
    self.local = local
    self.stored = stored
    self.attachmentStorage = attachmentStorage
    self.recoveryEvents = recoveryEvents
  }

  struct NormalizedBatch {
    let results: [NormalizedItem]
    let nextEngine: CloudEngineStateEnvelope?
    let attachmentOperationIDs: Set<CloudRecordID>
    let outboundBindings: [CloudFullOutboundBinding]
    let recoveryInputs: [CloudFullRecoveryInput]
    let outboundOperations: [CloudRecordID: CloudOutboundOperation]
    let sentItemResults: [CloudRecordID: CloudSendItemResult]
  }

  enum NormalizedItem {
    case record(CloudRecordSnapshot)
    case saved(CloudRecordSnapshot)
    case conflict(CloudRecordSnapshot)
    case deleted(CloudRecordID)
    case failed(CloudRecordID?, CloudOperationFailure)

    init(_ fetched: CloudFetchItemResult) {
      switch fetched {
      case .record(let snapshot): self = .record(snapshot)
      case .deleted(let id): self = .deleted(id)
      case .failed(let id, let failure): self = .failed(id, failure)
      }
    }

    // Attachments retain their own send-result reducer and submitted operations.
    var fetchResult: CloudFetchItemResult {
      switch self {
      case .record(let snapshot), .saved(let snapshot), .conflict(let snapshot): .record(snapshot)
      case .deleted(let id): .deleted(id)
      case .failed(let id, let failure): .failed(id, failure)
      }
    }

    var id: CloudRecordID? { fetchResult.id }
  }

  func plan(
    _ batch: CloudSyncBatch,
    inventorySource: CloudSyncBatch,
    blockedReplayIDs: Set<CloudRecordID>,
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
    let nextInventory = CloudFullFetchInventory.after(
      inventorySource, current: stored.namespaceState.initialFetchInventory,
      startsWithoutToken: expectedEngine == nil, dataZone: dataZone
    )
    let cleanInitialFetch = nextInventory?.canProveAbsence == true
      && CloudFullSyncPersistence.isCleanInitialMetadataFetch(
      batch, dataZone: dataZone
    )
    let batchObservedIDs = Set(normalized.results.compactMap(\.id))
    let observedIDs = batchObservedIDs
      .union((nextInventory?.observed ?? []).map(CloudFullSyncPersistence.recordID))
    var results = normalized.results
    if cleanInitialFetch {
      // Re-plan an unresolved snip read in an earlier batch of this attempt,
      // including one made ready by a cached list now proven absent remotely.
      // Use its accepted server body as the base and merge current local edits;
      // never blindly replay the cached local mutation after a restart.
      for accepted in allAccepted where accepted.reference.kind == .snip
        && nextInventory?.observed.contains(accepted.identity) == true
        && !batchObservedIDs.contains(CloudFullSyncPersistence.recordID(accepted.identity))
        && !blockedReplayIDs.contains(CloudFullSyncPersistence.recordID(accepted.identity))
      {
        let missingDependency = accepted.dependencyListID.map { listID in
          listID != SnipList.inbox.id && nextInventory?.observed.contains(
            CloudFullSyncPersistence.storageIdentity(.list(listID, in: dataZone))
          ) == false
        } == true
        guard accepted.isDeferred || missingDependency else { continue }
        let shadow = try CloudRecordShadow(data: accepted.shadowData)
        results.append(.record(try CloudKitRecordMapper.snapshot(shadow.record())))
      }
      // A fresh complete inventory can omit deleted records rather than returning
      // tombstones. Retire absent accepted snips through the normal deletion reducer.
      results.append(contentsOf: allAccepted
        .filter { $0.reference.kind == .snip }
        .map { CloudFullSyncPersistence.recordID($0.identity) }
        .filter { !observedIDs.contains($0) }
        .filter { !blockedReplayIDs.contains($0) }
        .map(NormalizedItem.deleted))
    }
    var attachmentTransitions: [CloudAttachmentTransition] = []
    var resolvedFetchIDs: Set<CloudRecordID> = []
    for normalizedItem in results {
      let result = normalizedItem.fetchResult
      switch try attachmentPlanner.reduce(result) {
      case .unhandled:
        break
      case .handled(let transition):
        if case .record(let snapshot) = result { resolvedFetchIDs.insert(snapshot.id) }
        if case .deleted(let id) = result { resolvedFetchIDs.insert(id) }
        if let transition { attachmentTransitions.append(transition) }
        continue
      }
      if case .saved(let snapshot) = normalizedItem {
        if let item = try Self.savedItem(snapshot, accepted: byReference) {
          items.append(item)
        }
        continue
      }
      switch result {
      case .record(let snapshot):
        if let item = try Self.recordItem(
          snapshot,
          namespaceKey: namespaceKey,
          local: local,
          accepted: byReference,
          conflicts: stored.conflicts,
          pendingDeleteReferences: Set(pendingDeletes.keys)
        ) {
          items.append(item)
          if item.acceptedAction == .upsert { resolvedFetchIDs.insert(snapshot.id) }
        }
      case .deleted(let id):
        resolvedFetchIDs.insert(id)
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
    // Reconcile parked intent with the current snip before dependency release.
    // This also keeps an ambiguous old absence on the normal conflict path.
    let arrivingListIDs = Set(items.compactMap {
      $0.acceptedAction == .upsert && $0.accepted.reference.kind == .list
        ? $0.accepted.reference.domainID : nil
    })
    let plannedReferences = Set(items.map { $0.accepted.reference })
    let failedBatchIDs = Set(normalized.results.compactMap { item -> CloudRecordID? in
      guard case .failed(let id, _) = item else { return nil }
      return id
    })
    for accepted in allAccepted where accepted.isDeferred
      && accepted.dependencyListID.map(arrivingListIDs.contains) == true
      && !plannedReferences.contains(accepted.reference)
      && (!batchObservedIDs.contains(CloudFullSyncPersistence.recordID(accepted.identity))
        || failedBatchIDs.contains(CloudFullSyncPersistence.recordID(accepted.identity)))
      && !blockedReplayIDs.contains(CloudFullSyncPersistence.recordID(accepted.identity))
    {
      let snapshot = try CloudKitRecordMapper.snapshot(CloudRecordShadow(data: accepted.shadowData).record())
      if let item = try Self.recordItem(
        snapshot, namespaceKey: namespaceKey, local: local, accepted: byReference,
        conflicts: stored.conflicts,
        pendingDeleteReferences: Set(pendingDeletes.keys)
      ) { items.append(item) }
      // This is a rebase of previously accepted intent, not a successful fetch.
      // Do not add its ID to resolvedFetchIDs: the failed-read sending barrier
      // remains until a real record read or deletion resolves it.
    }
    if cleanInitialFetch {
      // Preserve local lists, but discard bases proven absent from iCloud. Active
      // outbound planning will recreate those rows without an obsolete server base.
      for accepted in allAccepted where accepted.reference.kind == .list
        && !observedIDs.contains(CloudFullSyncPersistence.recordID(accepted.identity))
        && !blockedReplayIDs.contains(CloudFullSyncPersistence.recordID(accepted.identity))
      {
        items.append(CloudFullBatchItem(
          accepted: CloudFullSyncPersistence.acceptedInput(accepted),
          acceptedAction: .remove,
          expectedLocalRevision: accepted.localRevision,
          expectedSystemFields: accepted.systemFields,
          localMutation: .none,
          conflict: nil,
          quarantine: nil
        ))
        if pendingDeletes[accepted.reference]?.identity == accepted.identity {
          settledDeleteIdentities.append(accepted.identity)
        }
      }
    }
    let localListIDs = Set(local.lists.map(\.id))
    let deletedLocalListIDs = Set(items.compactMap {
      $0.acceptedAction == .remove && $0.accepted.reference.kind == .list
        && $0.localMutation != .none ? $0.accepted.reference.domainID : nil
    })
    let survivingLocalListIDs = localListIDs.subtracting(deletedLocalListIDs)
    let localSnipLists = Dictionary(uniqueKeysWithValues: local.snips.map { ($0.id, $0.listID) })
    var enrollment = stored.enrolledEntities
    for item in items where item.acceptedAction == .remove {
      if item.accepted.reference.kind == .list, item.localMutation == .none,
        localListIDs.contains(item.accepted.reference.domainID)
      { continue }
      enrollment.remove(item.accepted.reference)
    }
    let incomingLists = Set(items.compactMap {
      $0.acceptedAction == .upsert && $0.accepted.reference.kind == .list
        ? $0.accepted.reference.domainID : nil
    })
    enrollment.formUnion(incomingLists.map { CloudEntityReference(kind: .list, domainID: $0) })
    // Older active namespaces can omit virtual Inbox from enrollment. A repair's
    // accepted acknowledgement supplies the checked dependency needed to enroll it.
    if items.contains(where: {
      $0.acceptedAction == .upsert && $0.accepted.reference.kind == .snip
        && $0.accepted.dependencyListID == SnipList.inbox.id
        && byReference[$0.accepted.reference]?.wasMaterializedBeforeDeferral == true
    }) {
      enrollment.insert(CloudEntityReference(kind: .list, domainID: SnipList.inbox.id))
    }
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
      if let currentListID = localSnipLists[accepted.reference.domainID],
        currentListID == SnipList.inbox.id || survivingLocalListIDs.contains(currentListID)
      {
        enrollment.insert(CloudEntityReference(kind: .list, domainID: currentListID))
      }
      enrollment.insert(accepted.reference)
    }
    let graphRepairs = CloudFullGraphReconciler.repairs(
      completeInventory: cleanInitialFetch ? nextInventory?.observed : nil,
      dataZone: dataZone,
      accepted: acceptedAfterBatch,
      priorRepairs: Dictionary(uniqueKeysWithValues: allAccepted.compactMap {
        value in value.graphRepair.map { (value.reference, $0) }
      }),
      items: items,
      quarantines: stored.quarantines,
      local: local
    )
    enrollment.subtract(graphRepairs.map {
      CloudEntityReference(kind: .snip, domainID: $0.snipID)
    })
    // A quarantined row can leave enrollment without either a local item or a base.
    // Keep its archive, but defer enrollment until a checked base supplies its list.
    let localSnipIDs = Set(local.snips.map(\.id))
    enrollment = Set(enrollment.filter { reference in
      reference.kind != .snip || acceptedAfterBatch[reference] != nil
        || localSnipIDs.contains(reference.domainID)
    })
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
        ownedZones: Set([dataZone] + (payloadZone.map { [$0] } ?? [])),
        attachmentOperationIDs: normalized.attachmentOperationIDs,
        initialFetchInventory: nextInventory
      ),
      rawBatchData: rawBatchData,
      outboundBindings: normalized.outboundBindings,
      recoveryInputs: recoveryInputs,
      recoveryChanges: try {
        guard case .fetched = batch else { return [] }
        return try CloudFullSyncPersistence.fetchRecoveryChanges(recoveryEvents, resolved: resolvedFetchIDs)
      }(),
      recoveryReviews: recoveryReviews,
      graphRepairs: graphRepairs,
      settledDeleteIdentities: settledDeleteIdentities,
      attachmentTransitions: attachmentTransitions,
      items: items
    )
  }

  private static func savedItem(
    _ snapshot: CloudRecordSnapshot,
    accepted: [CloudEntityReference: CloudAcceptedEntity]
  ) throws -> CloudFullBatchItem? {
    let input: CloudAcceptedEntityInput
    let binding: CloudRecordBinding
    switch snapshot.recordType {
    case "Snip":
      let record = try CloudFullRecordCodec.snip(from: snapshot)
      input = try acceptedInput(record, snapshot: snapshot)
      binding = record.binding
    case "List":
      let record = try CloudFullRecordCodec.list(from: snapshot)
      input = try acceptedInput(record, snapshot: snapshot)
      binding = record.binding
    default:
      return nil
    }
    guard binding == .canonical else { return quarantineItem(input, snapshot: snapshot) }
    let base = accepted[input.reference]
    // This acknowledges the submitted save, not a remote edit. Advance the accepted
    // body and shadow without changing local rows: they may have changed or been
    // deleted since submission, including before the first save was accepted.
    return CloudFullBatchItem(
      accepted: input,
      expectedLocalRevision: base?.localRevision,
      expectedSystemFields: base?.systemFields,
      localMutation: .none,
      conflict: nil,
      quarantine: nil
    )
  }

  private static func recordItem(
    _ snapshot: CloudRecordSnapshot,
    namespaceKey: CloudSyncNamespaceKey,
    local: SnipLibrarySnapshot,
    accepted: [CloudEntityReference: CloudAcceptedEntity],
    conflicts: [CloudStoredConflict],
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
        let ancestor = try CloudFullSyncPersistence.snipFields(baseRecord)
        var currentFields = CloudFullSyncPersistence.snipFields(current, accepted: baseRecord)
        if base.isDeferred,
          let deferred = base.deferredLocalMutation,
          case .exactSnip(let before) = deferred.precondition,
          case .upsertSnip(let pending) = deferred.mutation
        {
          // The accepted shadow has already advanced, but this intent has not
          // touched the local snip. Its captured local row is the merge ancestor.
          // Reusing the server shadow as ancestor would mistake the old placement
          // for a new local move and discard the pending remote move.
          // Edits made after this intent was parked are newer, not concurrent
          // remote edits. Keep them and apply only its still-unchanged fields.
          let rebased = try CloudThreeWayMerge.snip(
            base: CloudFullSyncPersistence.snipFields(before, accepted: baseRecord),
            local: CloudFullSyncPersistence.snipFields(pending, accepted: baseRecord),
            server: currentFields
          )
          currentFields = rebased.merged
        }
        let result = try CloudThreeWayMerge.snip(
          base: ancestor, local: currentFields, server: serverFields
        )
        merged = result.merged
        conflict = try result.conflict.map { payload in
          let key = CloudConflictKey.make(
            namespaceKey: namespaceKey,
            recordID: snapshot.id,
            ancestorSystemFields: base.systemFields,
            serverSystemFields: snapshot.shadow.systemFields
          )
          let priorPayload = conflicts.first { prior in
            prior.key == key && prior.reference == input.reference && prior.format == .snipMergeV1
              && (try? JSONDecoder().decode(CloudSnipConflictPayload.self, from: prior.payload)) == payload
          }?.payload
          return CloudConflictInput(
            key: key,
            reference: input.reference,
            format: .snipMergeV1,
            payload: try priorPayload ?? JSONEncoder().encode(payload),
            recovery: .snip(CloudFullSyncPersistence.recoveredSnip(
              payload,
              key: key,
              attachments: current.attachments
            ))
          )
        }
      } else if current == nil, let base,
        !base.isDeferred || base.wasMaterializedBeforeDeferral || base.hasUnresolvedLegacyAbsence
      {
        let baseFields = try CloudFullSyncPersistence.snipFields(
          CloudFullSyncPersistence.snipRecord(base)
        )
        if !base.hasUnresolvedLegacyAbsence,
          CloudFullSyncPersistence.sameSnipFields(baseFields, serverFields)
        {
          return CloudFullBatchItem(
            accepted: input,
            expectedLocalRevision: base.localRevision,
            expectedSystemFields: base.systemFields,
            localPrecondition: .requireMissing,
            localMutation: .none,
            conflict: nil,
            quarantine: nil
          )
        }
        let key = CloudConflictKey.make(
          namespaceKey: namespaceKey,
          recordID: snapshot.id,
          ancestorSystemFields: base.systemFields,
          serverSystemFields: snapshot.shadow.systemFields
        )
        let payload = CloudSnipDeleteConflictPayload(server: serverFields)
        let priorPayload = conflicts.first {
          $0.key == key && $0.reference == input.reference && $0.format == .snipMergeV1
            && (try? JSONDecoder().decode(CloudSnipDeleteConflictPayload.self, from: $0.payload)) == payload
        }?.payload
        return CloudFullBatchItem(
          accepted: input,
          expectedLocalRevision: base.localRevision,
          expectedSystemFields: base.systemFields,
          localPrecondition: .requireMissing,
          localMutation: .none,
          conflict: CloudConflictInput(
            key: key,
            reference: input.reference,
            format: .snipMergeV1,
            payload: try priorPayload ?? JSONEncoder().encode(payload)
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
          localPrecondition: .requireMissing,
          localMutation: .none,
          conflict: nil,
          quarantine: nil
        )
      }
      return CloudFullBatchItem(
        accepted: input,
        expectedLocalRevision: base.localRevision,
        expectedSystemFields: base.systemFields,
        localPrecondition: .requireMissing,
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
          pinnedAt: snip.pinnedAt,
          manualSortKey: snip.manualSortKey,
          attachments: snip.attachments
        )
      }
      return DeletedRecordPlan(item: CloudFullBatchItem(
        accepted: input,
        acceptedAction: .remove,
        expectedLocalRevision: accepted.localRevision,
        expectedSystemFields: accepted.systemFields,
        localPrecondition: current.map { .exactSnip(CloudLocalSnipMutation($0)) } ?? .requireMissing,
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
        localPrecondition: current.map { .exactList(CloudLocalListMutation($0)) } ?? .requireMissing,
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

  static func acceptedInput(
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

  static func acceptedInput(
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
