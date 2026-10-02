import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData

struct CloudFullReenableCommitProof: Sendable {
  let namespaceKey: CloudSyncNamespaceKey
  let transitionID: UUID
  let digest: Data
}

extension SwiftDataSnipLibrary {
  public func transferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot {
    let current = try checkedSnapshot(sortedBy: .manual)
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let attachmentData = try readTransferAttachments(in: current.snips, lock: lock) {
      try Data(contentsOf: $0)
    }
    let transferMetadata = try Self.transferMetadata(context: context)
    return SnipLibraryTransferSnapshot(
      revision: revision,
      snips: current.snips,
      lists: current.lists,
      attachmentData: attachmentData,
      legacyManualPositions: transferMetadata.legacyManualPositions,
      opaqueSyncStateDigest: transferMetadata.opaqueSyncStateDigest,
      opaqueSyncStatePayload: transferMetadata.opaqueSyncStatePayload
    )
  }

  public func previewTransferSnapshot(
    revision: UInt64
  ) async throws -> SnipLibraryTransferSnapshot {
    let current = try checkedSnapshot(sortedBy: .manual)
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let files = try readTransferAttachments(in: current.snips, lock: lock) {
      (url: $0, digest: try AttachmentFileIO.digest(at: $0))
    }
    let transferMetadata = try Self.transferMetadata(context: context)
    return SnipLibraryTransferSnapshot(
      revision: revision,
      snips: current.snips,
      lists: current.lists,
      attachmentData: [:],
      attachmentFileURLs: files.mapValues(\.url),
      attachmentFileDigests: files.mapValues(\.digest),
      legacyManualPositions: transferMetadata.legacyManualPositions,
      opaqueSyncStateDigest: transferMetadata.opaqueSyncStateDigest,
      opaqueSyncStatePayload: transferMetadata.opaqueSyncStatePayload
    )
  }

  public func mergeTransferSnapshot(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID,
    expectedTargetDigest: Data?
  ) async throws -> SnipLibraryTransferResult {
    let plan = try await prepareTransferPlan(
      source,
      transitionID: transitionID,
      replacingTargetSnipIDs: [],
      priorSeedProvenance: [],
      priorServerAcceptedSnipIDs: [],
      priorSeededListIDs: []
    )
    if let expectedTargetDigest, plan.targetDigest != expectedTargetDigest {
      throw SnipLibraryError.importChanged
    }
    do {
      return try await applyTransferPlan(plan)
    } catch SnipLibraryError.invalidStore where expectedTargetDigest != nil {
      throw SnipLibraryError.importChanged
    }
  }

  package func mergeTransferSnapshot(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID,
    replacingTargetSnipIDs: Set<UUID>,
    priorSeedProvenance: [SyncModeSeedProvenance],
    priorServerAcceptedSnipIDs: Set<UUID>,
    priorSeededListIDs: Set<UUID>
  ) async throws -> SnipLibraryTransferResult {
    let plan = try await prepareTransferPlan(
      source,
      transitionID: transitionID,
      replacingTargetSnipIDs: replacingTargetSnipIDs,
      priorSeedProvenance: priorSeedProvenance,
      priorServerAcceptedSnipIDs: priorServerAcceptedSnipIDs,
      priorSeededListIDs: priorSeededListIDs
    )
    return try await applyTransferPlan(plan)
  }

