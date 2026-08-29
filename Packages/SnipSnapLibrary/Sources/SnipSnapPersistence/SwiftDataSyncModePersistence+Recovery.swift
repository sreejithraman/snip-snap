import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  static func recover(_ value: inout Manifest, rootURL: URL) throws {
    let storeRoots = try validatedStoreRoots(value.stores, rootURL: rootURL)
    // The revision advances before the store write starts. A leftover reservation means the
    // write may or may not have reached SwiftData, so keep that revision and reopen writes.
    value.writeReservation = nil
    if let isolation = value.accountIsolation,
      value.activeStoreID == isolation.storeID,
      let sourceIndex = value.stores.firstIndex(where: { $0.id == isolation.storeID }),
      let replacementIndex = value.stores.firstIndex(where: {
        $0.id == isolation.replacementStoreID
      })
    {
      guard let replacementRoot = storeRoots[isolation.replacementStoreID] else {
        throw SyncModePersistenceError.invalidManifest
      }
      _ = try SwiftDataSnipLibrary(
        storeURL: replacementRoot.appendingPathComponent("snips.store")
      )
      value.stores[replacementIndex].lifecycle = .ready
      value.stores[sourceIndex].lifecycle = .isolated
      value.activeStoreID = isolation.replacementStoreID
    }
    if let activeIndex = value.stores.firstIndex(where: { $0.id == value.activeStoreID }),
      value.stores[activeIndex].lifecycle == .creating
    {
      guard let root = storeRoots[value.stores[activeIndex].id] else {
        throw SyncModePersistenceError.invalidManifest
      }
      _ = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("snips.store"))
      value.stores[activeIndex].lifecycle = .ready
    }
    let removable = value.stores.filter {
      $0.id != value.activeStoreID && ($0.lifecycle == .creating || $0.lifecycle == .deleting)
    }.prefix(2)
    for store in removable {
      guard let storeRoot = storeRoots[store.id] else {
        throw SyncModePersistenceError.invalidManifest
      }
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
      if transition.phase == .sourceFrozen,
        transition.mergeIntent?.fullReenablePlanID != nil
      {
        value.transition = transition
        return
      }
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

  static func validatedStoreRoots(
    _ stores: [SyncModeStore],
    rootURL: URL
  ) throws -> [UUID: URL] {
    guard rootURL.isFileURL, Set(stores.map(\.id)).count == stores.count else {
      throw SyncModePersistenceError.invalidManifest
    }
    let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let rootComponents = resolvedRoot.pathComponents
    var roots: [UUID: URL] = [:]
    for store in stores {
      guard store.relativeRoot == canonicalRelativeRoot(for: store) else {
        throw SyncModePersistenceError.invalidManifest
      }
      let resolvedStore = rootURL
        .appendingPathComponent(store.relativeRoot, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
      let storeComponents = resolvedStore.pathComponents
      guard storeComponents.count > rootComponents.count,
        Array(storeComponents.prefix(rootComponents.count)) == rootComponents
      else { throw SyncModePersistenceError.invalidManifest }
      roots[store.id] = resolvedStore
    }
    return roots
  }

  static func canonicalRelativeRoot(for store: SyncModeStore) -> String {
    "stores/\(store.kind.rawValue)-\(store.id.uuidString.lowercased())"
  }

  static func absorbMergeIntent(_ transition: inout SyncModeTransition) {
    guard let intent = transition.mergeIntent else { return }
    transition.seedProvenance = intent.seedProvenance
    transition.seededListIDs = intent.seededListIDs
    transition.supersededApprovedSnipIDs.formUnion(intent.approvedSnipIDs)
    transition.pendingSettlementSnipIDs = []
    transition.sendAttempt = nil
    transition.mergeIntent = nil
  }

  static func validate(_ value: Manifest) throws {
    guard value.version == 2,
      let active = value.stores.first(where: { $0.id == value.activeStoreID }),
      active.lifecycle == .ready || active.lifecycle == .retired,
      Set(value.stores.map(\.id)).count == value.stores.count
    else { throw SyncModePersistenceError.invalidManifest }
    for store in value.stores {
      guard (store.kind == .iCloudSync) == (store.namespace != nil),
        (store.kind == .localOnly || store.quarantinedNamespace == nil),
        store.relativeRoot == canonicalRelativeRoot(for: store)
      else { throw SyncModePersistenceError.invalidManifest }
    }
    if let reservation = value.writeReservation {
      guard let store = value.stores.first(where: { $0.id == reservation.storeID }),
        store.id == value.activeStoreID,
        store.revision == reservation.reservedRevision
      else { throw SyncModePersistenceError.invalidManifest }
    }
    if let transition = value.transition {
      guard let source = value.stores.first(where: { $0.id == transition.sourceStoreID }),
        let candidate = value.stores.first(where: { $0.id == transition.candidateStoreID }),
        candidate.kind == transition.targetKind,
        candidate.namespace == transition.namespace,
        transition.syncProtocol == candidate.syncProtocol,
        (transition.targetKind == .iCloudSync) == (transition.namespace != nil)
      else { throw SyncModePersistenceError.invalidManifest }
      if transition.targetKind == .localOnly {
        guard source.kind == .iCloudSync,
          source.syncProtocol == transition.syncProtocol,
          candidate.syncProtocol == source.syncProtocol
        else { throw SyncModePersistenceError.invalidManifest }
      }
      let provenance = transition.seedProvenance + (transition.mergeIntent?.seedProvenance ?? [])
      guard provenance.allSatisfy({ $0.digestVersion == 1 || $0.digestVersion == 2 }) else {
        throw SyncModePersistenceError.invalidManifest
      }
      if let intent = transition.mergeIntent {
        guard transition.phase == .sourceFrozen,
          transition.freezeSnapshotTaken,
          transition.freezeToken?.revision == intent.sourceRevision,
          intent.planDigest.count == 32,
          intent.approvedSnipIDs.isSubset(of: Set(intent.seedProvenance.map(\.candidateSnipID))),
          (intent.fullReenablePlanID.map { $0 == transition.id } ?? true)
        else { throw SyncModePersistenceError.invalidManifest }
      }
      if let attempt = transition.sendAttempt {
        let operationIDs = Set(attempt.operations.compactMap {
          $0.reference?.kind == .snip ? $0.reference?.domainID : nil
        })
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
    if let isolation = value.accountIsolation {
      guard value.transition == nil,
        let source = value.stores.first(where: { $0.id == isolation.storeID }),
        let replacement = value.stores.first(where: {
          $0.id == isolation.replacementStoreID
        }),
        source.kind == .iCloudSync,
        source.namespace == isolation.namespace,
        replacement.kind == .localOnly,
        replacement.namespace == nil
      else { throw SyncModePersistenceError.invalidManifest }
      let declared = value.activeStoreID == source.id
        && source.lifecycle == .ready
        && replacement.lifecycle == .creating
      let isolated = value.activeStoreID == replacement.id
        && source.lifecycle == .isolated
        && replacement.lifecycle == .ready
      guard declared || isolated else { throw SyncModePersistenceError.invalidManifest }
    } else if value.stores.contains(where: { $0.lifecycle == .isolated }) {
      throw SyncModePersistenceError.invalidManifest
    }
  }

  static func write(
    _ manifest: Manifest,
    to url: URL,
    using writer: ManifestWriter
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try writer(encoder.encode(manifest), url)
  }
}
