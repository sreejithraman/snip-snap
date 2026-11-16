import Foundation
import SnipSnapCore
import SwiftData

/// Held across the two actor reads and bundle publication. Store order is always UUID order.
final class FailedEnableReadLocks: @unchecked Sendable {
  private let locks: [String: SnipStoreFileLock]
  init(stores: [(UUID, URL)]) throws {
    var held: [String: SnipStoreFileLock] = [:]
    for (_, url) in stores.sorted(by: { $0.0.uuidString < $1.0.uuidString }) {
      held[url.path] = try SnipStoreFileLock(url: url)
    }
    locks = held
  }
  func require(_ url: URL) throws {
    guard let lock = locks[url.path] else { throw FailedEnableEvidenceError.changed }
    try lock.check()
  }
}

package struct FailedEnableStoreRead: Sendable {
  package let snapshot: SnipLibraryTransferSnapshot
  package let seenRequestIDs: Set<UUID>
  package let storage: CloudFullStorageSnapshot
  package let recoveryDescriptors: [Data]

  package func images() throws -> [FailedEnableImage] {
    try (snapshot.snips.map {
      FailedEnableImage.snip(try FailedEnableSnipImage($0, attachmentData: snapshot.attachmentData))
    } + snapshot.lists.map { FailedEnableImage.list(FailedEnableListImage($0)) })
      .sorted { $0.reference.sortKey < $1.reference.sortKey }
  }

  package func sourceDigest(sourceID: UUID) throws -> String {
    struct Input: Encodable {
      let sourceStoreID: String
      let sourceRevision: String
      let images: [FailedEnableImage]
      let seenRequestIDs: [String]
      let dormantPayload: Data
    }
    return try FailedEnableEncoding.digest(Input(
      sourceStoreID: FailedEnableEncoding.uuid(sourceID), sourceRevision: String(snapshot.revision),
      images: images(), seenRequestIDs: seenRequestIDs.map(FailedEnableEncoding.uuid).sorted(),
      dormantPayload: snapshot.opaqueSyncStatePayload))
  }
}

extension SwiftDataSnipLibrary {
  func failedEnableRead(
    revision: UInt64,
    namespace: ICloudSyncNamespaceBinding,
    locks: FailedEnableReadLocks
  ) throws -> FailedEnableStoreRead {
    try locks.require(lockURL)
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let context = Self.makeContext(container: container)
    let loaded = try Self.load(context: context, seenRequestIDs: [])
    let snips = loaded.state.allSnips(sortMode: .manual)
    var bytes: [UUID: Data] = [:]
    for attachment in snips.flatMap(\.attachments) where bytes[attachment.id] == nil {
      let url = try attachmentURL(relativePath: attachment.relativePath)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw FailedEnableEvidenceError.unavailable
      }
      bytes[attachment.id] = try Data(contentsOf: url)
    }
    let metadata = try Self.transferMetadata(context: context)
    let snapshot = SnipLibraryTransferSnapshot(revision: revision, snips: snips,
      lists: loaded.state.allLists(), attachmentData: bytes,
      legacyManualPositions: metadata.legacyManualPositions,
      opaqueSyncStateDigest: metadata.opaqueSyncStateDigest,
      opaqueSyncStatePayload: metadata.opaqueSyncStatePayload,
      additionalSeenRequestIDs: loaded.state.seenRequestIDs)
    let key = namespace.namespaceKey.rawValue
    let entities = try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
      .filter { $0.namespaceKey == key }.map(Self.entity(from:))
    let conflicts = try context.fetch(FetchDescriptor<StoredCloudFullConflict>())
      .filter { $0.namespaceKey == key }.map { record -> CloudStoredConflict in
        let prefix = "\(key)|conflict|"
        guard let kind = CloudEntityKind(rawValue: record.kind),
          let format = CloudConflictFormat(rawValue: record.format), record.id.hasPrefix(prefix)
        else { throw SnipLibraryError.invalidStore }
        return CloudStoredConflict(key: String(record.id.dropFirst(prefix.count)),
          reference: CloudEntityReference(kind: kind, domainID: record.domainID),
          format: format, payload: record.payload)
      }
    let enrollment = try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
      .first { $0.namespaceKey == key }
    let state = try Self.fullEnrollmentState(from: enrollment?.referencesData)
    let deletes = try Self.cloudPendingDeletes(namespaceKey: key, context: context).map {
      guard let value = $0.value else { throw SnipLibraryError.invalidStore }
      return value
    }
    let recoveries = try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
      .filter { $0.namespaceKey == key }.sorted { $0.eventKey < $1.eventKey }.map(\.payload)
    try locks.require(lockURL)
    return FailedEnableStoreRead(snapshot: snapshot, seenRequestIDs: loaded.state.seenRequestIDs,
      storage: CloudFullStorageSnapshot(readyEntities: entities.filter { !$0.isDeferred },
        deferredEntities: entities.filter(\.isDeferred), pendingDeletes: deletes,
        conflicts: conflicts, enrolledEntities: state.references,
        quarantines: try Self.quarantines(namespaceKey: key, context: context),
        namespaceState: state.namespaceState), recoveryDescriptors: recoveries)
  }
}

package struct FailedEnablePreparationRead: Sendable {
  package let source: FailedEnableStoreRead
  package let candidate: FailedEnableStoreRead
  package let transition: SyncModeTransition
  package let token: SyncModeFreezeToken
  package let evidence: FailedEnableInstalledEvidence?
  package let continuityVerified: Bool
}

package struct FailedEnablePreparedMerge: Sendable {
  package let plan: CloudFullReenableApplyPlan
  package let records: [FailedEnableRecord]
  package let predecessors: [String]
  package init(plan: CloudFullReenableApplyPlan, records: [FailedEnableRecord], predecessors: [String]) {
    self.plan = plan
    self.records = records
    self.predecessors = predecessors
  }
}

/// Only the installed Cloud policy produces preparation and accepted-value decisions.
package protocol FailedEnableSemantics: Sendable {
  func prepare(_ input: FailedEnablePreparationRead) throws -> FailedEnablePreparedMerge
  func checkedTurnOffPayload(source: FailedEnableStoreRead) throws -> Data?
  func validateExposure(capture: FailedEnableCapture, candidate: FailedEnableStoreRead) throws
  func observe(
    capture: FailedEnableCapture,
    candidate: FailedEnableStoreRead,
    candidateStoreID: UUID,
    namespace: ICloudSyncNamespaceBinding
  ) throws -> FailedEnableCapture
}
