import Foundation
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  func corruptShadowRecovery(in stored: CloudFullStorageSnapshot) -> CloudCorruptShadowRecovery {
    CloudCorruptShadowRecovery(stored.quarantines, dataZone: dataZone)
  }

  /// Ordinary state reads must not wait for a mutation that is paused elsewhere.
  func needsCorruptShadowRecovery() async throws -> Bool {
    let snapshot = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    return corruptShadowRecovery(in: snapshot).needsRecovery
  }

  /// Moves every unresolved archive to recovering, before a fresh engine starts, including
  /// after a crash during recovery. Rechecks the current archives under the mutation lease
  /// before saving candidates.
  func prepareCorruptShadowRecovery() async throws -> Bool {
    let snapshot = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let archives = corruptShadowRecovery(in: snapshot).unresolvedArchives
    let candidates = try archives.map { value in
      CloudCorruptShadowRecoveryCandidate(archive: value, accepted: try acceptedCorruptShadow(value))
    }
    try await library.beginCorruptCloudShadowRecovery(namespaceKey: namespaceKey, candidates: candidates)
    return !archives.isEmpty
  }

  /// A recovery row is valid only for a canonical record in this metadata zone.
  static func isValidCorruptShadowRevision(_ value: CloudStoredQuarantine, dataZone: CloudZoneID) -> Bool {
    do {
      let shadow = try CloudRecordShadow(data: value.payload)
      let snapshot = try CloudKitRecordMapper.snapshot(shadow.record())
      guard snapshot.id.zone == dataZone,
        Self.storageIdentity(snapshot.id) == value.identity
      else { return false }
      switch value.reference.kind {
      case .snip:
        let record = try CloudFullRecordCodec.snip(from: snapshot)
        _ = try Self.snipFields(record)
        return record.domainID == value.reference.domainID && record.binding == .canonical
      case .list:
        let record = try CloudFullRecordCodec.list(from: snapshot)
        _ = try Self.listFields(record)
        return record.domainID == value.reference.domainID && record.binding == .canonical
      }
    } catch {
      return false
    }
  }

  /// Moves recovering archives to resolved after a clean first fetch.
  func resolveCorruptShadowsAfterFetch(_ batch: CloudSyncBatch) async throws {
    guard Self.isCleanInitialMetadataFetch(batch, dataZone: dataZone) else { return }
    let snapshot = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    guard snapshot.namespaceState.initialFetchInventory?.canProveAbsence == true else { return }
    try await library.resolveCorruptCloudShadows(namespaceKey: namespaceKey,
      expected: corruptShadowRecovery(in: snapshot).recoveringArchives)
  }

  func recoveryFetchBatch(
    _ batch: CloudSyncBatch,
    stored: CloudFullStorageSnapshot,
    recovery: CloudCorruptShadowRecovery
  ) -> CloudSyncBatch {
    guard case .fetched(let fetched) = batch else { return batch }
    let unpreparedIDs = recovery.unpreparedRecordIDs
    // An unresolved archive without a bound base must not become a new local item.
    let applicable = fetched.items.filter { item in
      switch item {
      case .record(let value): return !unpreparedIDs.contains(value.id)
      case .deleted(let id): return !unpreparedIDs.contains(id)
      case .failed: return true
      }
    }
    let inventory = stored.namespaceState.inventory(after: CloudFullInitialFetchStep(
      batch, startsWithoutToken: false, dataZone: dataZone
    ))
    let observed = Set(fetched.items.compactMap(\.id))
      .union((inventory?.observed ?? []).map(Self.recordID))
    let absent = inventory?.canProveAbsence == true
      && Self.isCleanInitialMetadataFetch(batch, dataZone: dataZone)
      ? recovery.recoveringArchives.map { Self.recordID($0.identity) }
        .filter { !observed.contains($0) && !unpreparedIDs.contains($0) }
      : []
    return .fetched(CloudFetchedBatch(id: fetched.id,
      items: applicable + absent.map(CloudFetchItemResult.deleted),
      databaseEvents: fetched.databaseEvents, zoneEvents: fetched.zoneEvents,
      engineState: fetched.engineState, isInitialFetch: fetched.isInitialFetch))
  }

  static func isCleanInitialMetadataFetch(
    _ batch: CloudSyncBatch,
    dataZone: CloudZoneID
  ) -> Bool {
    guard case .fetched(let fetched) = batch, fetched.isInitialFetch else { return false }
    guard CloudSyncIssueError.issue(in: batch) == nil,
      !CloudSyncIssueError.blocksOutbound(in: batch)
    else { return false }
    let completedZones = Set(fetched.zoneEvents.compactMap { event -> CloudZoneID? in
      guard case .fetched(let zone) = event else { return nil }
      return zone
    })
    return fetched.engineState?.requiresInitialFetch == false && completedZones.contains(dataZone)
  }

  private func acceptedCorruptShadow(_ value: CloudStoredQuarantine) throws -> CloudAcceptedEntityInput {
    let shadow = try CloudRecordShadow(data: value.payload)
    let mapped = try CloudKitRecordMapper.snapshot(shadow.record())
    let snapshot = CloudRecordSnapshot(id: mapped.id, recordType: mapped.recordType,
      schemaVersion: mapped.schemaVersion, routingFields: mapped.routingFields,
      encryptedFields: mapped.encryptedFields, assetFields: mapped.assetFields,
      shadow: shadow, completeness: mapped.completeness)
    switch value.reference.kind {
    case .snip:
      return try CloudFullBatchPlanner.acceptedInput(CloudFullRecordCodec.snip(from: snapshot), snapshot: snapshot)
    case .list:
      return try CloudFullBatchPlanner.acceptedInput(CloudFullRecordCodec.list(from: snapshot), snapshot: snapshot)
    }
  }
}
