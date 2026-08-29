import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  package func pendingChanges() async throws -> CloudOutboundBatch {
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
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
    return CloudOutboundBatch(
      operations: operations.sorted { Self.operationOrder($0) < Self.operationOrder($1) },
      zonesToSave: stored.namespaceState.zoneCreationPending ? [dataZone] : []
    )
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
