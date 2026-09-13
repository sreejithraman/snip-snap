import Foundation
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  /// Ordinary state reads must not wait for a mutation that is paused elsewhere.
  func needsCorruptShadowRecovery() async throws -> Bool {
    let snapshot = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    return !unresolvedCorruptShadows(snapshot.quarantines).isEmpty
  }

  /// Runs before a fresh engine starts, including after a crash during recovery.
  /// Rechecks the current archives under the mutation lease before saving candidates.
  func prepareCorruptShadowRecovery() async throws -> Bool {
    let snapshot = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let archives = unresolvedCorruptShadows(snapshot.quarantines)
    let candidates = try archives.map { value in
      CloudCorruptShadowRecoveryCandidate(archive: value, accepted: try acceptedCorruptShadow(value))
    }
    try await library.beginCorruptCloudShadowRecovery(namespaceKey: namespaceKey, candidates: candidates)
    return !archives.isEmpty
  }

  func hasUnresolvedQuarantines(_ values: [CloudStoredQuarantine]) -> Bool {
    let keys = Set(values.map(\.key))
    return values.contains {
      !isValidCorruptShadow($0, resolved: true)
        || keys.contains(String($0.key.dropFirst("resolved-".count)))
    }
  }

  func unresolvedCorruptShadows(_ values: [CloudStoredQuarantine]) -> [CloudStoredQuarantine] {
    values.filter { isValidCorruptShadow($0) }
  }

  /// A recovery mark is valid only for a canonical record in this metadata zone.
  func isValidCorruptShadow(_ value: CloudStoredQuarantine, resolved: Bool = false) -> Bool {
    let archiveKey = CloudStoredQuarantine.corruptShadowKey(reference: value.reference, payload: value.payload)
    guard value.format == .legacyBindingV1,
      value.key == (resolved ? "resolved-\(archiveKey)" : archiveKey)
    else { return false }
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

  func resolveCorruptShadowsAfterFetch(_ batch: CloudSyncBatch) async throws {
    guard isCleanInitialMetadataFetch(batch) else { return }
    let snapshot = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    try await library.resolveCorruptCloudShadows(namespaceKey: namespaceKey,
      expected: matchingRecoveryArchives(snapshot.quarantines))
  }

  func recoveryFetchBatch(_ batch: CloudSyncBatch, stored: CloudFullStorageSnapshot) -> CloudSyncBatch {
    guard case .fetched(let fetched) = batch else { return batch }
    let prepared = matchingRecoveryArchives(stored.quarantines)
    let preparedKeys = Set(prepared.map(\.key))
    let unpreparedIDs = Set(unresolvedCorruptShadows(stored.quarantines)
      .filter { !preparedKeys.contains($0.key) }.map { Self.recordID($0.identity) })
    // An unresolved archive without a bound base must not become a new local item.
    let applicable = fetched.items.filter { item in
      switch item {
      case .record(let value): return !unpreparedIDs.contains(value.id)
      case .deleted(let id): return !unpreparedIDs.contains(id)
      case .failed: return true
      }
    }
    let observed = Set(fetched.items.compactMap(\.id))
    let absent = isCleanInitialMetadataFetch(batch)
      ? prepared.map { Self.recordID($0.identity) }
        .filter { !observed.contains($0) && !unpreparedIDs.contains($0) }
      : []
    return .fetched(CloudFetchedBatch(id: fetched.id,
      items: applicable + absent.map(CloudFetchItemResult.deleted),
      databaseEvents: fetched.databaseEvents, zoneEvents: fetched.zoneEvents,
      engineState: fetched.engineState, isInitialFetch: fetched.isInitialFetch))
  }

  private func isCleanInitialMetadataFetch(_ batch: CloudSyncBatch) -> Bool {
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

  private func matchingRecoveryArchives(_ values: [CloudStoredQuarantine]) -> [CloudStoredQuarantine] {
    let byKey = Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0) })
    return unresolvedCorruptShadows(values).filter { archive in
      let expected = archive.corruptShadowRecoveryMarker
      guard let attempt = byKey[expected.key] else { return false }
      return attempt.reference == expected.reference && attempt.identity == expected.identity
        && attempt.format == expected.format && attempt.payload == expected.payload
    }
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
