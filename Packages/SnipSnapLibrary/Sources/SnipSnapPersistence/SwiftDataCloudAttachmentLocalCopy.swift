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
    var rollbackURLs: [URL] = []
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
          expectedSHA256: publication.sha256
        )
        if let rollbackURL = copy.rollbackURL { rollbackURLs.append(rollbackURL) }
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
      for url in rollbackURLs.reversed() { try? FileManager.default.removeItem(at: url) }
      throw error
    }
    try lock.check()
    try cloudAttachmentFiles.removeNamespaceFiles(namespaceKey: namespaceKey)
  }

  /// Verifies or promotes every Cloud attachment before a local-copy transfer.
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

  /// Verifies durable bytes or promotes a verified cache entry into durable storage.
  /// Returns `false` only when accepted Cloud metadata can recover unavailable bytes.
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
    guard attachment.relativePath.hasPrefix("CloudDownloads/") else {
      let durable = try attachmentURL(relativePath: attachment.relativePath)
      let isValid = cloudAttachmentFileIsValid(
        durable,
        expectedByteCount: publication.byteCount,
        expectedSHA256: publication.sha256
      )
      if !isValid, !publication.metadataAccepted {
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
      guard publication.metadataAccepted else { throw error }
      return false
    }
    let source: URL
    if FileManager.default.fileExists(atPath: cachedSource.path) {
      source = cachedSource
    } else if let relativePath = publication.sourceRelativePath {
      source = try Self.validatedChild(relativePath: relativePath, root: attachmentRootURL)
    } else {
      return false
    }
    guard cloudAttachmentFileIsValid(
      source,
      expectedByteCount: publication.byteCount,
      expectedSHA256: publication.sha256
    ) else {
      guard publication.metadataAccepted else { throw SnipLibraryError.attachmentCopyFailed }
      return false
    }
    var rollbackURL: URL?
    do {
      let copy = try copyCloudAttachmentToDurableStorage(
        attachmentID: attachment.id,
        fileName: attachment.fileName,
        source: source,
        expectedByteCount: publication.byteCount,
        expectedSHA256: publication.sha256
      )
      rollbackURL = copy.rollbackURL
      attachment.relativePath = copy.relativePath
      try afterMutationBeforeSave()
      try lock.check()
      try context.save()
      rollbackURL = nil
    } catch {
      context.rollback()
      if let rollbackURL { try? FileManager.default.removeItem(at: rollbackURL) }
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
    expectedSHA256: Data
  ) throws -> (relativePath: String, rollbackURL: URL?) {
    let safeName = URL(fileURLWithPath: fileName).lastPathComponent
    guard !safeName.isEmpty else { throw SnipLibraryError.attachmentCopyFailed }
    let relativePath = "\(attachmentID.uuidString)/\(safeName)"
    let destination = try Self.validatedChild(
      relativePath: relativePath,
      root: attachmentRootURL
    )
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      let values = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true,
        Int64(values.fileSize ?? -1) == expectedByteCount,
        try AttachmentFileIO.digest(at: destination) == expectedSHA256
      else { throw SnipLibraryError.attachmentCopyFailed }
      return (relativePath, nil)
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
      return (relativePath, directoryExisted ? destination : directory)
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
