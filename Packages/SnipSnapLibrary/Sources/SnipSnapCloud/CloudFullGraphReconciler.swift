import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// Plans confirmed missing-list repairs and retains checked placements until acknowledgement.
struct CloudFullGraphReconciler {
  static func repairs(
    completeInventory: Set<CloudTextStorageIdentity>?,
    dataZone: CloudZoneID,
    accepted: [CloudEntityReference: CloudAcceptedEntityInput],
    priorRepairs: [CloudEntityReference: CloudFullGraphRepair],
    items: [CloudFullBatchItem],
    quarantines: [CloudStoredQuarantine],
    local: SnipLibrarySnapshot
  ) -> [CloudFullGraphRepair] {
    let inventory = completeInventory ?? []

    var observedLists: Set<UUID> = [SnipList.inbox.id]
    observedLists.formUnion(accepted.values.compactMap { value in
      value.reference.kind == .list && inventory.contains(value.identity)
        ? value.reference.domainID : nil
    })
    // Binding/decoding problems do not make a positively fetched list absent.
    // Earlier quarantined records retain their routed domain ID in the archive.
    observedLists.formUnion(quarantines.compactMap { value in
      value.reference.kind == .list && inventory.contains(value.identity)
        ? value.reference.domainID : nil
    })
    observedLists.formUnion(items.compactMap { item in
      item.accepted.reference.kind == .list && item.acceptedAction == .quarantine
        ? item.accepted.reference.domainID : nil
    })
    let removedLists = Set(items.compactMap { item in
      item.acceptedAction == .remove && item.accepted.reference.kind == .list
        && item.localMutation != .none
        ? item.accepted.reference.domainID : nil
    })
    let survivingLocalLists = Set(local.lists.map(\.id)).subtracting(removedLists)
    let validReplacementLists = observedLists.union(survivingLocalLists)
    let currentPlacements = Dictionary(uniqueKeysWithValues: local.snips.map { ($0.id, $0.listID) })
    var plannedSnips: Set<UUID> = []
    return items.compactMap { item in
      let reference = item.accepted.reference
      guard item.acceptedAction == .upsert,
        reference.kind == .snip,
        plannedSnips.insert(reference.domainID).inserted,
        let value = accepted[reference],
        let missingListID = value.dependencyListID,
        missingListID != SnipList.inbox.id,
        case .upsertSnip(let proposed) = item.localMutation
      else { return nil }
      let priorRepair = priorRepairs[reference]
      let retainsCheckedPlacement = priorRepair?.snipID == reference.domainID
        && priorRepair?.missingListID == missingListID
        && currentPlacements[reference.domainID].map {
          $0 != missingListID && ($0 == SnipList.inbox.id || survivingLocalLists.contains($0))
        } == true
      // Incremental updates can preserve an already checked local placement, but
      // cannot infer absence or create a new fallback for another dependency.
      let confirmsAbsence = completeInventory != nil && !observedLists.contains(missingListID)
        && !inventory.contains(CloudFullSyncPersistence.storageIdentity(.list(missingListID, in: dataZone)))
      let dependencyIsReady = accepted[CloudEntityReference(kind: .list, domainID: missingListID)] != nil
      guard confirmsAbsence || (retainsCheckedPlacement && !dependencyIsReady) else { return nil }
      let replacementListID: UUID
      if let currentListID = currentPlacements[reference.domainID],
        currentListID != missingListID,
        currentListID == SnipList.inbox.id || survivingLocalLists.contains(currentListID)
      {
        replacementListID = currentListID
      } else if proposed.listID == missingListID {
        replacementListID = SnipList.inbox.id
      } else if validReplacementLists.contains(proposed.listID) {
        replacementListID = proposed.listID
      } else {
        return nil
      }
      return CloudFullGraphRepair(
        snipID: reference.domainID,
        missingListID: missingListID,
        replacementListID: replacementListID
      )
    }
    .sorted { $0.snipID.uuidString < $1.snipID.uuidString }
  }
}
