import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  /// Moves any available downloaded bytes into durable local attachment storage, then removes
  /// namespace-bound attachment queues, shadows, uploads, staging files, and cache rows.
  package func quarantineCloudNamespaceState(namespaceKey: CloudSyncNamespaceKey) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let loaded = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
    let publications = Dictionary(uniqueKeysWithValues: try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    ).map { ($0.attachmentID, $0) })
    var durableCopies: [CloudAttachmentDurableCopy] = []
    do {
      for attachment in loaded.attachments where attachment.relativePath.hasPrefix("CloudDownloads/") {
        try lock.check()
        let source = try attachmentURL(relativePath: attachment.relativePath)
        guard FileManager.default.fileExists(atPath: source.path),
          let publication = publications[attachment.id]
        else { continue }
        let copy = try copyCloudAttachmentToDurableStorage(
          attachmentID: attachment.id,
          fileName: attachment.fileName,
          source: source,
          expectedByteCount: publication.byteCount,
          expectedSHA256: publication.sha256,
          storedAttachments: loaded.attachments
        )
        durableCopies.append(copy)
        attachment.relativePath = copy.relativePath
      }
      for row in try Self.cloudAttachmentPublications(
        namespaceKey: namespaceKey,
        context: context
      ) { context.delete(row) }
      for row in try Self.cloudAttachmentCleanups(namespaceKey: namespaceKey, context: context) {
        context.delete(row)
      }
      for row in try Self.cloudAttachmentCacheEntries(
        namespaceKey: namespaceKey,
        context: context
      ) { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudTextRecord>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudEngineState>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudStagedBatch>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudNamespaceState>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudFullConflict>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudDormantBaseRecord>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudMappingQuarantine>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudFullBatchReceipt>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      for row in try context.fetch(FetchDescriptor<StoredCloudPendingDelete>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
      try afterMutationBeforeSave()
      try lock.check()
      try context.save()
    } catch {
      context.rollback()
      for copy in durableCopies.reversed() { copy.rollBack() }
      throw error
    }
    try lock.check()
    try cloudAttachmentFiles.removeNamespaceFiles(namespaceKey: namespaceKey)
  }

  /// Verifies every Cloud attachment, or makes its durable copy, before a local-copy transfer.
  /// Cloud metadata remains intact until the transition commits.
  package func prepareCloudAttachmentsForLocalCopy(
    namespaceKey: CloudSyncNamespaceKey
  ) throws {
    let snapshot = try checkedSnapshot(sortedBy: .manual)
    for attachmentID in snapshot.snips.flatMap(\.attachments).map(\.id) {
      guard try materializeCloudAttachmentForLocalCopy(
        namespaceKey: namespaceKey,
        attachmentID: attachmentID
      ) else { throw SnipLibraryError.attachmentCopyFailed }
    }
  }

  /// Verifies durable bytes, or makes a durable copy of a verified cache entry.
  /// Returns `false` only when the bytes are unavailable here but recoverable from CloudKit.
  package func materializeCloudAttachmentForLocalCopy(
    namespaceKey: CloudSyncNamespaceKey,
    attachmentID: UUID
  ) throws -> Bool {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let loaded = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
    guard let attachment = loaded.attachments.first(where: { $0.id == attachmentID }) else {
      throw SnipLibraryError.attachmentCopyFailed
    }
    let publication = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    ).first(where: { $0.attachmentID == attachmentID })
    guard let publication else {
      guard !attachment.relativePath.hasPrefix("CloudDownloads/") else {
        throw SnipLibraryError.attachmentCopyFailed
      }
      let durable = try attachmentURL(relativePath: attachment.relativePath)
      let values = try durable.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw SnipLibraryError.attachmentCopyFailed
      }
      return true
    }
    let lifecycle = publication.lifecycle
    guard attachment.relativePath.hasPrefix("CloudDownloads/") else {
      let durable = try attachmentURL(relativePath: attachment.relativePath)
      let isValid = cloudAttachmentFileIsValid(
        durable,
        expectedByteCount: publication.byteCount,
        expectedSHA256: publication.sha256
      )
      if !isValid, !lifecycle.isPayloadRecoverableFromCloudKit {
        throw SnipLibraryError.attachmentCopyFailed
      }
      return isValid
    }
    let cachePrefix = "CloudDownloads/\(CloudAttachmentCacheFiles.namespaceDigest(namespaceKey))/"
    guard attachment.relativePath.hasPrefix(cachePrefix) else {
      throw SnipLibraryError.attachmentCopyFailed
    }
    let cachedSource: URL
    do {
      cachedSource = try attachmentURL(relativePath: attachment.relativePath)
    } catch {
      guard lifecycle.isPayloadRecoverableFromCloudKit else { throw error }
      return false
    }
    let source: URL
    if FileManager.default.fileExists(atPath: cachedSource.path) {
      source = cachedSource
    } else if let relativePath = lifecycle.localSourceRelativePath {
      source = try Self.validatedChild(relativePath: relativePath, root: attachmentRootURL)
    } else {
      return false
    }
    guard cloudAttachmentFileIsValid(
      source,
      expectedByteCount: publication.byteCount,
      expectedSHA256: publication.sha256
    ) else {
      guard lifecycle.isPayloadRecoverableFromCloudKit else {
        throw SnipLibraryError.attachmentCopyFailed
      }
      return false
    }
    var durableCopy: CloudAttachmentDurableCopy?
    do {
      let copy = try copyCloudAttachmentToDurableStorage(
        attachmentID: attachment.id,
        fileName: attachment.fileName,
        source: source,
        expectedByteCount: publication.byteCount,
        expectedSHA256: publication.sha256,
        storedAttachments: loaded.attachments
      )
      durableCopy = copy
      attachment.relativePath = copy.relativePath
      try afterMutationBeforeSave()
      try lock.check()
      try context.save()
    } catch {
      context.rollback()
      durableCopy?.rollBack()
      throw error
    }
    let refreshed = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
    lastKnownState = refreshed.state
    rememberAttachments(in: refreshed.state)
    return true
  }

  private func cloudAttachmentFileIsValid(
    _ url: URL,
    expectedByteCount: Int64,
    expectedSHA256: Data
  ) -> Bool {
    guard let values = try? url.resourceValues(
      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    ) else { return false }
    guard values.isRegularFile == true
      && values.isSymbolicLink != true
      && Int64(values.fileSize ?? -1) == expectedByteCount
    else { return false }
    return (try? AttachmentFileIO.digest(at: url)) == expectedSHA256
  }

  private func copyCloudAttachmentToDurableStorage(
    attachmentID: UUID,
    fileName: String,
    source: URL,
    expectedByteCount: Int64,
    expectedSHA256: Data,
    storedAttachments: [StoredAttachmentRecord]
  ) throws -> CloudAttachmentDurableCopy {
    let safeName = URL(fileURLWithPath: fileName).lastPathComponent
    guard !safeName.isEmpty else { throw SnipLibraryError.attachmentCopyFailed }
    let relativePath = "\(attachmentID.uuidString)/\(safeName)"
    try DurableFile.createDirectory(attachmentRootURL)
    let destination = try Self.validatedChild(
      relativePath: relativePath,
      root: attachmentRootURL
    )
    if FileManager.default.fileExists(atPath: destination.path) {
      let values = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true else { throw SnipLibraryError.attachmentCopyFailed }
      if Int64(values.fileSize ?? -1) == expectedByteCount,
        try AttachmentFileIO.digest(at: destination) == expectedSHA256
      {
        return .reused(relativePath: relativePath)
      }
      // A copy killed midway leaves a partial file. A file that a stored attachment references
      // holds that attachment's bytes, so only an unreferenced one is replaced. A case-insensitive
      // volume resolves paths that differ only in case to the same file.
      guard !storedAttachments.contains(where: {
        $0.relativePath.compare(relativePath, options: .caseInsensitive) == .orderedSame
      }) else { throw SnipLibraryError.attachmentCopyFailed }
      try FileManager.default.removeItem(at: destination)
    }
    let directory = destination.deletingLastPathComponent()
    let directoryExisted = FileManager.default.fileExists(atPath: directory.path)
    do {
      try DurableFile.createDirectory(directory)
      let copied = try AttachmentFileIO.copyRegularFile(
        from: source,
        to: destination,
        expectedByteCount: expectedByteCount
      )
      guard copied.byteCount == expectedByteCount, copied.digest == expectedSHA256 else {
        throw SnipLibraryError.attachmentCopyFailed
      }
      try DurableFile.syncFile(destination)
      try DurableFile.syncDirectory(directory)
      return .created(
        relativePath: relativePath,
        rollback: directoryExisted ? destination : directory
      )
    } catch {
      if directoryExisted {
        try? FileManager.default.removeItem(at: destination)
      } else {
        try? FileManager.default.removeItem(at: directory)
      }
      throw error
    }
  }
}

/// A durable copy made for one save. Rolling back removes only what this copy created: the
/// file, or the attachment directory when the copy created it.
private enum CloudAttachmentDurableCopy {
  /// The destination already held the verified bytes.
  case reused(relativePath: String)
  case created(relativePath: String, rollback: URL)

  var relativePath: String {
    switch self {
    case .reused(let relativePath), .created(let relativePath, _): relativePath
    }
  }

  func rollBack() {
    guard case .created(_, let rollback) = self else { return }
    try? FileManager.default.removeItem(at: rollback)
  }
}
