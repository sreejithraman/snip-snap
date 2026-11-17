import Foundation
import SnipSnapCore
import SwiftData

/// Held across actor reads and bundle publication. Store order is always UUID order.
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
  /// Current row identity and bytes, from the same locked namespace read.
  package let recoveryRows: [(id: String, eventKey: String, payload: Data)]
  /// Existing stored engine bytes and pending work, read with the accepted rows.
  package let engineState: Data?
  package let hasPendingBatches: Bool
  package let reenableReceiptDigest: Data?

  package init(snapshot: SnipLibraryTransferSnapshot, seenRequestIDs: Set<UUID>,
    storage: CloudFullStorageSnapshot, recoveryDescriptors: [Data],
    engineState: Data? = nil, hasPendingBatches: Bool = true,
    reenableReceiptDigest: Data? = nil,
    recoveryRows: [(id: String, eventKey: String, payload: Data)] = []
  ) {
    self.snapshot = snapshot
    self.seenRequestIDs = seenRequestIDs
    self.storage = storage
    self.recoveryDescriptors = recoveryDescriptors
    self.recoveryRows = recoveryRows
    self.engineState = engineState
    self.hasPendingBatches = hasPendingBatches
    self.reenableReceiptDigest = reenableReceiptDigest
  }

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
    locks: FailedEnableReadLocks,
    reenableTransitionID: UUID? = nil
  ) throws -> FailedEnableStoreRead {
    try locks.require(lockURL)
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    return try Self.failedEnableRead(context: Self.makeContext(container: container),
      revision: revision, namespace: namespace, locks: locks, lockURL: lockURL,
      reenableTransitionID: reenableTransitionID, requiresStoredMetadata: false) { attachment in
        let url = try self.attachmentURL(relativePath: attachment.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
          throw FailedEnableEvidenceError.unavailable
        }
        return try Data(contentsOf: url)
      }
  }

  /// Metadata-only acquisition/read: no lazy attachment materialization or legacy migration.
  func failedEnableReenableReceipts(namespaceKey: String, transitionID: UUID) throws
    -> (modern: Data?, ambiguous: Data?) {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let modern = try Self.failedEnableReceipt(.reenableTransition(transitionID),
      namespaceKey: namespaceKey, context: context)
    let ambiguous = try Self.failedEnableReceipt(.committedBatch(transitionID),
      namespaceKey: namespaceKey, context: context)
    guard !context.hasChanges else { throw FailedEnableEvidenceError.changed }
    try lock.check()
    return (modern, ambiguous)
  }

  func recognizesFailedEnablePrepared(_ preparation: FailedEnablePreparedRead,
    digest expected: Data, evidenceRoot: URL
  ) throws -> Bool {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    _ = try preparation.current(at: evidenceRoot)
    let key = try preparation.transfer.namespace.domain.namespaceKey.rawValue
    guard FailedEnableEncoding.hex(expected) == preparation.transfer.planDigest else {
      throw CloudFullStorageError.invalidBatchReplay
    }
    if let digest = try Self.failedEnableReceipt(.reenableTransition(preparation.transitionID),
      namespaceKey: key, context: context) {
      guard digest == expected else { throw CloudFullStorageError.invalidBatchReplay }
      return true
    }
    let ambiguous = try Self.failedEnableReceipt(.committedBatch(preparation.transitionID),
      namespaceKey: key, context: context)
    if preparation.requiresTurnOffAbsence {
      guard ambiguous == nil else { throw FailedEnableEvidenceError.changed }
      return false
    }
    guard try SwiftDataCloudFullOperationReceipts.migrateLegacyReenableReceipt(
      namespaceKey: key, transitionID: preparation.transitionID, expectedDigest: expected,
      context: context) else { return false }
    try afterMutationBeforeSave()
    _ = try preparation.current(at: evidenceRoot)
    try lock.check()
    try context.save()
    return true
  }

  func retireFailedEnablePrepared(_ preparation: FailedEnablePreparedRead,
    evidenceRoot: URL
  ) throws {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let transfer = try preparation.current(at: evidenceRoot)
    let key = try preparation.transfer.namespace.domain.namespaceKey.rawValue
    let digest = try Self.failedEnableReceipt(.reenableTransition(preparation.transitionID),
      namespaceKey: key, context: context)
    guard let digest else {
      guard try Self.failedEnableReceipt(.committedBatch(preparation.transitionID),
        namespaceKey: key, context: context) == nil else {
        throw FailedEnableEvidenceError.changed
      }
      return
    }
    guard transfer.state == .checked else { throw FailedEnableEvidenceError.changed }
    guard FailedEnableEncoding.hex(digest) == transfer.planDigest else {
      throw CloudFullStorageError.invalidBatchReplay
    }
    guard try SwiftDataCloudFullOperationReceipts.retire(
      .reenableTransition(preparation.transitionID), namespaceKey: key, context: context)
    else { throw FailedEnableEvidenceError.changed }
    try afterMutationBeforeSave()
    let finalTransfer = try preparation.current(at: evidenceRoot)
    guard finalTransfer.state == .checked, finalTransfer == transfer else {
      throw FailedEnableEvidenceError.changed
    }
    try lock.check()
    try context.save()
  }

  private static func failedEnableReceipt(_ operation: CloudFullReceiptOperation,
    namespaceKey: String, context: ModelContext
  ) throws -> Data? {
    let receipts = try context.fetch(FetchDescriptor<StoredCloudFullBatchReceipt>())
      .filter { $0.id == operation.storageKey(namespaceKey: namespaceKey) }
    guard receipts.count <= 1 else { throw FailedEnableEvidenceError.unsupported }
    guard let receipt = receipts.first else { return nil }
    guard operation.matches(receipt, namespaceKey: namespaceKey),
      receipt.batchID == operation.operationID, receipt.digest.count == 32
    else { throw FailedEnableEvidenceError.unsupported }
    return receipt.digest
  }

  /// Opens only an existing current-schema root. Saves and automatic library setup are absent.
  static func retainedFailedEnableRead(storeURL: URL, revision: UInt64,
    namespace: ICloudSyncNamespaceBinding, locks: FailedEnableReadLocks
  ) throws -> FailedEnableStoreRead {
    let lockURL = storeURL.appendingPathExtension("lock")
    try locks.require(lockURL)
    guard FileManager.default.fileExists(atPath: storeURL.path) else {
      throw FailedEnableEvidenceError.unavailable
    }
    let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
    let configuration = ModelConfiguration("SnipSnapLocal", schema: schema, url: storeURL,
      allowsSave: false, cloudKitDatabase: .none)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return try failedEnableRead(context: makeContext(container: container),
      revision: revision, namespace: namespace, locks: locks, lockURL: lockURL,
      reenableTransitionID: nil, requiresStoredMetadata: true) { _ in
        // Attachment-bearing histories need their existing byte/preservation owner.
        throw FailedEnableEvidenceError.unsupported
      }
  }

  private static func failedEnableRead(context: ModelContext, revision: UInt64,
    namespace: ICloudSyncNamespaceBinding, locks: FailedEnableReadLocks, lockURL: URL,
    reenableTransitionID: UUID?, requiresStoredMetadata: Bool,
    attachmentBytes: (SnipAttachment) throws -> Data
  ) throws -> FailedEnableStoreRead {
    try locks.require(lockURL)
    let loaded = try Self.load(context: context, seenRequestIDs: [])
    try Self.validate(loaded.state)
    guard !loaded.lists.isEmpty else { throw FailedEnableEvidenceError.unsupported }
    if requiresStoredMetadata {
      let expected = Set(loaded.snips.map {
        StoredLibraryMetadataRecord.identifier(kind: .snip, domainID: $0.id)
      } + loaded.lists.map {
        StoredLibraryMetadataRecord.identifier(kind: .list, domainID: $0.id)
      })
      guard loaded.attachments.isEmpty, loaded.references.isEmpty,
        loaded.metadata.count == expected.count,
        Set(loaded.metadata.map(\.id)) == expected else {
        throw FailedEnableEvidenceError.unsupported
      }
      for row in loaded.metadata {
        guard let kind = StoredLibraryMetadataKind(rawValue: row.kind),
          row.id == StoredLibraryMetadataRecord.identifier(kind: kind, domainID: row.domainID),
          kind != .list || row.desiredName != nil else { throw FailedEnableEvidenceError.unsupported }
      }
    }
    let snips = loaded.state.allSnips(sortMode: .manual)
    var bytes: [UUID: Data] = [:]
    for attachment in snips.flatMap(\.attachments) where bytes[attachment.id] == nil {
      bytes[attachment.id] = try attachmentBytes(attachment)
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
    guard Set(entities.map(\.reference)).count == entities.count,
      Set(entities.map(\.identity)).count == entities.count else {
      throw FailedEnableEvidenceError.unsupported
    }
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
      .filter { $0.namespaceKey == key }
    let engineStates = try context.fetch(FetchDescriptor<StoredCloudEngineState>())
      .filter { $0.namespaceKey == key }
    guard enrollment.count <= 1, engineStates.count <= 1 else {
      throw FailedEnableEvidenceError.unsupported
    }
    let state = try Self.fullEnrollmentState(from: enrollment.first?.referencesData)
    let pendingBatches = try context.fetch(FetchDescriptor<StoredCloudStagedBatch>())
      .contains { $0.namespaceKey == key }
    let deletes = try Self.cloudPendingDeletes(namespaceKey: key, context: context).map {
      guard let value = $0.value else { throw SnipLibraryError.invalidStore }
      return value
    }
    let recoveries = try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
      .filter { $0.namespaceKey == key }.sorted { $0.eventKey < $1.eventKey }
      .map { (id: $0.id, eventKey: $0.eventKey, payload: $0.payload) }
    let quarantines = try Self.quarantines(namespaceKey: key, context: context)
    let receiptDigest: Data?
    if let reenableTransitionID {
      let operation = CloudFullReceiptOperation.reenableTransition(reenableTransitionID)
      let receipts = try context.fetch(FetchDescriptor<StoredCloudFullBatchReceipt>())
        .filter { $0.id == operation.storageKey(namespaceKey: key) }
      guard receipts.count <= 1 else { throw FailedEnableEvidenceError.unsupported }
      if let receipt = receipts.first {
        guard operation.matches(receipt, namespaceKey: key),
          receipt.batchID == reenableTransitionID, receipt.digest.count == 32
        else { throw FailedEnableEvidenceError.unsupported }
        receiptDigest = receipt.digest
      } else {
        receiptDigest = nil
      }
    } else {
      receiptDigest = nil
    }
    guard !context.hasChanges else { throw FailedEnableEvidenceError.changed }
    try locks.require(lockURL)
    return FailedEnableStoreRead(snapshot: snapshot, seenRequestIDs: loaded.state.seenRequestIDs,
      storage: CloudFullStorageSnapshot(readyEntities: entities.filter { !$0.isDeferred },
        deferredEntities: entities.filter(\.isDeferred), pendingDeletes: deletes,
        conflicts: conflicts, enrolledEntities: state.references,
        quarantines: quarantines,
        namespaceState: state.namespaceState), recoveryDescriptors: recoveries.map(\.payload),
      engineState: engineStates.first?.envelopeData, hasPendingBatches: pendingBatches,
      reenableReceiptDigest: receiptDigest, recoveryRows: recoveries)
  }
}

