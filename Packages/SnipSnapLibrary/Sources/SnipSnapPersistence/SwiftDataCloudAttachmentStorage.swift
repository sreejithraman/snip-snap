import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  private var cloudAttachmentFiles: CloudAttachmentCacheFiles {
    CloudAttachmentCacheFiles(attachmentRootURL: attachmentRootURL, lockURL: lockURL)
  }

  /// Moves any downloaded bytes into the durable local attachment tree, then removes all
  /// namespace-bound attachment queues, shadows, uploads, staging files, and cache rows.
  package func quarantineCloudNamespaceState(namespaceKey: CloudSyncNamespaceKey) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let loaded = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
    var createdDirectories: [URL] = []
    do {
      for attachment in loaded.attachments where attachment.relativePath.hasPrefix("CloudDownloads/") {
        let source = try Self.validatedChild(
          relativePath: attachment.relativePath,
          root: attachmentRootURL
        )
        guard FileManager.default.fileExists(atPath: source.path) else { continue }
        let safeName = URL(fileURLWithPath: attachment.fileName).lastPathComponent
        guard !safeName.isEmpty else { throw SnipLibraryError.attachmentCopyFailed }
        let relativePath = "\(attachment.id.uuidString)/\(safeName)"
        let destination = try Self.validatedChild(
          relativePath: relativePath,
          root: attachmentRootURL
        )
        let directory = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: destination.path) {
          try DurableFile.createDirectory(directory)
          createdDirectories.append(directory)
          _ = try AttachmentFileIO.copyRegularFile(from: source, to: destination)
          try DurableFile.syncFile(destination)
          try DurableFile.syncDirectory(directory)
        } else if try Data(contentsOf: destination) != Data(contentsOf: source) {
          throw SnipLibraryError.attachmentCopyFailed
        }
        attachment.relativePath = relativePath
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
      try context.save()
    } catch {
      context.rollback()
      removeAttachmentDirectories(createdDirectories)
      throw error
    }
    try cloudAttachmentFiles.removeNamespaceFiles(namespaceKey: namespaceKey)
  }

  package func reconcileCloudAttachments(
    namespaceKey: CloudSyncNamespaceKey,
    metadataZoneName: String,
    metadataOwnerName: String,
    payloadZoneName: String,
    payloadOwnerName: String
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let loaded = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
    let existing = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    )
    try sweepCloudAttachmentUploads(
      namespaceKey: namespaceKey,
      keeping: Set(existing.compactMap { row in
        row.uploadRelativePath?.split(separator: "/").first.map(String.init)
      })
    )
    let byAttachment = Dictionary(uniqueKeysWithValues: existing.map { ($0.attachmentID, $0) })
    var local: [UUID: (UUID, Int, SnipAttachment)] = [:]
    for snip in loaded.state.snips {
      for (position, attachment) in snip.attachments.enumerated() {
        local[attachment.id] = (snip.id, position, attachment)
      }
    }

    var changed = false
    var createdUploadFiles: [URL] = []
    var uploadFilesToRemove: [URL] = []
    do {
      for (attachmentID, value) in local.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
        let localSourcePath = value.2.relativePath.hasPrefix("CloudDownloads/")
          ? nil : value.2.relativePath
        if let row = byAttachment[attachmentID] {
          if !row.isLocallyPresent {
            row.isLocallyPresent = true
            changed = true
          }
          if row.snipID != value.0 || row.position != value.1 {
            row.snipID = value.0
            row.position = value.1
            row.metadataAccepted = false
            row.lastFailure = nil
            row.revision += 1
            changed = true
          }
          guard let localSourcePath else {
            if row.fileName != value.2.fileName || row.contentType != value.2.contentType {
              row.fileName = value.2.fileName
              row.contentType = value.2.contentType
              row.metadataAccepted = false
              row.lastFailure = nil
              row.revision += 1
              changed = true
            }
            continue
          }
          let sourceURL = try Self.validatedChild(
            relativePath: localSourcePath,
            root: attachmentRootURL
          )
          let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
          guard values.isRegularFile == true else {
            throw CloudAttachmentStorageError.missingPayload
          }
          let byteCount = Int64(values.fileSize ?? -1)
          let digest = try Self.sha256(of: sourceURL)
          let payloadChanged = row.sha256 != digest || row.byteCount != byteCount
          let metadataChanged = payloadChanged
            || row.fileName != value.2.fileName
            || row.contentType != value.2.contentType
            || row.sourceRelativePath != localSourcePath
          if payloadChanged {
            if row.metadataAccepted {
              row.priorPayloadZoneName = row.payloadZoneName
              row.priorPayloadOwnerName = row.payloadOwnerName
              row.priorPayloadRecordName = row.payloadRecordName
              row.priorPayloadShadowData = row.payloadShadowData
            } else if row.payloadAccepted {
              try Self.insertCleanup(
                namespaceKey: namespaceKey,
                identity: row.payloadIdentity,
                shadowData: row.payloadShadowData,
                context: context
              )
            }
            if let oldUpload = try row.uploadRelativePath.map({
              try Self.validatedChild(relativePath: $0, root: cloudAttachmentUploadRoot(
                namespaceKey: namespaceKey
              ))
            }) {
              uploadFilesToRemove.append(oldUpload)
            }
            let payloadRecordName = UUID().uuidString.lowercased()
            let upload = try stageCloudAttachmentUpload(
              sourceURL: sourceURL,
              namespaceKey: namespaceKey,
              payloadRecordName: payloadRecordName
            )
            createdUploadFiles.append(upload.url)
            row.payloadZoneName = payloadZoneName
            row.payloadOwnerName = payloadOwnerName
            row.payloadRecordName = payloadRecordName
            row.uploadRelativePath = upload.relativePath
            row.payloadAccepted = false
            row.payloadShadowData = nil
            row.payloadSystemFields = nil
            row.metadataAccepted = false
          } else if !row.payloadAccepted {
            let upload = try stageCloudAttachmentUpload(
              sourceURL: sourceURL,
              namespaceKey: namespaceKey,
              payloadRecordName: row.payloadRecordName
            )
            if row.uploadRelativePath == nil { createdUploadFiles.append(upload.url) }
            if row.uploadRelativePath != upload.relativePath {
              row.uploadRelativePath = upload.relativePath
              changed = true
            }
          }
          if metadataChanged {
            row.fileName = value.2.fileName
            row.contentType = value.2.contentType
            row.byteCount = byteCount
            row.sha256 = digest
            row.sourceRelativePath = localSourcePath
            row.metadataAccepted = false
            row.lastFailure = nil
            row.revision += 1
            changed = true
          }
          continue
        }
        let sourceURL = try Self.validatedChild(
          relativePath: value.2.relativePath,
          root: attachmentRootURL
        )
        let digest = try Self.sha256(of: sourceURL)
        let metadataIdentity = CloudTextStorageIdentity(
          zoneName: metadataZoneName,
          ownerName: metadataOwnerName,
          recordName: "a-\(attachmentID.uuidString.lowercased())"
        )
        let payloadRecordName = UUID().uuidString.lowercased()
        let payloadIdentity = CloudTextStorageIdentity(
          zoneName: payloadZoneName,
          ownerName: payloadOwnerName,
          recordName: payloadRecordName
        )
        let upload = try stageCloudAttachmentUpload(
          sourceURL: sourceURL,
          namespaceKey: namespaceKey,
          payloadRecordName: payloadRecordName
        )
        createdUploadFiles.append(upload.url)
        let row = StoredCloudAttachmentPublication(
          namespaceKey: namespaceKey,
          attachmentID: attachmentID,
          snipID: value.0,
          position: value.1,
          fileName: value.2.fileName,
          contentType: value.2.contentType,
          byteCount: value.2.byteCount,
          sha256: digest,
          sourceRelativePath: value.2.relativePath,
          metadataIdentity: metadataIdentity,
          payloadIdentity: payloadIdentity
        )
        row.uploadRelativePath = upload.relativePath
        context.insert(row)
        changed = true
      }

      for row in existing where local[row.attachmentID] == nil && row.isLocallyPresent {
        row.isLocallyPresent = false
        row.sourceRelativePath = nil
        row.lastFailure = nil
        row.revision += 1
        changed = true
        if !row.metadataAccepted {
          if row.payloadAccepted {
            try Self.insertCleanup(
              namespaceKey: namespaceKey,
              identity: row.payloadIdentity,
              shadowData: row.payloadShadowData,
              context: context
            )
          }
          if let upload = try row.uploadRelativePath.map({
            try Self.validatedChild(
              relativePath: $0,
              root: cloudAttachmentUploadRoot(namespaceKey: namespaceKey)
            )
          }) {
            uploadFilesToRemove.append(upload)
          }
          context.delete(row)
        }
      }
      if changed {
        try afterMutationBeforeSave()
        try context.save()
      }
      for url in uploadFilesToRemove {
        CloudAttachmentCacheFiles.remove(url, includingParentDirectory: true)
      }
    } catch {
      context.rollback()
      for url in createdUploadFiles {
        CloudAttachmentCacheFiles.remove(url, includingParentDirectory: true)
      }
      throw error
    }
  }

  package func cloudAttachmentStorageSnapshot(
    namespaceKey: CloudSyncNamespaceKey
  ) throws -> CloudAttachmentStorageSnapshot {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let uploadRoot = try cloudAttachmentUploadRoot(namespaceKey: namespaceKey)
    let publications = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    )
      .map { row in
        CloudAttachmentPublication(
          metadata: row.metadata,
          metadataIdentity: row.metadataIdentity,
          isLocallyPresent: row.isLocallyPresent,
          localSourceURL: try row.sourceRelativePath.map {
            try Self.validatedChild(relativePath: $0, root: attachmentRootURL)
          },
          sourceURL: try row.uploadRelativePath.map {
            try Self.validatedChild(relativePath: $0, root: uploadRoot)
          },
          payloadAccepted: row.payloadAccepted,
          payloadShadowData: row.payloadShadowData,
          metadataAccepted: row.metadataAccepted,
          metadataShadowData: row.metadataShadowData,
          priorPayloadIdentity: row.priorPayloadIdentity,
          priorPayloadShadowData: row.priorPayloadShadowData,
          lastFailure: row.lastFailure.flatMap(CloudAttachmentFailure.init(rawValue:)),
          revision: row.revision
        )
      }
      .sorted { $0.metadata.attachmentID.uuidString < $1.metadata.attachmentID.uuidString }
    let cleanups = try Self.cloudAttachmentCleanups(
      namespaceKey: namespaceKey,
      context: context
    )
      .map {
        CloudAttachmentCleanup(
          identity: $0.identity,
          shadowData: $0.shadowData,
          blockedByAttachmentID: $0.blockedByAttachmentID,
          lastFailure: $0.lastFailure.flatMap(CloudAttachmentFailure.init(rawValue:)),
          revision: $0.revision
        )
      }
      .sorted { $0.identity.key < $1.identity.key }
    let cacheRoot = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
    let caches = try Self.cloudAttachmentCacheEntries(
      namespaceKey: namespaceKey,
      context: context
    )
      .map {
        CloudAttachmentCacheEntry(
          attachmentID: $0.attachmentID,
          payloadIdentity: $0.payloadIdentity,
          fileURL: try Self.validatedChild(relativePath: $0.relativePath, root: cacheRoot),
          byteCount: $0.byteCount,
          lastAccessedAt: $0.lastAccessedAt
        )
      }
      .sorted { $0.attachmentID.uuidString < $1.attachmentID.uuidString }
    return CloudAttachmentStorageSnapshot(
      publications: publications,
      cleanups: cleanups,
      cacheEntries: caches
    )
  }

  package func quarantineCloudAttachmentOperations(
    namespaceKey: CloudSyncNamespaceKey,
    publicationIDs: Set<UUID>,
    cleanupIdentities: Set<CloudTextStorageIdentity>
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    guard !publicationIDs.isEmpty || !cleanupIdentities.isEmpty else { return }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let publications = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    )
    let cleanups = try Self.cloudAttachmentCleanups(
      namespaceKey: namespaceKey,
      context: context
    )
    var changed = false
    for row in publications where publicationIDs.contains(row.attachmentID)
      && row.lastFailure != CloudAttachmentFailure.invalidRecord.rawValue
    {
      row.lastFailure = CloudAttachmentFailure.invalidRecord.rawValue
      row.revision += 1
      changed = true
    }
    for row in cleanups where cleanupIdentities.contains(row.identity)
      && row.lastFailure != CloudAttachmentFailure.invalidRecord.rawValue
    {
      row.lastFailure = CloudAttachmentFailure.invalidRecord.rawValue
      row.revision += 1
      changed = true
    }
    if changed {
      try afterMutationBeforeSave()
      try context.save()
    }
  }

  package func clearManuallyRetryableCloudAttachmentFailures(
    namespaceKey: CloudSyncNamespaceKey
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let publications = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    )
    let cleanups = try Self.cloudAttachmentCleanups(
      namespaceKey: namespaceKey,
      context: context
    )
    var changed = false
    for row in publications {
      guard let failure = row.lastFailure.flatMap(CloudAttachmentFailure.init(rawValue:)),
        failure.retriesManually,
        !failure.retriesAutomatically
      else { continue }
      row.lastFailure = nil
      row.revision += 1
      changed = true
    }
    for row in cleanups {
      guard let failure = row.lastFailure.flatMap(CloudAttachmentFailure.init(rawValue:)),
        failure.retriesManually,
        !failure.retriesAutomatically
      else { continue }
      row.lastFailure = nil
      row.revision += 1
      changed = true
    }
    if changed {
      try afterMutationBeforeSave()
      try context.save()
    }
  }

  package func cloudAttachmentStagingRoot(namespaceKey: CloudSyncNamespaceKey) throws -> URL {
    try cloudAttachmentFiles.stagingRoot(namespaceKey: namespaceKey.rawValue)
  }

  package func installCloudAttachmentCacheFile(
    namespaceKey: CloudSyncNamespaceKey,
    attachmentID: UUID,
    expectedPayloadIdentity: CloudTextStorageIdentity,
    stagedURL: URL,
    expectedByteCount: Int64,
    expectedSHA256: Data,
    maximumBytes: Int64,
    now: Date
  ) throws -> URL {
    let namespaceKey = namespaceKey.rawValue
    guard maximumBytes >= 0, let container else { throw SnipLibraryError.storeUnavailable }
    guard expectedByteCount <= maximumBytes else {
      throw CloudAttachmentStorageError.sizeMismatch
    }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let cacheRoot = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
    try cloudAttachmentFiles.validateStagedFile(
      stagedURL,
      namespaceKey: namespaceKey,
      expectedByteCount: expectedByteCount,
      expectedSHA256: expectedSHA256
    )
    let context = Self.makeContext(container: container)
    var filesToRemoveAfterCommit: [URL] = []
    guard let publication = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    ).first(where: { $0.attachmentID == attachmentID })
    else { throw CloudAttachmentStorageError.missingPublication }
    guard publication.payloadIdentity == expectedPayloadIdentity,
      publication.byteCount == expectedByteCount,
      publication.sha256 == expectedSHA256
    else { throw CloudAttachmentStorageError.staleTransition }
    let relativePath = CloudAttachmentCacheFiles.cacheEntryRelativePath(
      attachmentID: attachmentID,
      fileName: publication.fileName
    )
    let destination = try cloudAttachmentFiles.installStagedFile(
      stagedURL,
      namespaceKey: namespaceKey,
      relativePath: relativePath
    )
    var didCommit = false
    defer { if !didCommit { CloudAttachmentCacheFiles.remove(destination) } }
    let key = StoredCloudAttachmentCacheEntry.key(
      namespaceKey: namespaceKey,
      attachmentID: attachmentID
    )
    if let old = try Self.cloudAttachmentCacheEntries(
      namespaceKey: namespaceKey,
      context: context
    ).first(where: { $0.id == key })
    {
      if let oldURL = try? Self.validatedChild(relativePath: old.relativePath, root: cacheRoot) {
        filesToRemoveAfterCommit.append(oldURL)
      }
      context.delete(old)
    }
    context.insert(StoredCloudAttachmentCacheEntry(
      namespaceKey: namespaceKey,
      attachmentID: attachmentID,
      payloadIdentity: publication.payloadIdentity,
      relativePath: relativePath,
      byteCount: expectedByteCount,
      lastAccessedAt: now
    ))
    let domainRelativePath = "CloudDownloads/"
      + CloudAttachmentCacheFiles.namespaceDigest(namespaceKey) + "/" + relativePath
    if let attachment = try Self.storedAttachments(
      attachmentID: attachmentID,
      context: context
    ).first
    {
      attachment.relativePath = domainRelativePath
      attachment.fileName = publication.fileName
      attachment.contentType = publication.contentType
      attachment.byteCount = publication.byteCount
    }
    let entries = try Self.cloudAttachmentCacheEntries(
      namespaceKey: namespaceKey,
      context: context
    )
      .sorted {
        if $0.lastAccessedAt != $1.lastAccessedAt { return $0.lastAccessedAt < $1.lastAccessedAt }
        return $0.id < $1.id
      }
    var total = entries.reduce(Int64(0)) { $0 + $1.byteCount }
    for entry in entries where total > maximumBytes && entry.attachmentID != attachmentID {
      let url = try Self.validatedChild(relativePath: entry.relativePath, root: cacheRoot)
      filesToRemoveAfterCommit.append(url)
      total -= entry.byteCount
      context.delete(entry)
    }
    try afterMutationBeforeSave()
    try context.save()
    didCommit = true
    for url in filesToRemoveAfterCommit where url != destination {
      CloudAttachmentCacheFiles.remove(url)
    }
    return destination
  }

  package func clearCloudAttachmentCache(namespaceKey: CloudSyncNamespaceKey) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    try cloudAttachmentFiles.clearCacheDirectories(namespaceKey: namespaceKey)
    let context = Self.makeContext(container: container)
    for entry in try Self.cloudAttachmentCacheEntries(
      namespaceKey: namespaceKey,
      context: context
    ) { context.delete(entry) }
    try afterMutationBeforeSave()
    try context.save()
  }

  /// Repairs crashes between a cache file move, the matching database save, and old-file cleanup.
  package func sweepCloudAttachmentCache(
    namespaceKey: CloudSyncNamespaceKey,
    maximumBytes: Int64
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard maximumBytes >= 0, let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let root = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
    let context = Self.makeContext(container: container)
    let publications = Dictionary(uniqueKeysWithValues:
      try Self.cloudAttachmentPublications(namespaceKey: namespaceKey, context: context)
        .map { ($0.attachmentID, $0) }
    )
    let entries = try Self.cloudAttachmentCacheEntries(
      namespaceKey: namespaceKey,
      context: context
    )
      .sorted {
        if $0.lastAccessedAt != $1.lastAccessedAt { return $0.lastAccessedAt < $1.lastAccessedAt }
        return $0.id < $1.id
      }
    var kept: [(StoredCloudAttachmentCacheEntry, URL)] = []
    var filesToRemove: [URL] = []
    var removedEntryIDs: Set<String> = []
    for entry in entries {
      guard let url = try? Self.validatedChild(relativePath: entry.relativePath, root: root) else {
        context.delete(entry)
        removedEntryIDs.insert(entry.id)
        continue
      }
      guard let publication = publications[entry.attachmentID],
        publication.metadataAccepted,
        publication.payloadIdentity == entry.payloadIdentity,
        cloudAttachmentFiles.cacheFileIsValid(
          url,
          expectedByteCount: publication.byteCount,
          expectedSHA256: publication.sha256
        )
      else {
        context.delete(entry)
        removedEntryIDs.insert(entry.id)
        filesToRemove.append(url)
        continue
      }
      kept.append((entry, url))
    }
    var total = kept.reduce(Int64(0)) { $0 + $1.0.byteCount }
    for (entry, url) in kept where total > maximumBytes {
      total -= entry.byteCount
      context.delete(entry)
      removedEntryIDs.insert(entry.id)
      filesToRemove.append(url)
    }
    let remainingPaths = Set(kept.compactMap { entry, url in
      removedEntryIDs.contains(entry.id) ? nil : url.standardizedFileURL.path
    })
    if !removedEntryIDs.isEmpty {
      try afterMutationBeforeSave()
      try context.save()
    }
    for url in filesToRemove { CloudAttachmentCacheFiles.remove(url) }
    try CloudAttachmentCacheFiles.removeOrphans(
      under: root.appendingPathComponent("Files", isDirectory: true),
      keeping: remainingPaths
    )
    try cloudAttachmentFiles.clearStaging(namespaceKey: namespaceKey)
  }

  package func touchCloudAttachmentCache(
    namespaceKey: CloudSyncNamespaceKey,
    attachmentID: UUID,
    now: Date
  ) throws -> URL? {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    guard let row = try Self.cloudAttachmentCacheEntries(
      namespaceKey: namespaceKey,
      context: context
    ).first(where: { $0.attachmentID == attachmentID })
    else { return nil }
    guard let publication = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    ).first(where: { $0.attachmentID == attachmentID }),
      publication.metadataAccepted,
      publication.payloadIdentity == row.payloadIdentity
    else {
      let root = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
      if let url = try? Self.validatedChild(relativePath: row.relativePath, root: root) {
        CloudAttachmentCacheFiles.remove(url, includingParentDirectory: true)
      }
      context.delete(row)
      try context.save()
      return nil
    }
    let root = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
    guard let url = try? Self.validatedChild(relativePath: row.relativePath, root: root) else {
      context.delete(row)
      try context.save()
      return nil
    }
    guard cloudAttachmentFiles.cacheFileIsValid(
      url,
      expectedByteCount: publication.byteCount,
      expectedSHA256: publication.sha256
    )
    else {
      CloudAttachmentCacheFiles.remove(url)
      context.delete(row)
      try context.save()
      return nil
    }
    row.lastAccessedAt = now
    try context.save()
    return url
  }

  func cloudAttachmentCacheRoot(namespaceKey: String) throws -> URL {
    try cloudAttachmentFiles.cacheRoot(namespaceKey: namespaceKey)
  }

  func cloudAttachmentUploadRoot(namespaceKey: String) throws -> URL {
    try cloudAttachmentFiles.uploadRoot(namespaceKey: namespaceKey)
  }

  private func stageCloudAttachmentUpload(
    sourceURL: URL,
    namespaceKey: String,
    payloadRecordName: String
  ) throws -> (relativePath: String, url: URL) {
    try cloudAttachmentFiles.stageUpload(
      sourceURL: sourceURL,
      namespaceKey: namespaceKey,
      payloadRecordName: payloadRecordName
    )
  }

  /// Removes only direct, unowned upload directories so recovery work stays bounded.
  private func sweepCloudAttachmentUploads(
    namespaceKey: String,
    keeping recordNames: Set<String>
  ) throws {
    try cloudAttachmentFiles.sweepUploads(
      namespaceKey: namespaceKey,
      keeping: recordNames
    )
  }

  static func cloudAttachmentPublications(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredCloudAttachmentPublication] {
    let key = namespaceKey
    return try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredCloudAttachmentPublication> { $0.namespaceKey == key }
    ))
  }

  static func cloudAttachmentCleanups(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredCloudAttachmentCleanup] {
    let key = namespaceKey
    return try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredCloudAttachmentCleanup> { $0.namespaceKey == key }
    ))
  }

  static func cloudAttachmentCacheEntries(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredCloudAttachmentCacheEntry] {
    let key = namespaceKey
    return try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredCloudAttachmentCacheEntry> { $0.namespaceKey == key }
    ))
  }

  private static func storedAttachments(
    attachmentID: UUID,
    context: ModelContext
  ) throws -> [StoredAttachmentRecord] {
    let id = attachmentID
    return try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredAttachmentRecord> { $0.id == id }
    ))
  }

  private static func insertCleanup(
    namespaceKey: String,
    identity: CloudTextStorageIdentity,
    shadowData: Data?,
    blockedByAttachmentID: UUID? = nil,
    context: ModelContext
  ) throws {
    let id = StoredCloudAttachmentCleanup.key(namespaceKey: namespaceKey, identity: identity)
    if let current = try Self.cloudAttachmentCleanups(
      namespaceKey: namespaceKey,
      context: context
    )
      .first(where: { $0.id == id })
    {
      if current.shadowData == nil { current.shadowData = shadowData }
      if current.blockedByAttachmentID == nil {
        current.blockedByAttachmentID = blockedByAttachmentID
      }
      return
    }
    context.insert(StoredCloudAttachmentCleanup(
      namespaceKey: namespaceKey,
      identity: identity,
      shadowData: shadowData,
      blockedByAttachmentID: blockedByAttachmentID
    ))
  }

  private static func sha256(of url: URL) throws -> Data {
    try CloudAttachmentCacheFiles.digest(at: url)
  }

  static func validatedChild(relativePath: String, root: URL) throws -> URL {
    try CloudAttachmentCacheFiles.validatedChild(relativePath: relativePath, root: root)
  }
}

extension StoredCloudAttachmentPublication {
  var metadataIdentity: CloudTextStorageIdentity {
    CloudTextStorageIdentity(
      zoneName: metadataZoneName,
      ownerName: metadataOwnerName,
      recordName: metadataRecordName
    )
  }

  var payloadIdentity: CloudTextStorageIdentity {
    CloudTextStorageIdentity(
      zoneName: payloadZoneName,
      ownerName: payloadOwnerName,
      recordName: payloadRecordName
    )
  }

  var priorPayloadIdentity: CloudTextStorageIdentity? {
    guard let zoneName = priorPayloadZoneName,
      let ownerName = priorPayloadOwnerName,
      let recordName = priorPayloadRecordName
    else { return nil }
    return CloudTextStorageIdentity(
      zoneName: zoneName,
      ownerName: ownerName,
      recordName: recordName
    )
  }

  var metadata: CloudAttachmentMetadataValue {
    CloudAttachmentMetadataValue(
      attachmentID: attachmentID,
      snipID: snipID,
      position: position,
      fileName: fileName,
      contentType: contentType,
      byteCount: byteCount,
      sha256: sha256,
      payloadIdentity: payloadIdentity
    )
  }
}
