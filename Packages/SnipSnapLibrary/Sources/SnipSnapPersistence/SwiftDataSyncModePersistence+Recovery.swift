import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  static func recover(
    _ value: inout Manifest,
    rootURL: URL,
    attachmentCacheRootURL: URL? = nil
  ) throws {
    let storeRoots = try validatedStoreRoots(value.stores, rootURL: rootURL)
    if let transition = value.transition {
      try validateTransition(transition, in: value)
      if value.activeStoreID == transition.sourceStoreID,
        let candidateIndex = value.stores.firstIndex(where: { $0.id == transition.candidateStoreID })
      {
        value.stores[candidateIndex].lifecycle = .deleting
      } else if let root = storeRoots[transition.candidateStoreID],
        FileManager.default.fileExists(atPath: root.appendingPathComponent("snips.store").path),
        let sourceIndex = value.stores.firstIndex(where: { $0.id == transition.sourceStoreID }),
        value.stores[sourceIndex].lifecycle == .retired
      {
        value.stores[sourceIndex].lifecycle = .deleting
      }
      value.transition = nil
    }
    try recoverInterruptedReset(&value, rootURL: rootURL, storeRoots: storeRoots)
    try recoverLegacyAccountCopy(&value, storeRoots: storeRoots)
    if let activeIndex = value.stores.firstIndex(where: { $0.id == value.activeStoreID }),
      value.stores[activeIndex].lifecycle == .creating
    {
      guard let root = storeRoots[value.stores[activeIndex].id] else {
        throw SyncModePersistenceError.invalidManifest
      }
      _ = try SwiftDataSnipLibrary(
        storeURL: root.appendingPathComponent("snips.store"),
        attachmentCacheRootURL: cacheRootURL(
          base: attachmentCacheRootURL,
          storeID: value.stores[activeIndex].id
        )
      )
      value.stores[activeIndex].lifecycle = .ready
    }
    if let active = value.stores.first(where: { $0.id == value.activeStoreID }),
      let root = storeRoots[active.id]
    {
      try SwiftDataSnipLibrary.StoreRetirementMarkers(
        storeURL: root.appendingPathComponent("snips.store", isDirectory: false)
      ).restore()
    }
    let removable = value.stores.filter {
      $0.id != value.activeStoreID && ($0.lifecycle == .creating || $0.lifecycle == .deleting)
    }.prefix(2)
    for store in removable {
      guard let storeRoot = storeRoots[store.id] else {
        throw SyncModePersistenceError.invalidManifest
      }
      do {
        if let cacheRoot = cacheRootURL(base: attachmentCacheRootURL, storeID: store.id),
          FileManager.default.fileExists(atPath: cacheRoot.path)
        {
          try CloudAttachmentCacheFiles.removeCacheContainer(cacheRoot)
        }
        if FileManager.default.fileExists(atPath: storeRoot.path) {
          try FileManager.default.removeItem(at: storeRoot)
        }
        value.stores.removeAll { $0.id == store.id }
      } catch {
        if value.attentionReason != .namespaceChanged { value.attentionReason = .storageFailure }
      }
    }
    for index in value.stores.indices where value.stores[index].syncProtocol == .retiredText {
      let store = value.stores[index]
      if store.id == value.activeStoreID, let namespace = store.namespace ?? store.quarantinedNamespace,
        let root = storeRoots[store.id]
      {
        _ = try SwiftDataSnipLibrary(
          storeURL: root.appendingPathComponent("snips.store"),
          attachmentCacheRootURL: cacheRootURL(base: attachmentCacheRootURL, storeID: store.id),
          resetRetiredTextNamespace: namespace.namespaceKey
        )
      }
      value.stores[index].syncProtocol = .fullRecordV1
    }
  }

  /// Reads the reset marker written by pre-#122 builds. A newer interrupted
  /// purge can instead leave the source marked read-only and deleting.
  private struct LegacyCollectionState: Decodable {
    struct Reset: Decodable {
      struct Namespace: Decodable {
        let cloudScope: String
        let accountLineage: String
        let generation: UUID
        let zones: Set<ICloudSyncZoneBinding>

        var binding: ICloudSyncNamespaceBinding {
          ICloudSyncNamespaceBinding(
            scope: cloudScope, accountLineage: accountLineage, generation: generation, zones: zones
          )
        }
      }
      let priorNamespace: Namespace
      let recoveryStoreID: UUID?
    }
    let encryptedDataReset: Reset?
  }

  static func clearLegacyCloudReset(
    at rootURL: URL, matching namespace: ICloudSyncNamespaceBinding, storeID: UUID
  ) throws {
    let url = rootURL.appendingPathComponent("cloud-collection-state.json")
    guard let data = try? Data(contentsOf: url),
      let reset = try? JSONDecoder().decode(LegacyCollectionState.self, from: data).encryptedDataReset,
      reset.priorNamespace.binding == namespace,
      reset.recoveryStoreID == nil || reset.recoveryStoreID == storeID,
      var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    fields.removeValue(forKey: "encryptedDataReset")
    try DurableFile.write(JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), to: url)
  }

  private static func recoverInterruptedReset(
    _ manifest: inout Manifest, rootURL: URL, storeRoots: [UUID: URL]
  ) throws {
    guard let active = manifest.stores.first(where: { $0.id == manifest.activeStoreID }),
      manifest.accountIsolation == nil
    else { return }
    let stateURL = rootURL.appendingPathComponent("cloud-collection-state.json")
    let reset = (try? JSONDecoder().decode(LegacyCollectionState.self,
      from: Data(contentsOf: stateURL)))?.encryptedDataReset
    if let reset, active.namespace == reset.priorNamespace.binding,
      reset.recoveryStoreID == nil || reset.recoveryStoreID == active.id
    {
      manifest.attentionReason = .namespaceChanged
      return
    }
    guard active.kind == .localOnly, active.quarantinedNamespace == nil else { return }
    for index in manifest.stores.indices.reversed() {
      let store = manifest.stores[index]
      guard let namespace = store.namespace, let root = storeRoots[store.id],
        store.lifecycle == .recovery || store.lifecycle == .deleting
      else { continue }
      let file = root.appendingPathComponent("snips.store")
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      let hasLegacyMarker = reset?.priorNamespace.binding == namespace
        && (reset?.recoveryStoreID == nil || reset?.recoveryStoreID == store.id)
      // The previous purge swap marked its source read-only before selecting an
      // empty local store. Ordinary mode transitions never wrote that marker.
      let interruptedPurge = store.lifecycle == .deleting
        && SwiftDataSnipLibrary.StoreRetirementMarkers(storeURL: file).phase != .writable
      guard hasLegacyMarker || interruptedPurge else { continue }
      manifest.accountIsolation = LegacyAccountCopy(id: store.id, storeID: store.id,
        replacementStoreID: active.id)
      manifest.attentionReason = .namespaceChanged
      return
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
    let cloudRoot = canonicalRelativeRoot(kind: .iCloudSync, id: store.id)
    if store.quarantinedNamespace != nil, store.relativeRoot == cloudRoot { return cloudRoot }
    return canonicalRelativeRoot(kind: store.kind, id: store.id)
  }

  static func canonicalRelativeRoot(kind: SyncModeStoreKind, id: UUID) -> String {
    "stores/\(kind.rawValue)-\(id.uuidString.lowercased())"
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
    if let transition = value.transition {
      try validateTransition(transition, in: value)
    }
  }

  private static func validateTransition(_ transition: SyncModeTransition, in value: Manifest) throws {
    guard transition.sourceStoreID != transition.candidateStoreID,
      transition.sourceStoreID == value.activeStoreID || transition.candidateStoreID == value.activeStoreID,
      let source = value.stores.first(where: { $0.id == transition.sourceStoreID }),
      let candidate = value.stores.first(where: { $0.id == transition.candidateStoreID }),
      candidate.kind == transition.targetKind, candidate.namespace == transition.namespace,
      candidate.syncProtocol == transition.syncProtocol
    else { throw SyncModePersistenceError.invalidManifest }
    if transition.targetKind == .localOnly {
      guard source.kind == .iCloudSync, source.syncProtocol == candidate.syncProtocol else {
        throw SyncModePersistenceError.invalidManifest
      }
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
