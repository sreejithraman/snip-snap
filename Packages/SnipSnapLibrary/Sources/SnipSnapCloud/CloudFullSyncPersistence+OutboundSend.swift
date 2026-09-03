import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  package func clearRetryableRecoveryEvents(
    kind: CloudFullRecoveryKind
  ) async throws -> Bool {
    guard kind == .retryableFetch || kind == .retryableSend else { return false }
    let recovery = try await library.cloudFullRecoveryEvents(namespaceKey: namespaceKey)
      .filter { $0.kind == kind }
    guard !recovery.isEmpty else { return false }
    let keys = Set(recovery.map {
      "full-recovery-\($0.batchID.uuidString.lowercased())"
    })
    try await library.clearCloudFullRecoveryEvents(namespaceKey: namespaceKey, keys: keys)
    return true
  }

  package func isSyncSettled() async throws -> Bool {
    let pending = try await pendingChanges()
    guard pending.operations.isEmpty, pending.zonesToSave.isEmpty else { return false }
    return try await unresolvedSyncIssue() == nil
  }

  package func unresolvedSyncIssue() async throws -> SyncedContentSyncIssue? {
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let recovery = try await library.cloudFullRecoveryEvents(namespaceKey: namespaceKey)
    let attachments = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
    var issues = recovery.map(Self.storedSyncIssue(for:))
    if stored.namespaceState.phase == .blocked
      || !stored.conflicts.isEmpty
      || !stored.quarantines.isEmpty
    {
      issues.append(.appDataIssue)
    }
    issues += attachments.publications.compactMap(\.lastFailure).map(Self.syncIssue(for:))
    issues += attachments.cleanups.compactMap(\.lastFailure).map(Self.syncIssue(for:))
    return CloudSyncIssueError.preferredIssue(from: issues)
  }

  package func prepareManualRetry() async throws {
    let recovery = try await library.cloudFullRecoveryEvents(namespaceKey: namespaceKey)
    let keys = Set(recovery.compactMap { event -> String? in
      guard event.kind == .terminalFetch || event.kind == .terminalSend else { return nil }
      guard let issues = Self.storedSyncIssues(for: event),
        issues.allSatisfy(\.canRetry)
      else { return nil }
      return "full-recovery-\(event.batchID.uuidString.lowercased())"
    })
    if !keys.isEmpty {
      try await library.clearCloudFullRecoveryEvents(namespaceKey: namespaceKey, keys: keys)
    }
    try await library.clearManuallyRetryableCloudAttachmentFailures(namespaceKey: namespaceKey)
  }

  private static func syncIssue(for failure: CloudAttachmentFailure) -> SyncedContentSyncIssue {
    switch failure {
    case .retryable: .someChangesPending
    case .quotaExceeded: .iCloudStorageFull
    case .updateRequired: .updateRequired
    case .accessDenied: .accessDenied
    case .attachmentMissing: .attachmentMissing
    case .rejected, .invalidRecord: .appDataIssue
    case .zoneMissing: .appDataIssue
    case .localStorage: .attachmentUnavailable
    }
  }

  package func pendingChanges() async throws -> CloudOutboundBatch {
    // The durable local rows and request ledger, compared with the durable accepted shadows,
    // are the change-history seam. Share imports use this same path; keep one sync driver and
    // do not add a second Share-only queue or cursor.
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    guard stored.namespaceState.phase != .blocked else {
      return CloudOutboundBatch(operations: [], zonesToSave: [])
    }
    if let payloadZone {
      try await library.reconcileCloudAttachments(
        namespaceKey: namespaceKey,
        metadataZoneName: dataZone.name,
        metadataOwnerName: dataZone.ownerName,
        payloadZoneName: payloadZone.name,
        payloadOwnerName: payloadZone.ownerName
      )
    }
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    var attachments = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
    let unsupportedAttachments = CloudAttachmentTransferCoordinator.unsupportedFiles(
      in: attachments,
      policy: attachmentPolicy
    )
    if !unsupportedAttachments.isEmpty {
      try await library.quarantineCloudAttachmentOperations(
        namespaceKey: namespaceKey,
        publicationIDs: Set(unsupportedAttachments.map(\.attachmentID)),
        cleanupIdentities: []
      )
      attachments = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
    }
    let acceptedValues = stored.readyEntities + stored.deferredEntities
    var corruptAccepted: [CloudAcceptedEntity] = []
    for value in acceptedValues {
      do {
        switch value.reference.kind {
        case .snip: _ = try Self.snipRecord(value)
        case .list: _ = try Self.listRecord(value)
        }
      } catch {
        corruptAccepted.append(value)
      }
    }
    if !corruptAccepted.isEmpty {
      try await library.quarantineCorruptCloudEntities(
        namespaceKey: namespaceKey,
        values: corruptAccepted
      )
      throw CloudSyncIssueError(.appDataIssue)
    }
    let accepted = Dictionary(uniqueKeysWithValues:
      acceptedValues.map { ($0.reference, $0) }
    )
    let snips = Dictionary(uniqueKeysWithValues: local.snips.map { ($0.id, $0) })
    let lists = Dictionary(uniqueKeysWithValues: local.lists.map { ($0.id, $0) })
    let conflicted = Set(stored.conflicts.map(\.reference))
    var eligible = stored.enrolledEntities
    if stored.namespaceState.phase == .active {
      eligible.formUnion(local.lists.map {
        CloudEntityReference(kind: .list, domainID: $0.id)
      })
      eligible.formUnion(local.snips.map {
        CloudEntityReference(kind: .snip, domainID: $0.id)
      })
    }
    let deletedListPlacements = try await library.cloudFullRecoveryEvents(
      namespaceKey: namespaceKey
    ).filter { $0.kind == .deletedListPlacement }
      .reduce(into: [UUID: Set<UUID>]()) { result, recovery in
        let decoder = JSONDecoder()
        let deletedListID = try decoder.decode(UUID.self, from: recovery.outboundData)
        for snipID in try decoder.decode([UUID].self, from: recovery.resultData) {
          result[snipID, default: []].insert(deletedListID)
        }
      }
    eligible.subtract(Set(stored.deferredEntities.compactMap { entity in
      guard entity.reference.kind == .snip,
        let deferredListID = entity.dependencyListID,
        deletedListPlacements[entity.reference.domainID]?.contains(deferredListID) == true,
        let currentListID = snips[entity.reference.domainID]?.listID,
        currentListID != deferredListID,
        currentListID == SnipList.inbox.id || stored.enrolledEntities.contains(
          CloudEntityReference(kind: .list, domainID: currentListID)
        )
      else { return entity.reference }
      return nil
    }))
    let newlyDeleted = eligible.compactMap { reference -> CloudPendingDelete? in
      guard let base = accepted[reference] else { return nil }
      let isMissing = switch reference.kind {
      case .snip: snips[reference.domainID] == nil
      case .list: lists[reference.domainID] == nil
      }
      return isMissing
        ? CloudPendingDelete(reference: reference, identity: base.identity)
        : nil
    }
    try await library.stageCloudPendingDeletes(namespaceKey: namespaceKey, values: newlyDeleted)
    var pendingDeletes = Dictionary(uniqueKeysWithValues:
      stored.pendingDeletes.map { ($0.reference, $0) }
    )
    for value in newlyDeleted {
      if let current = pendingDeletes[value.reference], current != value {
        throw CloudTransportError.invalidRecord
      }
      pendingDeletes[value.reference] = value
    }
    eligible.formUnion(pendingDeletes.keys)
    var operations: [CloudOutboundOperation] = []
    var hasEligiblePayloadSave = false
    for reference in eligible.sorted(by: Self.referenceOrder) {
      if pendingDeletes[reference] != nil {
        guard let base = accepted[reference] else { throw CloudTransportError.invalidRecord }
        operations.append(.delete(Self.recordID(base.identity), base: try Self.shadow(base)))
        continue
      }
      if conflicted.contains(reference) { continue }
      let base = accepted[reference]
      switch reference.kind {
      case .snip:
        if let snip = snips[reference.domainID] {
          if let base {
            let typed = try Self.snipRecord(base)
            if try Self.sameSnipFields(
              Self.snipFields(typed),
              Self.snipFields(snip, accepted: typed)
            ) { continue }
            operations.append(.save(try CloudFullRecordCodec.snipDraft(snip, accepted: typed)))
          } else {
            operations.append(.save(try CloudFullRecordCodec.snipDraft(snip, in: dataZone)))
          }
        } else if let base {
          operations.append(.delete(Self.recordID(base.identity), base: try Self.shadow(base)))
        }
      case .list:
        if let list = lists[reference.domainID] {
          if let base {
            let typed = try Self.listRecord(base)
            if try Self.sameListFields(
              Self.listFields(typed),
              Self.listFields(list, updatedAt: .distantPast)
            ) {
              continue
            }
            operations.append(
              .save(try CloudFullRecordCodec.listDraft(list, updatedAt: now(), accepted: typed))
            )
          } else {
            operations.append(
              .save(try CloudFullRecordCodec.listDraft(list, updatedAt: now(), in: dataZone))
            )
          }
        } else if let base {
          operations.append(.delete(Self.recordID(base.identity), base: try Self.shadow(base)))
        }
      }
    }
    if let payloadZone {
      let attachmentPlan = Self.attachmentOperations(
        attachments,
        dataZone: dataZone,
        payloadZone: payloadZone
      )
      if !attachmentPlan.invalidPublicationIDs.isEmpty
        || !attachmentPlan.invalidCleanupIdentities.isEmpty
      {
        try await library.quarantineCloudAttachmentOperations(
          namespaceKey: namespaceKey,
          publicationIDs: attachmentPlan.invalidPublicationIDs,
          cleanupIdentities: attachmentPlan.invalidCleanupIdentities
        )
      }
      operations.append(contentsOf: attachmentPlan.operations)
      hasEligiblePayloadSave = attachmentPlan.operations.contains { operation in
        guard case .save(let draft) = operation else { return false }
        return draft.recordType == CloudAttachmentRecordCodec.payloadRecordType
      }
    }
    var zonesToSave: Set<CloudZoneID> = stored.namespaceState.zoneCreationPending
      ? [dataZone] : []
    if let payloadZone, hasEligiblePayloadSave {
      zonesToSave.insert(payloadZone)
    }
    return CloudOutboundBatch(
      operations: operations.sorted { Self.operationOrder($0) < Self.operationOrder($1) },
      zonesToSave: zonesToSave
    )
  }

  private struct AttachmentOperationPlan {
    var operations: [CloudOutboundOperation] = []
    var invalidPublicationIDs: Set<UUID> = []
    var invalidCleanupIdentities: Set<CloudTextStorageIdentity> = []
  }

  private static func attachmentOperations(
    _ snapshot: CloudAttachmentStorageSnapshot,
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID
  ) -> AttachmentOperationPlan {
    let publications = snapshot.publications.sorted {
      $0.metadata.attachmentID.uuidString < $1.metadata.attachmentID.uuidString
    }
    let publicationByID = Dictionary(
      publications.map { ($0.metadata.attachmentID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var plan = AttachmentOperationPlan()
    for publication in publications where publication.isLocallyPresent
      && !publication.payloadAccepted
      && !isTerminalAttachmentFailure(publication.lastFailure)
    {
      do {
        guard publication.metadata.payloadIdentity.zoneName == payloadZone.name,
          publication.metadata.payloadIdentity.ownerName == payloadZone.ownerName
        else { throw CloudAttachmentStorageError.invalidMetadata }
        plan.operations.append(.save(try CloudAttachmentRecordCodec.payloadDraft(publication)))
      } catch {
        plan.invalidPublicationIDs.insert(publication.metadata.attachmentID)
      }
    }
    for publication in publications where publication.isLocallyPresent
      && publication.payloadAccepted
      && !publication.metadataAccepted
      && !isTerminalAttachmentFailure(publication.lastFailure)
    {
      do {
        guard publication.metadataIdentity.zoneName == dataZone.name,
          publication.metadataIdentity.ownerName == dataZone.ownerName,
          publication.metadata.payloadIdentity.zoneName == payloadZone.name,
          publication.metadata.payloadIdentity.ownerName == payloadZone.ownerName
        else { throw CloudAttachmentStorageError.invalidMetadata }
        plan.operations.append(.save(try CloudAttachmentRecordCodec.metadataDraft(publication)))
      } catch {
        plan.invalidPublicationIDs.insert(publication.metadata.attachmentID)
      }
    }
    for publication in publications where !publication.isLocallyPresent
      && publication.metadataAccepted
      && !isTerminalAttachmentFailure(publication.lastFailure)
    {
      do {
        let base = try publication.metadataShadowData.map(CloudRecordShadow.init(data:))
        plan.operations.append(.delete(
          CloudAttachmentRecordCodec.recordID(publication.metadataIdentity),
          base: base
        ))
      } catch {
        plan.invalidPublicationIDs.insert(publication.metadata.attachmentID)
      }
    }
    for cleanup in snapshot.cleanups where !isTerminalAttachmentFailure(cleanup.lastFailure) {
      if let blockedByAttachmentID = cleanup.blockedByAttachmentID,
        let replacement = publicationByID[blockedByAttachmentID],
        !replacement.metadataAccepted
      {
        continue
      }
      do {
        guard cleanup.identity.zoneName == payloadZone.name,
          cleanup.identity.ownerName == payloadZone.ownerName
        else { throw CloudAttachmentStorageError.invalidMetadata }
        let base = try cleanup.shadowData.map(CloudRecordShadow.init(data:))
        plan.operations.append(
          .delete(CloudAttachmentRecordCodec.recordID(cleanup.identity), base: base)
        )
      } catch {
        plan.invalidCleanupIdentities.insert(cleanup.identity)
      }
    }
    return plan
  }

  static func plannedAttachmentOperationIDs(
    _ snapshot: CloudAttachmentStorageSnapshot,
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID
  ) -> Set<CloudRecordID> {
    Set(attachmentOperations(snapshot, dataZone: dataZone, payloadZone: payloadZone)
      .operations.map(\.id))
  }

  private static func isTerminalAttachmentFailure(
    _ failure: CloudAttachmentFailure?
  ) -> Bool {
    failure.map { !$0.retriesAutomatically } ?? false
  }
  static func uniqueOperations(
    _ operations: [CloudOutboundOperation]
  ) throws -> [CloudRecordID: CloudOutboundOperation] {
    var result: [CloudRecordID: CloudOutboundOperation] = [:]
    for operation in operations {
      guard result.updateValue(operation, forKey: operation.id) == nil else {
        throw CloudTransportError.invalidRecord
      }
    }
    return result
  }

  static func outboundBinding(
    _ operation: CloudOutboundOperation
  ) throws -> CloudFullOutboundBinding {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return CloudFullOutboundBinding(
      identity: storageIdentity(operation.id),
      action: {
        switch operation {
        case .save: .save
        case .delete: .delete
        }
      }(),
      operationData: try encoder.encode(operation)
    )
  }

  static func malformedSentRecovery(
    sent: CloudSentBatch,
    outbound: CloudOutboundBatch,
    namespaceKey: CloudSyncNamespaceKey
  ) throws -> CloudFullRecoveryInput {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let operations = outbound.operations.sorted {
      identityOrder(storageIdentity($0.id)) < identityOrder(storageIdentity($1.id))
    }
    let results = sent.items.sorted {
      identityOrder(storageIdentity($0.id)) < identityOrder(storageIdentity($1.id))
    }
    return CloudFullRecoveryInput(
      namespaceKey: namespaceKey.rawValue,
      batchID: sent.id,
      kind: .malformedSentBatch,
      outboundData: try encoder.encode(operations),
      resultData: try encoder.encode(results)
    )
  }

  static func identityOrder(_ identity: CloudTextStorageIdentity) -> String {
    "\(identity.ownerName)|\(identity.zoneName)|\(identity.recordName)"
  }
  private static func referenceOrder(
    _ lhs: CloudEntityReference,
    _ rhs: CloudEntityReference
  ) -> Bool {
    (lhs.kind.rawValue, lhs.domainID.uuidString) < (rhs.kind.rawValue, rhs.domainID.uuidString)
  }

  private static func operationOrder(_ value: CloudOutboundOperation) -> String {
    let kind = switch value {
    case .save(let draft): draft.recordType
    case .delete(let id, _): id.name.hasPrefix("l-") ? "List" : "Snip"
    }
    return "\(kind)|\(value.id.name)"
  }
}
