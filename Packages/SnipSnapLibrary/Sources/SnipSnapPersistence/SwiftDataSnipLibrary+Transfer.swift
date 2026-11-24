import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData

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
    let requests = try context.fetch(FetchDescriptor<StoredRequestRecord>())
    return SnipLibraryTransferSnapshot(
      revision: revision,
      snips: current.snips,
      lists: current.lists,
      attachmentData: attachmentData,
      opaqueSyncStateDigest: transferMetadata.opaqueSyncStateDigest,
      opaqueSyncStatePayload: transferMetadata.opaqueSyncStatePayload,
      additionalSeenRequestIDs: Set(requests.map(\.id))
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
      opaqueSyncStateDigest: transferMetadata.opaqueSyncStateDigest,
      opaqueSyncStatePayload: transferMetadata.opaqueSyncStatePayload
    )
  }

  public func mergeTransferSnapshot(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID,
    expectedTargetDigest: Data?
  ) async throws -> SnipLibraryTransferResult {
    let target = try await transferSnapshot(revision: 0)
    let plan = try SnipLibraryTransferPlanner.plan(source: source, target: target, transitionID: transitionID)
    if let expectedTargetDigest, plan.targetDigest != expectedTargetDigest {
      throw SnipLibraryError.importChanged
    }
    do {
      return try applyTransferPlan(plan)
    } catch SnipLibraryError.invalidStore where expectedTargetDigest != nil {
      throw SnipLibraryError.importChanged
    }
  }

  package func applyTransferPlan(
    _ plan: SnipLibraryTransferPlan
  ) throws -> SnipLibraryTransferResult {
    try applyTransferPlan(plan, reenable: nil)
  }

  package func applyCloudFullReenablePlan(_ plan: CloudFullReenableApplyPlan) throws {
    _ = try applyTransferPlan(plan.transfer, reenable: plan)
  }

  private func applyTransferPlan(
    _ plan: SnipLibraryTransferPlan, reenable: CloudFullReenableApplyPlan?
  ) throws -> SnipLibraryTransferResult {
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
      revision: 0,
      snips: currentSnips,
      lists: loaded.state.allLists(),
      attachmentData: currentAttachmentData,
      opaqueSyncStateDigest: transferMetadata.opaqueSyncStateDigest,
      opaqueSyncStatePayload: transferMetadata.opaqueSyncStatePayload
    )
    guard SnipLibraryTransferPlanner.digest(snapshot: current) == plan.targetDigest
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
              || plan.unavailableDownloadIDs.contains(attachment.id)
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
        seenRequestIDs: loaded.state.seenRequestIDs
          .union(transferredSnips.map(\.requestID))
          .union(plan.additionalSeenRequestIDs)
      )
      try Self.validate(state)
      try Self.applyChanges(from: loaded, to: state, context: context)
      try Self.replaceDormantBases(with: plan.opaqueSyncStatePayload, context: context)
      if let reenable {
        for conflict in reenable.conflicts {
          try Self.insertConflictIfNeeded(conflict, namespaceKey: reenable.namespaceKey, context: context)
        }
        for recovery in reenable.recoveryInputs {
          try Self.insertFullRecoveryIfNeeded(recovery, context: context)
        }
      }
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

  static func transferMetadata(
    context: ModelContext
  ) throws -> (
    opaqueSyncStateDigest: Data,
    opaqueSyncStatePayload: Data
  ) {
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
    return (Data(SHA256.hash(data: bundle)), bundle)
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