  package func prepareTransferPlan(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID,
    replacingTargetSnipIDs: Set<UUID>,
    priorSeedProvenance: [SyncModeSeedProvenance],
    priorServerAcceptedSnipIDs: Set<UUID>,
    priorSeededListIDs: Set<UUID>,
    targetRevision: UInt64 = 0,
    targetSnapshot: SnipLibraryTransferSnapshot? = nil
  ) async throws -> SnipLibraryTransferPlan {
    guard isAvailable else { throw SnipLibraryError.storeUnavailable }
    let target: SnipLibraryTransferSnapshot
    if let targetSnapshot {
      target = targetSnapshot
    } else {
      target = try await transferSnapshot(revision: targetRevision)
    }
    let acceptedTargetTextBySnipID = try acceptedCloudTextValues()
    let acceptedTargetSnipIDs = Set(acceptedTargetTextBySnipID.keys)
    return try SnipLibraryTransferPlanner.plan(
      source: source,
      target: target,
      transitionID: transitionID,
      replacingTargetSnipIDs: replacingTargetSnipIDs,
      acceptedTargetSnipIDs: acceptedTargetSnipIDs,
      acceptedTargetTextBySnipID: acceptedTargetTextBySnipID,
      priorSeedProvenance: priorSeedProvenance,
      priorServerAcceptedSnipIDs: priorServerAcceptedSnipIDs,
      priorSeededListIDs: priorSeededListIDs
    )
  }

