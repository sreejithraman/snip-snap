import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  func makeCommit(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?,
    rawBatchData: Data
  ) async throws -> CloudFullBatchCommit {
    let wire = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
    let expectedEngine = wire.engineState
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let attachmentStorage = try await library.cloudAttachmentStorageSnapshot(
      namespaceKey: namespaceKey
    )
    let allAccepted = stored.readyEntities + stored.deferredEntities
    let byReference = Dictionary(uniqueKeysWithValues: allAccepted.map { ($0.reference, $0) })
    let byIdentity = Dictionary(uniqueKeysWithValues: allAccepted.map { ($0.identity, $0) })
    let attachmentByMetadataIdentity = Dictionary(
      attachmentStorage.publications.map { ($0.metadataIdentity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let attachmentByPayloadIdentity = Dictionary(
      attachmentStorage.publications.map { ($0.metadata.payloadIdentity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let cleanupByIdentity = Dictionary(
      attachmentStorage.cleanups.map { ($0.identity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var attachmentOperationIDs: Set<CloudRecordID> = []
    var items: [CloudFullBatchItem] = []
    var seen: [CloudRecordID: CloudFetchItemResult] = [:]
    var outboundBindings: [CloudFullOutboundBinding] = []
    var recoveryInputs: [CloudFullRecoveryInput] = []
    var recoveryReviews: [CloudRecoveryReviewInput] = []
    var settledDeleteIdentities: [CloudTextStorageIdentity] = []
    let pendingDeletes = Dictionary(uniqueKeysWithValues:
      stored.pendingDeletes.map { ($0.reference, $0) }
    )
    var attachmentTransitions: [CloudAttachmentTransition] = []
    var outboundOperations: [CloudRecordID: CloudOutboundOperation] = [:]
    var sentItemResults: [CloudRecordID: CloudSendItemResult] = [:]
    let results: [CloudFetchItemResult]
    let nextEngine: CloudEngineStateEnvelope?
    switch batch {
    case .fetched(let fetched):
      guard outbound == nil else { throw CloudTransportError.invalidRecord }
      for item in fetched.items {
        guard let id = item.id else { continue }
        if let prior = seen[id], prior != item { throw CloudTransportError.invalidRecord }
        seen[id] = item
      }
      results = seen.values.sorted { ($0.id?.name ?? "") < ($1.id?.name ?? "") }
      nextEngine = fetched.engineState
      if let kind = Self.fetchRecoveryKind(fetched) {
        recoveryInputs = [CloudFullRecoveryInput(
          namespaceKey: namespaceKey,
          batchID: fetched.id,
          kind: kind,
          outboundData: Data(),
          resultData: rawBatchData
        )]
      }
    case .sent(let sent):
      guard let outbound else { throw CloudTransportError.invalidRecord }
      let operations = try Self.uniqueOperations(outbound.operations)
      outboundOperations = operations
      if let payloadZone {
        attachmentOperationIDs = Set(operations.keys).intersection(
          Self.plannedAttachmentOperationIDs(
            attachmentStorage,
            dataZone: dataZone,
            payloadZone: payloadZone
          )
        )
      }
      var sentResults: [CloudRecordID: CloudSendItemResult] = [:]
      for result in sent.items {
        guard operations[result.id] != nil,
          sentResults.updateValue(result, forKey: result.id) == nil
        else { throw CloudTransportError.invalidRecord }
      }
      guard Set(sentResults.keys) == Set(operations.keys) else {
        throw CloudTransportError.invalidRecord
      }
      sentItemResults = sentResults
      outboundBindings = try operations.values
        .map(Self.outboundBinding)
        .sorted { Self.identityOrder($0.identity) < Self.identityOrder($1.identity) }
      results = try sentResults.values.map { result in
        guard let operation = operations[result.id] else {
          throw CloudTransportError.invalidRecord
        }
        switch result {
        case .saved(let value):
          guard case .save(let draft) = operation else {
            throw CloudTransportError.invalidRecord
          }
          guard value.recordType == draft.recordType else {
            return .failed(value.id, .invalidRecord)
          }
          return .record(value)
        case .deleted(let id):
          guard case .delete = operation else { throw CloudTransportError.invalidRecord }
          return .deleted(id)
        case .conflict(let id, let value):
          if case .save(let draft) = operation, value.recordType != draft.recordType {
            return .failed(id, .invalidRecord)
          }
          return .record(value)
        case .unknownItem(let id):
          if case .save(let draft) = operation,
            draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
              || draft.recordType == CloudAttachmentRecordCodec.payloadRecordType
          {
            return .failed(id, .invalidRecord)
          }
          return .deleted(id)
        case .failed(let id, let failure):
          return .failed(id, failure)
        }
      }
      .sorted { ($0.id?.name ?? "") < ($1.id?.name ?? "") }
      nextEngine = sent.engineState
      if let kind = Self.sendRecoveryKind(
        sent,
        normalized: results,
        attachmentOperationIDs: attachmentOperationIDs
      ) {
        recoveryInputs = [CloudFullRecoveryInput(
          namespaceKey: namespaceKey,
          batchID: sent.id,
          kind: kind,
          outboundData: try JSONEncoder().encode(outbound),
          resultData: rawBatchData
        )]
      }
    }
    for result in results {
      switch result {
      case .record(let snapshot):
        if snapshot.recordType == CloudAttachmentRecordCodec.metadataRecordType,
          outboundOperations[snapshot.id] == nil || attachmentOperationIDs.contains(snapshot.id)
        {
          guard let payloadZone else { throw CloudAttachmentStorageError.invalidMetadata }
          let metadata = try CloudAttachmentRecordCodec.metadata(
            from: snapshot,
            metadataZone: dataZone,
            payloadZone: payloadZone
          )
          let identity = Self.storageIdentity(snapshot.id)
          if outboundOperations[snapshot.id] != nil,
            let local = attachmentByMetadataIdentity[identity]
          {
            if case .conflict? = sentItemResults[snapshot.id] {
              if case .delete? = outboundOperations[snapshot.id] {
                attachmentTransitions.append(.metadataDeleteConflict(
                  attachmentID: local.metadata.attachmentID,
                  expectedRevision: local.revision,
                  shadowData: snapshot.shadow.data,
                  systemFields: snapshot.shadow.systemFields,
                  payloadIdentity: metadata.payloadIdentity
                ))
              } else {
                attachmentTransitions.append(.metadataConflict(
                  attachmentID: local.metadata.attachmentID,
                  expectedRevision: local.revision,
                  shadowData: snapshot.shadow.data,
                  systemFields: snapshot.shadow.systemFields
                ))
              }
            } else {
              attachmentTransitions.append(.metadataAccepted(
                attachmentID: local.metadata.attachmentID,
                expectedRevision: local.revision,
                shadowData: snapshot.shadow.data,
                systemFields: snapshot.shadow.systemFields
              ))
            }
          } else {
            attachmentTransitions.append(.remoteMetadataAccepted(
              metadata: metadata,
              metadataIdentity: identity,
              shadowData: snapshot.shadow.data,
              systemFields: snapshot.shadow.systemFields
            ))
          }
          continue
        }
        if snapshot.recordType == CloudAttachmentRecordCodec.payloadRecordType,
          (outboundOperations[snapshot.id] == nil
            || attachmentOperationIDs.contains(snapshot.id)),
          let local = attachmentByPayloadIdentity[Self.storageIdentity(snapshot.id)]
        {
          guard let payloadZone, snapshot.id.zone == payloadZone else {
            throw CloudAttachmentStorageError.invalidMetadata
          }
          if case .conflict? = sentItemResults[snapshot.id] {
            attachmentTransitions.append(.payloadCollision(
              attachmentID: local.metadata.attachmentID,
              expectedRevision: local.revision,
              replacementIdentity: CloudTextStorageIdentity(
                zoneName: payloadZone.name,
                ownerName: payloadZone.ownerName,
                recordName: UUID().uuidString.lowercased()
              )
            ))
          } else {
            attachmentTransitions.append(.payloadAccepted(
              attachmentID: local.metadata.attachmentID,
              expectedRevision: local.revision,
              shadowData: snapshot.shadow.data,
              systemFields: snapshot.shadow.systemFields
            ))
          }
          continue
        }
        if snapshot.recordType == CloudAttachmentRecordCodec.payloadRecordType,
          attachmentOperationIDs.contains(snapshot.id),
          case .conflict? = sentItemResults[snapshot.id],
          let cleanup = cleanupByIdentity[Self.storageIdentity(snapshot.id)]
        {
          attachmentTransitions.append(.cleanupConflict(
            identity: cleanup.identity,
            expectedRevision: cleanup.revision,
            shadowData: snapshot.shadow.data
          ))
          continue
        }
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
        let identity = Self.storageIdentity(id)
        if let local = attachmentByMetadataIdentity[identity] {
          if attachmentOperationIDs.contains(id) {
            attachmentTransitions.append(.metadataDeleteAccepted(
              attachmentID: local.metadata.attachmentID,
              expectedRevision: local.revision
            ))
            continue
          } else if outboundOperations[id] == nil {
            attachmentTransitions.append(.remoteMetadataDeleted(metadataIdentity: identity))
            continue
          }
        }
        if let cleanup = cleanupByIdentity[identity],
          attachmentOperationIDs.contains(id) || outboundOperations[id] == nil
        {
          attachmentTransitions.append(.cleanupAccepted(
            identity: identity,
            expectedRevision: cleanup.revision
          ))
          continue
        }
        guard let accepted = byIdentity[Self.storageIdentity(id)] else { continue }
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
            namespaceKey: namespaceKey,
            batchID: batch.id,
            kind: .deletedListPlacement,
            outboundData: try encoder.encode(accepted.reference.domainID),
            resultData: try encoder.encode(plan.movedSnipIDs.sorted {
              $0.uuidString < $1.uuidString
            })
          ))
        }
      case .failed(let id, let failure):
        if let id,
          attachmentOperationIDs.contains(id),
          let cleanup = cleanupByIdentity[Self.storageIdentity(id)]
        {
          attachmentTransitions.append(.cleanupFailed(
            identity: cleanup.identity,
            expectedRevision: cleanup.revision,
            failure: Self.attachmentFailure(failure)
          ))
          continue
        }
        if let id,
          attachmentOperationIDs.contains(id),
          let local = attachmentByMetadataIdentity[Self.storageIdentity(id)]
            ?? attachmentByPayloadIdentity[Self.storageIdentity(id)]
        {
          if case .unknownItem? = sentItemResults[id],
            local.metadataIdentity == Self.storageIdentity(id)
          {
            let replacementAttachmentID = UUID()
            attachmentTransitions.append(.metadataUnknown(
              attachmentID: local.metadata.attachmentID,
              expectedRevision: local.revision,
              replacementAttachmentID: replacementAttachmentID,
              replacementMetadataIdentity: CloudTextStorageIdentity(
                zoneName: dataZone.name,
                ownerName: dataZone.ownerName,
                recordName: "a-\(replacementAttachmentID.uuidString.lowercased())"
              )
            ))
          } else if case .unknownItem? = sentItemResults[id],
            local.metadata.payloadIdentity == Self.storageIdentity(id),
            let payloadZone
          {
            attachmentTransitions.append(.payloadCollision(
              attachmentID: local.metadata.attachmentID,
              expectedRevision: local.revision,
              replacementIdentity: CloudTextStorageIdentity(
                zoneName: payloadZone.name,
                ownerName: payloadZone.ownerName,
                recordName: UUID().uuidString.lowercased()
              )
            ))
          } else {
            attachmentTransitions.append(.operationFailed(
              attachmentID: local.metadata.attachmentID,
              expectedRevision: local.revision,
              failure: Self.attachmentFailure(failure)
            ))
          }
        }
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
      ($0.reference, Self.acceptedInput($0))
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
      namespaceKey: namespaceKey,
      batchID: batch.id,
      expectedEngineState: expectedEngine,
      nextEngineState: try Self.engineData(nextEngine),
      nextEnrollment: enrollment,
      expectedNamespaceRevision: stored.namespaceState.revision,
      nextNamespaceState: Self.nextNamespaceState(
        current: stored.namespaceState,
        batch: batch,
        dataZone: dataZone,
        attachmentOperationIDs: attachmentOperationIDs
      ),
      rawBatchData: rawBatchData,
      outboundBindings: outboundBindings,
      recoveryInputs: recoveryInputs,
      recoveryReviews: recoveryReviews,
      settledDeleteIdentities: settledDeleteIdentities,
      attachmentTransitions: attachmentTransitions,
      items: items
    )
  }

  private static func attachmentFailure(
    _ failure: CloudOperationFailure
  ) -> CloudAttachmentFailure {
    switch failure {
    case .retryable: .retryable
    case .quotaExceeded: .quotaExceeded
    case .rejected: .rejected
    case .invalidRecord: .invalidRecord
    case .zoneMissing: .zoneMissing
    }
  }

  private static func fetchRecoveryKind(
    _ batch: CloudFetchedBatch
  ) -> CloudFullRecoveryKind? {
    if batch.databaseEvents.contains(where: isDestructiveReset) { return .destructiveReset }
    let failures = batch.items.compactMap { item -> CloudOperationFailure? in
      guard case .failed(_, let failure) = item else { return nil }
      return failure
    } + batch.databaseEvents.compactMap { event -> CloudOperationFailure? in
      guard case .failed(_, let failure) = event else { return nil }
      return failure
    } + batch.zoneEvents.compactMap { event -> CloudOperationFailure? in
      guard case .failed(_, let failure) = event else { return nil }
      return failure
    }
    let relevant = failures.filter { $0 != .zoneMissing }
    guard !relevant.isEmpty else { return nil }
    return relevant.allSatisfy { $0 == .retryable } ? .retryableFetch : .terminalFetch
  }

  private static func sendRecoveryKind(
    _ batch: CloudSentBatch,
    normalized: [CloudFetchItemResult],
    attachmentOperationIDs: Set<CloudRecordID>
  ) -> CloudFullRecoveryKind? {
    if batch.databaseEvents.contains(where: isDestructiveReset) { return .destructiveReset }
    let failures = normalized.compactMap { item -> CloudOperationFailure? in
      guard case .failed(let id, let failure) = item else { return nil }
      if failure != .retryable, let id, attachmentOperationIDs.contains(id)
      {
        return nil
      }
      return failure
    } + batch.databaseEvents.compactMap { event -> CloudOperationFailure? in
      guard case .failed(_, let failure) = event else { return nil }
      return failure
    } + batch.zoneEvents.compactMap { event -> CloudOperationFailure? in
      guard case .failed(_, let failure) = event else { return nil }
      return failure
    }
    let relevant = failures.filter { $0 != .zoneMissing }
    guard !relevant.isEmpty else { return nil }
    return relevant.allSatisfy { $0 == .retryable } ? .retryableSend : .terminalSend
  }

  private static func nextNamespaceState(
    current: CloudFullNamespaceState,
    batch: CloudSyncBatch,
    dataZone: CloudZoneID,
    attachmentOperationIDs: Set<CloudRecordID>
  ) -> CloudFullNamespaceState {
    var phase = current.phase
    var zoneCreationPending = current.zoneCreationPending
    switch batch {
    case .fetched(let fetched):
      if fetched.databaseEvents.contains(where: isDestructiveReset) {
        phase = .blocked
        zoneCreationPending = false
      } else if hasMissingZone(fetched) {
        if current.phase == .active {
          phase = .blocked
        } else {
          phase = .remoteCheckedMissingZone
        }
      } else if fetchRecoveryKind(fetched) == nil {
        if current.phase != .active && current.phase != .seeding && current.phase != .blocked {
          phase = fetched.items.contains(where: {
            if case .record = $0 { true } else { false }
          }) ? .active : .remoteChecked
        }
      }
    case .sent(let sent):
      if sent.databaseEvents.contains(where: isDestructiveReset) {
        phase = .blocked
        zoneCreationPending = false
      } else if hasMissingZone(sent, attachmentOperationIDs: attachmentOperationIDs) {
        if current.phase == .seeding {
          zoneCreationPending = true
        } else {
          phase = .blocked
        }
      } else if current.phase == .seeding {
        let hasIncomplete = sent.items.contains { item in
          if case .failed(_, let failure) = item { failure == .retryable }
          else { false }
        }
        if !hasIncomplete {
          if !zoneCreationPending || sent.databaseEvents.contains(where: { event in
            if case .zoneSaved(let zone) = event { zone == dataZone } else { false }
          }) {
            phase = .active
            zoneCreationPending = false
          }
        }
      }
    }
    return CloudFullNamespaceState(
      revision: current.revision + 1,
      phase: phase,
      zoneCreationPending: zoneCreationPending
    )
  }

  private static func isDestructiveReset(_ event: CloudDatabaseEvent) -> Bool {
    switch event {
    case .zoneDeleted(_, reason: .purged), .zoneDeleted(_, reason: .encryptedDataReset): true
    default: false
    }
  }

  private static func hasMissingZone(_ batch: CloudFetchedBatch) -> Bool {
    batch.databaseEvents.contains { event in
      switch event {
      case .zoneDeleted(_, reason: .deleted), .failed(_, .zoneMissing): true
      default: false
      }
    } || batch.zoneEvents.contains { event in
      if case .failed(_, .zoneMissing) = event { true } else { false }
    }
  }

  private static func hasMissingZone(
    _ batch: CloudSentBatch,
    attachmentOperationIDs: Set<CloudRecordID>
  ) -> Bool {
    batch.items.contains { item in
      if case .failed(let id, .zoneMissing) = item {
        !attachmentOperationIDs.contains(id)
      } else { false }
    } || batch.databaseEvents.contains { event in
      if case .failed(_, .zoneMissing) = event { true } else { false }
    } || batch.zoneEvents.contains { event in
      if case .failed(_, .zoneMissing) = event { true } else { false }
    }
  }
  private static func recordItem(
    _ snapshot: CloudRecordSnapshot,
    namespaceKey: String,
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
      let serverFields = try snipFields(server)
      var merged = serverFields
      var conflict: CloudConflictInput?
      if let current, let base {
        let baseRecord = try snipRecord(base)
        let result = try CloudThreeWayMerge.snip(
          base: try snipFields(baseRecord),
          local: snipFields(current, accepted: baseRecord),
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
            recovery: .snip(recoveredSnip($0, key: key, attachments: current.attachments))
          )
        }
      } else if current == nil, let base {
        let baseFields = try snipFields(snipRecord(base))
        if sameSnipFields(baseFields, serverFields) {
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
        let localFields = snipFields(current, accepted: nil)
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
            recovery: .snip(recoveredSnip(payload, key: key, attachments: current.attachments))
          )
        }
      }
      return CloudFullBatchItem(
        accepted: input,
        expectedLocalRevision: base?.localRevision,
        expectedSystemFields: base?.systemFields,
        localPrecondition: current.map { .exactSnip(CloudLocalSnipMutation($0)) }
          ?? .requireMissing,
        localMutation: .upsertSnip(localMutation(merged)),
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
    let serverFields = try listFields(server)
    var merged = serverFields
    var conflict: CloudConflictInput?
    if let current, let base {
      let result = try CloudThreeWayMerge.list(
        base: try listFields(listRecord(base)),
        local: listFields(current, updatedAt: serverFields.updatedAt),
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
          recovery: .list(recoveredList($0, key: key))
        )
      }
    } else if current == nil, let base {
      let baseFields = try listFields(listRecord(base))
      if sameListFields(baseFields, serverFields) {
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
      localMutation: .upsertList(localList(merged)),
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
    namespaceKey: String,
    local: SnipLibrarySnapshot,
    hasPendingDelete: Bool
  ) throws -> DeletedRecordPlan {
    let input = acceptedInput(accepted)
    switch accepted.reference.kind {
    case .snip:
      let current = local.snips.first { $0.id == accepted.reference.domainID }
      let acceptedRecord = try snipRecord(accepted)
      let shouldRecover = try current.map { snip in
        if hasPendingDelete { return false }
        return !sameSnipFields(
          try snipFields(acceptedRecord),
          snipFields(snip, accepted: acceptedRecord)
        )
          || !snip.attachments.isEmpty
      } ?? false
      let key = CloudConflictKey.make(
        namespaceKey: namespaceKey,
        recordID: recordID(accepted.identity),
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
      identity: storageIdentity(snapshot.id),
      schemaVersion: record.schemaVersion,
      acceptedData: try JSONEncoder().encode(record),
      presenceData: try JSONEncoder().encode(record),
      shadowData: snapshot.shadow.data,
      systemFields: snapshot.shadow.systemFields,
      dependencyListID: try snipFields(record).placement.listID
    )
  }

  private static func acceptedInput(
    _ record: CloudTypedListRecord,
    snapshot: CloudRecordSnapshot
  ) throws -> CloudAcceptedEntityInput {
    CloudAcceptedEntityInput(
      reference: CloudEntityReference(kind: .list, domainID: record.domainID),
      identity: storageIdentity(snapshot.id),
      schemaVersion: record.schemaVersion,
      acceptedData: try JSONEncoder().encode(record),
      presenceData: try JSONEncoder().encode(record),
      shadowData: snapshot.shadow.data,
      systemFields: snapshot.shadow.systemFields
    )
  }

  static func acceptedInput(_ entity: CloudAcceptedEntity) -> CloudAcceptedEntityInput {
    CloudAcceptedEntityInput(
      reference: entity.reference,
      identity: entity.identity,
      schemaVersion: entity.schemaVersion,
      acceptedData: entity.acceptedData,
      presenceData: entity.presenceData,
      shadowData: entity.shadowData,
      systemFields: entity.systemFields,
      dependencyListID: entity.dependencyListID
    )
  }

  static func snipRecord(_ entity: CloudAcceptedEntity) throws -> CloudTypedSnipRecord {
    try CloudFullRecordCodec.snip(from: snapshot(entity))
  }

  static func listRecord(_ entity: CloudAcceptedEntity) throws -> CloudTypedListRecord {
    try CloudFullRecordCodec.list(from: snapshot(entity))
  }

  private static func snapshot(_ entity: CloudAcceptedEntity) throws -> CloudRecordSnapshot {
    let shadow = try shadow(entity)
    guard shadow.systemFields == entity.systemFields else { throw CloudRecordError.invalidShadow }
    let decoded = try CloudKitRecordMapper.snapshot(shadow.record())
    return CloudRecordSnapshot(
      id: decoded.id,
      recordType: decoded.recordType,
      schemaVersion: decoded.schemaVersion,
      routingFields: decoded.routingFields,
      encryptedFields: decoded.encryptedFields,
      assetFields: decoded.assetFields,
      shadow: shadow,
      completeness: decoded.completeness
    )
  }

  static func shadow(_ entity: CloudAcceptedEntity) throws -> CloudRecordShadow {
    try CloudRecordShadow(data: entity.shadowData)
  }

  static func snipFields(_ record: CloudTypedSnipRecord) throws -> CloudSnipMergeFields {
    CloudSnipMergeFields(
      id: record.domainID,
      requestID: value(record.requestID, default: record.domainID),
      createdAt: value(record.createdAt, default: Date(timeIntervalSince1970: 0)),
      originRaw: value(record.origin, default: SnipOrigin.quickEntry.rawValue),
      text: try required(record.text, "text"),
      source: value(record.source, default: nil),
      isDone: value(record.isDone, default: false),
      placement: try value(record.placement, default: CloudSnipPlacement(
        listID: SnipList.inbox.id,
        orderKey: try legacyOrderKey(record.domainID)
      )),
      updatedAt: value(record.updatedAt, default: Date(timeIntervalSince1970: 0))
    )
  }

  static func snipFields(
    _ snip: Snip,
    accepted: CloudTypedSnipRecord?
  ) -> CloudSnipMergeFields {
    CloudSnipMergeFields(
      id: snip.id,
      requestID: accepted.map { value($0.requestID, default: snip.requestID) } ?? snip.requestID,
      createdAt: accepted.map { value($0.createdAt, default: snip.createdAt) } ?? snip.createdAt,
      originRaw: accepted.map { value($0.origin, default: snip.origin.rawValue) }
        ?? snip.origin.rawValue,
      text: snip.content,
      source: snip.source,
      isDone: snip.isDone,
      placement: CloudSnipPlacement(listID: snip.listID, orderKey: snip.manualSortKey),
      updatedAt: snip.updatedAt
    )
  }

  static func listFields(_ record: CloudTypedListRecord) throws -> CloudListMergeFields {
    CloudListMergeFields(
      id: record.domainID,
      desiredName: try required(record.desiredName, "desiredName"),
      systemImage: try required(record.systemImage, "systemImage"),
      orderKey: try required(record.orderKey, "orderKey"),
      updatedAt: value(record.updatedAt, default: Date(timeIntervalSince1970: 0))
    )
  }

  static func listFields(_ list: SnipList, updatedAt: Date) -> CloudListMergeFields {
    CloudListMergeFields(
      id: list.id,
      desiredName: list.desiredName,
      systemImage: list.systemImage,
      orderKey: list.sortKey,
      updatedAt: updatedAt
    )
  }

  static func sameSnipFields(
    _ lhs: CloudSnipMergeFields,
    _ rhs: CloudSnipMergeFields
  ) -> Bool {
    lhs.id == rhs.id
      && lhs.requestID == rhs.requestID
      && lhs.createdAt == rhs.createdAt
      && lhs.originRaw == rhs.originRaw
      && lhs.text == rhs.text
      && lhs.source == rhs.source
      && lhs.isDone == rhs.isDone
      && lhs.placement == rhs.placement
  }

  static func sameListFields(
    _ lhs: CloudListMergeFields,
    _ rhs: CloudListMergeFields
  ) -> Bool {
    lhs.id == rhs.id
      && lhs.desiredName == rhs.desiredName
      && lhs.systemImage == rhs.systemImage
      && lhs.orderKey == rhs.orderKey
  }

  static func localMutation(_ value: CloudSnipMergeFields) -> CloudLocalSnipMutation {
    CloudLocalSnipMutation(
      snipID: value.id,
      requestID: value.requestID,
      createdAt: value.createdAt,
      updatedAt: value.updatedAt,
      content: value.text,
      origin: SnipOrigin(rawValue: value.originRaw) ?? .quickEntry,
      source: value.source,
      listID: value.placement.listID,
      isDone: value.isDone,
      orderKey: value.placement.orderKey
    )
  }

  static func localList(_ value: CloudListMergeFields) -> SnipList {
    SnipList(
      id: value.id,
      desiredName: value.desiredName,
      resolvedName: value.desiredName,
      systemImage: value.systemImage,
      sortKey: value.orderKey
    )
  }

  static func recoveredSnip(
    _ payload: CloudSnipConflictPayload,
    key: String,
    attachments: [SnipAttachment]
  ) -> RecoveredSnip {
    let recoveryID = CloudConflictKey.recoveryID(for: key)
    let value = payload.local
    let snip = Snip(
      id: recoveryID,
      requestID: recoveryID,
      createdAt: value.createdAt,
      updatedAt: value.updatedAt,
      content: value.text,
      origin: SnipOrigin(rawValue: value.originRaw) ?? .quickEntry,
      source: value.source,
      listID: value.placement.listID,
      isDone: value.isDone,
      manualSortKey: value.placement.orderKey,
      attachments: attachments
    )
    return RecoveredSnip(
      id: recoveryID,
      currentSnipID: value.id,
      recovered: snip,
      conflictingFields: Set(payload.fields.map { field in
        switch field {
        case .text: .text
        case .source: .source
        case .isDone: .done
        case .placement: .placement
        }
      })
    )
  }

  static func recoveredList(
    _ payload: CloudListConflictPayload,
    key: String
  ) -> RecoveredListEdit {
    RecoveredListEdit(
      id: CloudConflictKey.recoveryID(for: key),
      currentListID: payload.local.id,
      recovered: localList(payload.local),
      conflictingFields: Set(payload.fields.map { field in
        switch field {
        case .desiredName: .name
        case .systemImage: .icon
        }
      })
    )
  }

  private static func legacyOrderKey(_ id: UUID) throws -> SnipOrderKey {
    var data = Data()
    withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
    data.append(0x80)
    return try SnipOrderKey(data: data)
  }

  private static func required<Value>(
    _ presence: CloudFieldPresence<Value>,
    _ key: String
  ) throws -> Value {
    guard case .value(let value) = presence else { throw CloudRecordError.missingField(key) }
    return value
  }

  private static func value<Value>(
    _ presence: CloudFieldPresence<Value>,
    default fallback: @autoclosure () throws -> Value
  ) rethrows -> Value {
    switch presence {
    case .missing: try fallback()
    case .value(let value): value
    }
  }

  private static func engineData(_ value: CloudEngineStateEnvelope?) throws -> Data? {
    try value.map { try JSONEncoder().encode($0) }
  }

  static func storageIdentity(_ id: CloudRecordID) -> CloudTextStorageIdentity {
    CloudTextStorageIdentity(
      zoneName: id.zone.name,
      ownerName: id.zone.ownerName,
      recordName: id.name
    )
  }

  static func recordID(_ identity: CloudTextStorageIdentity) -> CloudRecordID {
    CloudRecordID(
      zone: CloudZoneID(name: identity.zoneName, ownerName: identity.ownerName),
      name: identity.recordName
    )
  }
}