package struct FailedEnablePreparationRead: Sendable {
  package let source: FailedEnableStoreRead
  package let candidate: FailedEnableStoreRead
  package let transition: SyncModeTransition
  package let token: SyncModeFreezeToken
  package let evidence: FailedEnableInstalledEvidence?
  package let continuityVerified: Bool
  package var retainedTurnOff: FailedEnableRetainedTurnOffRead? = nil

  package var reviewRead: FailedEnableReviewRead {
    FailedEnableReviewRead(source: source, candidate: candidate, transition: transition, evidence: evidence,
      retainedTurnOff: retainedTurnOff)
  }
}

package struct FailedEnableReviewRead: Sendable {
  package let source: FailedEnableStoreRead
  package let candidate: FailedEnableStoreRead
  package let transition: SyncModeTransition
  package let evidence: FailedEnableInstalledEvidence?
  package let retainedTurnOff: FailedEnableRetainedTurnOffRead?
  package init(source: FailedEnableStoreRead, candidate: FailedEnableStoreRead,
    transition: SyncModeTransition, evidence: FailedEnableInstalledEvidence?,
    retainedTurnOff: FailedEnableRetainedTurnOffRead? = nil) {
    self.source = source
    self.candidate = candidate
    self.transition = transition
    self.evidence = evidence
    self.retainedTurnOff = retainedTurnOff
  }
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

/// In-memory locked reads, not a stored certificate or a permit supplied by a caller.
package struct FailedEnableRetainedTurnOffRead: Sendable {
  package let store: SyncModeStore
  package let source: FailedEnableStoreRead
  package let frames: [FailedEnableInstalledEvidence]
}

/// Only the installed Cloud policy produces preparation and accepted-value decisions.
package protocol FailedEnableSemantics: Sendable {
  var reviewNamespace: ICloudSyncNamespaceBinding { get }
  func reviewDrafts(_ input: FailedEnableReviewRead) throws -> [FailedEnableReview]
  func reviewCaptureRecords(_ input: FailedEnablePreparationRead,
    reviews: [FailedEnableReview]) throws -> [FailedEnableRecord]
  func choices(for review: FailedEnableReview) throws -> [FailedEnableSetupSelection]
  func decision(for review: FailedEnableReview, selection: FailedEnableSetupSelection,
    outputIDs: [FailedEnableCopyIDs]) throws -> FailedEnableReviewDecision
  func serverFields(for reference: FailedEnableReference,
    in candidate: FailedEnableStoreRead) throws -> FailedEnableSetupLocalVersion?
  func prepare(_ input: FailedEnablePreparationRead) throws -> FailedEnablePreparedMerge
  func checkedTurnOffPayload(source: FailedEnableStoreRead) throws -> Data?
  func turnOffAbsenceCandidates(_ input: FailedEnableReviewRead) throws -> Set<FailedEnableReference>
  func needsTurnOffInventory(_ input: FailedEnableReviewRead) throws -> Bool
  func unchangedTurnOffAbsences(_ input: FailedEnableReviewRead) throws -> Set<FailedEnableReference>
  func validateTurnOffOutput(_ input: FailedEnableReviewRead, capture: FailedEnableCapture,
    applied: Bool) throws -> Set<FailedEnableReference>
  func validatePastTurnOffApply(_ input: FailedEnableReviewRead, capture: FailedEnableCapture) throws
  func validateExposure(_ input: FailedEnableReviewRead, capture: FailedEnableCapture,
    requiresAccepted: Bool) throws -> Set<FailedEnableReference>
  func observe(
    capture: FailedEnableCapture,
    candidate: FailedEnableStoreRead,
    candidateStoreID: UUID,
    namespace: ICloudSyncNamespaceBinding
  ) throws -> FailedEnableCapture
}