  package func applyTransferPlan(
    _ plan: SnipLibraryTransferPlan,
    currentRevision: UInt64 = 0
  ) async throws -> SnipLibraryTransferResult {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    try requireContentWritesAllowed(context: context)
    let loaded = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
    let currentSnips = loaded.state.allSnips(sortMode: .manual)
    let currentAttachmentData = try readTransferAttachments(in: currentSnips, lock: lock) {
      try Data(contentsOf: $0)
    }
    let transferMetadata = try Self.transferMetadata(context: context)
    let current = SnipLibraryTransferSnapshot(
      revision: currentRevision,
      snips: currentSnips,
      lists: loaded.state.allLists(),
      attachmentData: currentAttachmentData,
      legacyManualPositions: transferMetadata.legacyManualPositions,
      opaqueSyncStateDigest: transferMetadata.opaqueSyncStateDigest,
      opaqueSyncStatePayload: transferMetadata.opaqueSyncStatePayload
    )
    guard currentRevision == plan.targetRevision,
      SnipLibraryTransferPlanner.digest(snapshot: current) == plan.targetDigest
    else { throw SnipLibraryError.invalidStore }
    var createdDirectories: [URL] = []
    var transferredSnips = plan.snips
    let currentAttachments = Dictionary(
      currentSnips.flatMap(\.attachments).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    do {
      for snipIndex in transferredSnips.indices {
        try lock.check()
        for attachmentIndex in transferredSnips[snipIndex].attachments.indices {
          try lock.check()
          var attachment = transferredSnips[snipIndex].attachments[attachmentIndex]
          // Retained remote metadata already names its validated cache location.
          // An unrelated transfer must not promote or require its evictable bytes.
          if attachment.relativePath.hasPrefix("CloudDownloads/"),
            currentAttachments[attachment.id] == attachment
          { continue }
          let safeName = URL(fileURLWithPath: attachment.fileName).lastPathComponent
          guard !safeName.isEmpty else { throw SnipLibraryError.attachmentCopyFailed }
          let relativePath = "\(attachment.id.uuidString)/\(safeName)"
          let destination = attachmentRootURL.appendingPathComponent(relativePath)
          let directory = destination.deletingLastPathComponent()
          if !FileManager.default.fileExists(atPath: destination.path) {
            try DurableFile.createDirectory(directory)
            createdDirectories.append(directory)
            if let bytes = plan.attachmentData[attachment.id] {
              try DurableFile.write(bytes, to: destination)
            } else if let sourceURL = plan.attachmentFileURLs[attachment.id] {
              let copied = try AttachmentFileIO.copyRegularFile(
                from: sourceURL,
                to: destination,
                expectedByteCount: attachment.byteCount
              )
              guard copied.digest == plan.attachmentFileDigests[attachment.id] else {
                throw SnipLibraryError.importChanged
              }
            } else {
              throw SnipLibraryError.attachmentCopyFailed
            }
          } else if try !plan.attachmentContentsEqual(
            attachmentID: attachment.id,
            fileURL: destination
          ) {
            throw SnipLibraryError.transferConflict(.attachmentIdentity(attachment.id))
          }
          attachment.relativePath = relativePath
          transferredSnips[snipIndex].attachments[attachmentIndex] = attachment
        }
      }
      let state = SnipLibraryState(
        snips: transferredSnips,
        lists: plan.lists,
        seenRequestIDs: loaded.state.seenRequestIDs.union(transferredSnips.map(\.requestID))
      )
      try Self.validate(state)
      try Self.applyChanges(from: loaded, to: state, context: context)
      try Self.replaceDormantBases(with: plan.opaqueSyncStatePayload, context: context)
      try afterMutationBeforeSave()
      try lock.check()
      try context.save()
      seenRequestIDs = state.seenRequestIDs
      lastKnownState = state
      rememberAttachments(in: state)
      return plan.result
    } catch {
      context.rollback()
      removeAttachmentDirectories(createdDirectories)
      throw error
    }
  }

  package func applyCloudFullReenablePlan(
    _ plan: CloudFullReenableApplyPlan,
    currentRevision: UInt64 = 0
  ) async throws -> SnipLibraryTransferResult {
    guard plan.storageVersion == 1, try plan.hasValidDigest(),
      let container, isAvailable
    else { throw SnipLibraryError.invalidStore }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    try requireContentWritesAllowed(context: context)
    if try SwiftDataCloudFullOperationReceipts.isReplay(
      .reenableTransition(plan.transitionID),
      namespaceKey: plan.namespaceKey,
      digest: plan.planDigest,
      context: context
    ) {
      return plan.result
    }
    let loaded = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
    let currentSnips = loaded.state.allSnips(sortMode: .manual)
    let currentAttachmentData = try readTransferAttachments(in: currentSnips, lock: lock) {
      try Data(contentsOf: $0)
    }
    let transferMetadata = try Self.transferMetadata(context: context)
    let current = SnipLibraryTransferSnapshot(
      revision: currentRevision,
      snips: currentSnips,
      lists: loaded.state.allLists(),
      attachmentData: currentAttachmentData,
      legacyManualPositions: transferMetadata.legacyManualPositions,
      opaqueSyncStateDigest: transferMetadata.opaqueSyncStateDigest,
      opaqueSyncStatePayload: transferMetadata.opaqueSyncStatePayload
    )
    guard currentRevision == plan.targetRevision,
      SnipLibraryTransferPlanner.digest(snapshot: current) == plan.targetDigest
    else { throw SnipLibraryError.invalidStore }

    let acceptedRows = try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
      .filter { $0.namespaceKey == plan.namespaceKey }
    let enrollmentRow = try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
      .first { $0.namespaceKey == plan.namespaceKey }
    let enrollment = try Self.fullEnrollmentState(from: enrollmentRow?.referencesData)
    guard enrollment.namespaceState.revision == plan.expectedNamespaceRevision else {
      throw CloudFullStorageError.namespaceStateMismatch
    }
    var acceptedByReference: [CloudEntityReference: StoredCloudEntityRecord] = [:]
    var acceptedIdentities: Set<String> = []
    for row in acceptedRows {
      guard let kind = CloudEntityKind(rawValue: row.kind) else {
        throw CloudFullStorageError.invalidBatchReplay
      }
      let reference = CloudEntityReference(kind: kind, domainID: row.domainID)
      guard acceptedByReference.updateValue(row, forKey: reference) == nil,
        acceptedIdentities.insert(row.identity.key).inserted
      else { throw CloudFullStorageError.invalidBatchReplay }
    }
    guard Set(acceptedByReference.keys) == Set(plan.acceptedCAS.map { $0.accepted.reference }),
      acceptedIdentities == Set(plan.acceptedCAS.map { $0.accepted.identity.key })
    else { throw CloudFullStorageError.staleAcceptedEntity }
    for expected in plan.acceptedCAS {
      guard let row = acceptedByReference[expected.accepted.reference],
        row.identity == expected.accepted.identity,
        row.schemaVersion == expected.accepted.schemaVersion,
        row.acceptedData == expected.accepted.acceptedData,
        row.presenceData == expected.accepted.presenceData,
        row.shadowData == expected.accepted.shadowData,
        row.systemFields == expected.accepted.systemFields,
        row.dependencyListID == expected.accepted.dependencyListID,
        row.localRevision == expected.localRevision,
        row.isDeferred == expected.isDeferred
      else { throw CloudFullStorageError.staleAcceptedEntity }
    }
    guard Set(plan.acceptedCAS.map { $0.accepted.reference }).count == plan.acceptedCAS.count,
      Set(plan.conflicts.map(\.key)).count == plan.conflicts.count,
      plan.conflicts.allSatisfy({ conflict in
        (conflict.reference.kind == .snip && conflict.format == .snipMergeV1)
          || (conflict.reference.kind == .list && conflict.format == .listMergeV1)
      }),
      plan.recoveryInputs.allSatisfy({ $0.namespaceKey == plan.namespaceKey })
    else { throw CloudFullStorageError.invalidBatchReplay }

    var createdDirectories: [URL] = []
    var transferredSnips = plan.snips
    do {
      for snipIndex in transferredSnips.indices {
        try lock.check()
        for attachmentIndex in transferredSnips[snipIndex].attachments.indices {
          try lock.check()
          var attachment = transferredSnips[snipIndex].attachments[attachmentIndex]
          guard let bytes = plan.attachmentData[attachment.id] else {
            throw SnipLibraryError.attachmentCopyFailed
          }
          let safeName = URL(fileURLWithPath: attachment.fileName).lastPathComponent
          guard !safeName.isEmpty else { throw SnipLibraryError.attachmentCopyFailed }
          let relativePath = "\(attachment.id.uuidString)/\(safeName)"
          let destination = attachmentRootURL.appendingPathComponent(relativePath)
          let directory = destination.deletingLastPathComponent()
          if !FileManager.default.fileExists(atPath: destination.path) {
            try DurableFile.createDirectory(directory)
            createdDirectories.append(directory)
            try DurableFile.write(bytes, to: destination)
          } else if try Data(contentsOf: destination) != bytes {
            throw SnipLibraryError.transferConflict(.attachmentIdentity(attachment.id))
          }
          attachment.relativePath = relativePath
          transferredSnips[snipIndex].attachments[attachmentIndex] = attachment
        }
      }
      let state = SnipLibraryState(
        snips: transferredSnips,
        lists: plan.lists,
        seenRequestIDs: loaded.state.seenRequestIDs.union(transferredSnips.map(\.requestID))
      )
      try Self.validate(state)
      try Self.applyChanges(from: loaded, to: state, context: context)
      try Self.replaceDormantBases(with: plan.dormantPayload, context: context)
      for conflict in plan.conflicts {
        try Self.insertConflictIfNeeded(
          conflict,
          namespaceKey: plan.namespaceKey,
          context: context
        )
      }
      for recovery in plan.recoveryInputs {
        try Self.insertFullRecoveryIfNeeded(recovery, context: context)
      }
      SwiftDataCloudFullOperationReceipts.record(
        .reenableTransition(plan.transitionID),
        namespaceKey: plan.namespaceKey,
        digest: plan.planDigest,
        context: context
      )
      try afterMutationBeforeSave()
      try lock.check()
      try context.save()
      seenRequestIDs = state.seenRequestIDs
      lastKnownState = state
      rememberAttachments(in: state)
      return plan.result
    } catch {
      context.rollback()
      removeAttachmentDirectories(createdDirectories)
      throw error
    }
  }

  /// Uses the caller's store lock so planning and commit observe the same file
  /// policy without reacquiring it. Resolve paths before recognizing cache misses;
  /// missing durable files and unsafe paths must still reject the transfer.
  private func readTransferAttachments<Value>(
    in snips: [Snip],
    lock: SnipStoreFileLock,
    read: (URL) throws -> Value
  ) throws -> [UUID: Value] {
    var values: [UUID: Value] = [:]
    var readAttachmentIDs: Set<UUID> = []
    for attachment in snips.flatMap(\.attachments) {
      try lock.check()
      guard readAttachmentIDs.insert(attachment.id).inserted else { continue }
      let url = try attachmentURL(relativePath: attachment.relativePath)
      if attachment.relativePath.hasPrefix("CloudDownloads/"),
        !FileManager.default.fileExists(atPath: url.path)
      { continue }
      do {
        values[attachment.id] = try read(url)
      } catch {
        throw SnipLibraryError.attachmentCopyFailed
      }
    }
    try lock.check()
    return values
  }

  func retireCompletedCloudFullReenable(
    namespaceKey: CloudSyncNamespaceKey,
    transitionID: UUID
  ) throws {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    guard try SwiftDataCloudFullOperationReceipts.retire(
      .reenableTransition(transitionID),
      namespaceKey: namespaceKey.rawValue,
      context: context
    ) else { return }
    try afterMutationBeforeSave()
    try lock.check()
    try context.save()
  }

  func recognizesAppliedCloudFullReenable(
    _ proof: CloudFullReenableCommitProof
  ) throws -> Bool {
    let namespaceKey = proof.namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    if let digest = try SwiftDataCloudFullOperationReceipts.digest(
      for: .reenableTransition(proof.transitionID),
      namespaceKey: namespaceKey,
      context: context
    ) {
      guard digest == proof.digest else { throw CloudFullStorageError.invalidBatchReplay }
      return true
    }
    guard try SwiftDataCloudFullOperationReceipts.migrateLegacyReenableReceipt(
      namespaceKey: namespaceKey,
      transitionID: proof.transitionID,
      expectedDigest: proof.digest,
      context: context
    ) else { return false }
    try afterMutationBeforeSave()
    try lock.check()
    try context.save()
    return true
  }

  static func transferMetadata(
    context: ModelContext
  ) throws -> (
    legacyManualPositions: [UUID: Int64],
    opaqueSyncStateDigest: Data,
    opaqueSyncStatePayload: Data
  ) {
    let legacyManualPositions = Dictionary(uniqueKeysWithValues:
      try context.fetch(FetchDescriptor<StoredLibraryMetadataRecord>()).compactMap {
        metadata -> (UUID, Int64)? in
        guard metadata.kind == StoredLibraryMetadataKind.snip.rawValue,
          metadata.orderKeyData == metadata.legacyOrderKeyData,
          let position = metadata.legacyPosition
        else { return nil }
        return (metadata.domainID, position)
      }
    )
    let bases = try context.fetch(FetchDescriptor<StoredCloudDormantBaseRecord>()).sorted(
      by: { ($0.namespaceKey, $0.id) < ($1.namespaceKey, $1.id) }
    )
    let bundle = try CloudDormantAcceptedBaseBundle(entries: bases.map { base in
      guard let kind = CloudEntityKind(rawValue: base.kind) else {
        throw SnipLibraryError.invalidStore
      }
      return CloudDormantAcceptedBaseBundle.Entry(
        namespaceKey: base.namespaceKey,
        reference: CloudEntityReference(kind: kind, domainID: base.domainID),
        identity: CloudTextStorageIdentity(
          zoneName: base.zoneName,
          ownerName: base.ownerName,
          recordName: base.recordName
        ),
        payload: base.payload
      )
    }).encoded()
    return (
      legacyManualPositions,
      Data(SHA256.hash(data: bundle)),
      bundle
    )
  }

  static func replaceDormantBases(
    with payload: Data,
    context: ModelContext
  ) throws {
    let bundle = try CloudDormantAcceptedBaseBundle.decode(payload)
    for current in try context.fetch(FetchDescriptor<StoredCloudDormantBaseRecord>()) {
      context.delete(current)
    }
    for entry in bundle.entries {
      context.insert(StoredCloudDormantBaseRecord(
        namespaceKey: entry.namespaceKey,
        reference: entry.reference,
        identity: entry.identity,
        payload: entry.payload
      ))
    }
  }
}
