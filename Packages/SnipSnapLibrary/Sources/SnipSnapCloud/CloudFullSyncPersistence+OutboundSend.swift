import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  package func pendingChanges() async throws -> CloudOutboundBatch {
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
    let attachments = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
    let accepted = Dictionary(uniqueKeysWithValues:
      (stored.readyEntities + stored.deferredEntities).map { ($0.reference, $0) }
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
    eligible.subtract(Set(stored.deferredEntities.map(\.reference)))
    var operations: [CloudOutboundOperation] = []
    for reference in eligible.sorted(by: Self.referenceOrder) {
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
      let attachmentOperations = try Self.attachmentOperations(
        attachments,
        dataZone: dataZone,
        payloadZone: payloadZone
      )
      operations.append(contentsOf: attachmentOperations)
    }
    var zonesToSave: Set<CloudZoneID> = stored.namespaceState.zoneCreationPending
      ? [dataZone] : []
    if let payloadZone, attachments.publications.contains(where: { $0.isLocallyPresent }) {
      zonesToSave.insert(payloadZone)
    }
    return CloudOutboundBatch(
      operations: operations.sorted { Self.operationOrder($0) < Self.operationOrder($1) },
      zonesToSave: zonesToSave
    )
  }

  private static func attachmentOperations(
    _ snapshot: CloudAttachmentStorageSnapshot,
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID
  ) throws -> [CloudOutboundOperation] {
    let publications = snapshot.publications.sorted {
      $0.metadata.attachmentID.uuidString < $1.metadata.attachmentID.uuidString
    }
    let payloads = try publications.compactMap { publication -> CloudOutboundOperation? in
      guard publication.isLocallyPresent, !publication.payloadAccepted else { return nil }
      if publication.lastFailure == .rejected || publication.lastFailure == .invalidRecord
        || publication.lastFailure == .zoneMissing
      { return nil }
      guard publication.metadata.payloadIdentity.zoneName == payloadZone.name,
        publication.metadata.payloadIdentity.ownerName == payloadZone.ownerName
      else { throw CloudAttachmentStorageError.invalidMetadata }
      return .save(try CloudAttachmentRecordCodec.payloadDraft(publication))
    }
    if !payloads.isEmpty { return payloads }
    let metadata = try publications.compactMap { publication -> CloudOutboundOperation? in
      guard publication.isLocallyPresent, publication.payloadAccepted,
        !publication.metadataAccepted
      else { return nil }
      guard publication.metadataIdentity.zoneName == dataZone.name,
        publication.metadataIdentity.ownerName == dataZone.ownerName,
        publication.metadata.payloadIdentity.zoneName == payloadZone.name,
        publication.metadata.payloadIdentity.ownerName == payloadZone.ownerName
      else { throw CloudAttachmentStorageError.invalidMetadata }
      return .save(CloudAttachmentRecordCodec.metadataDraft(publication))
    }
    if !metadata.isEmpty { return metadata }
    var metadataDeletions: [CloudOutboundOperation] = []
    for publication in publications where !publication.isLocallyPresent
      && publication.metadataAccepted
    {
      let base = try publication.metadataShadowData.map(CloudRecordShadow.init(data:))
      metadataDeletions.append(.delete(
        CloudAttachmentRecordCodec.recordID(publication.metadataIdentity),
        base: base
      ))
    }
    if !metadataDeletions.isEmpty { return metadataDeletions }
    var cleanupDeletions: [CloudOutboundOperation] = []
    for cleanup in snapshot.cleanups {
      guard cleanup.identity.zoneName == payloadZone.name,
        cleanup.identity.ownerName == payloadZone.ownerName
      else { throw CloudAttachmentStorageError.invalidMetadata }
      let base = try cleanup.shadowData.map(CloudRecordShadow.init(data:))
      cleanupDeletions.append(
        .delete(CloudAttachmentRecordCodec.recordID(cleanup.identity), base: base)
      )
    }
    return cleanupDeletions
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
    namespaceKey: String
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
      namespaceKey: namespaceKey,
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
