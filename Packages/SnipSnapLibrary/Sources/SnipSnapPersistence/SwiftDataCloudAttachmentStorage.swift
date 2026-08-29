import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  package func reconcileCloudAttachments(
    namespaceKey: String,
    metadataZoneName: String,
    metadataOwnerName: String,
    payloadZoneName: String,
    payloadOwnerName: String
  ) throws {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let loaded = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
    let existing = try context.fetch(FetchDescriptor<StoredCloudAttachmentPublication>())
      .filter { $0.namespaceKey == namespaceKey }
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
        guard let localSourcePath else { continue }
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
          row.uploadRelativePath = upload.relativePath
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
    for url in uploadFilesToRemove { try? FileManager.default.removeItem(at: url) }
    } catch {
      context.rollback()
      for url in createdUploadFiles {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
      }
      throw error
    }
  }

  package func cloudAttachmentStorageSnapshot(
    namespaceKey: String
  ) throws -> CloudAttachmentStorageSnapshot {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let uploadRoot = try cloudAttachmentUploadRoot(namespaceKey: namespaceKey)
    let publications = try context.fetch(FetchDescriptor<StoredCloudAttachmentPublication>())
      .filter { $0.namespaceKey == namespaceKey }
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
    let cleanups = try context.fetch(FetchDescriptor<StoredCloudAttachmentCleanup>())
      .filter { $0.namespaceKey == namespaceKey }
      .map {
        CloudAttachmentCleanup(
          identity: $0.identity,
          shadowData: $0.shadowData,
          revision: $0.revision
        )
      }
      .sorted { $0.identity.key < $1.identity.key }
    let cacheRoot = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
    let caches = try context.fetch(FetchDescriptor<StoredCloudAttachmentCacheEntry>())
      .filter { $0.namespaceKey == namespaceKey }
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

  package func applyCloudAttachmentTransitions(
    namespaceKey: String,
    transitions: [CloudAttachmentTransition],
    context: ModelContext
  ) throws {
    let publications = try context.fetch(FetchDescriptor<StoredCloudAttachmentPublication>())
      .filter { $0.namespaceKey == namespaceKey }
    let byAttachment = Dictionary(uniqueKeysWithValues: publications.map { ($0.attachmentID, $0) })
    let cleanups = try context.fetch(FetchDescriptor<StoredCloudAttachmentCleanup>())
      .filter { $0.namespaceKey == namespaceKey }
    let byCleanup = Dictionary(uniqueKeysWithValues: cleanups.map { ($0.identity, $0) })
    for transition in transitions {
      switch transition {
      case .remoteMetadataAccepted(
        let metadata,
        let metadataIdentity,
        let shadow,
        let systemFields
      ):
        if let row = byAttachment[metadata.attachmentID] {
          if row.metadataAccepted,
            row.metadataShadowData == shadow,
            row.metadataSystemFields == systemFields { continue }
          guard row.metadataIdentity == metadataIdentity else {
            throw CloudAttachmentStorageError.staleTransition
          }
          if row.payloadIdentity != metadata.payloadIdentity {
            try removeCloudAttachmentCacheRow(
              namespaceKey: namespaceKey,
              attachmentID: metadata.attachmentID,
              context: context
            )
          }
          row.snipID = metadata.snipID
          row.position = metadata.position
          row.fileName = metadata.fileName
          row.contentType = metadata.contentType
          row.byteCount = metadata.byteCount
          row.sha256 = metadata.sha256
          row.payloadZoneName = metadata.payloadIdentity.zoneName
          row.payloadOwnerName = metadata.payloadIdentity.ownerName
          row.payloadRecordName = metadata.payloadIdentity.recordName
          row.payloadAccepted = true
          row.metadataAccepted = true
          row.metadataShadowData = shadow
          row.metadataSystemFields = systemFields
          row.lastFailure = nil
          row.revision += 1
        } else {
          let row = StoredCloudAttachmentPublication(
            namespaceKey: namespaceKey,
            attachmentID: metadata.attachmentID,
            snipID: metadata.snipID,
            position: metadata.position,
            fileName: metadata.fileName,
            contentType: metadata.contentType,
            byteCount: metadata.byteCount,
            sha256: metadata.sha256,
            sourceRelativePath: nil,
            metadataIdentity: metadataIdentity,
            payloadIdentity: metadata.payloadIdentity
          )
          row.payloadAccepted = true
          row.metadataAccepted = true
          row.metadataShadowData = shadow
          row.metadataSystemFields = systemFields
          row.lastFailure = nil
          context.insert(row)
        }
      case .payloadAccepted(let attachmentID, let expected, let shadow, let systemFields):
        guard let row = byAttachment[attachmentID] else {
          throw CloudAttachmentStorageError.missingPublication
        }
        if row.payloadAccepted, row.payloadShadowData == shadow,
          row.payloadSystemFields == systemFields { continue }
        guard row.revision == expected, !row.payloadAccepted else {
          throw CloudAttachmentStorageError.staleTransition
        }
        row.payloadAccepted = true
        row.payloadShadowData = shadow
        row.payloadSystemFields = systemFields
        row.uploadRelativePath = nil
        row.lastFailure = nil
        row.revision += 1
      case .metadataAccepted(let attachmentID, let expected, let shadow, let systemFields):
        guard let row = byAttachment[attachmentID] else {
          throw CloudAttachmentStorageError.missingPublication
        }
        if row.metadataAccepted, row.metadataShadowData == shadow,
          row.metadataSystemFields == systemFields { continue }
        guard row.revision == expected, row.payloadAccepted else {
          throw CloudAttachmentStorageError.staleTransition
        }
        row.metadataAccepted = true
        row.metadataShadowData = shadow
        row.metadataSystemFields = systemFields
        if let prior = row.priorPayloadIdentity {
          try Self.insertCleanup(
            namespaceKey: namespaceKey,
            identity: prior,
            shadowData: row.priorPayloadShadowData,
            context: context
          )
          row.priorPayloadZoneName = nil
          row.priorPayloadOwnerName = nil
          row.priorPayloadRecordName = nil
          row.priorPayloadShadowData = nil
        }
        row.lastFailure = nil
        row.revision += 1
      case .metadataConflict(let attachmentID, let expected, let shadow, let systemFields):
        guard let row = byAttachment[attachmentID], row.revision == expected else {
          throw CloudAttachmentStorageError.staleTransition
        }
        row.metadataAccepted = false
        row.metadataShadowData = shadow
        row.metadataSystemFields = systemFields
        row.lastFailure = nil
        row.revision += 1
      case .payloadCollision(let attachmentID, let expected, let replacementIdentity):
        guard let row = byAttachment[attachmentID], row.revision == expected,
          !row.payloadAccepted
        else { throw CloudAttachmentStorageError.staleTransition }
        row.payloadZoneName = replacementIdentity.zoneName
        row.payloadOwnerName = replacementIdentity.ownerName
        row.payloadRecordName = replacementIdentity.recordName
        row.lastFailure = nil
        row.revision += 1
      case .metadataUnknown(let attachmentID, let expected):
        guard let row = byAttachment[attachmentID], row.revision == expected else {
          throw CloudAttachmentStorageError.staleTransition
        }
        row.metadataAccepted = false
        row.metadataShadowData = nil
        row.metadataSystemFields = nil
        row.lastFailure = nil
        row.revision += 1
      case .operationFailed(let attachmentID, let expected, let failure):
        guard let row = byAttachment[attachmentID], row.revision == expected else {
          throw CloudAttachmentStorageError.staleTransition
        }
        row.lastFailure = failure.rawValue
        row.revision += 1
      case .metadataDeleteAccepted(let attachmentID, let expected):
        guard let row = byAttachment[attachmentID], row.revision == expected,
          !row.isLocallyPresent
        else { throw CloudAttachmentStorageError.staleTransition }
        try Self.insertCleanup(
          namespaceKey: namespaceKey,
          identity: row.payloadIdentity,
          shadowData: row.payloadShadowData,
          context: context
        )
        try removeCloudAttachmentCacheRow(
          namespaceKey: namespaceKey,
          attachmentID: attachmentID,
          context: context
        )
        context.delete(row)
      case .metadataDeleteConflict(let attachmentID, let expected, let shadow, let systemFields):
        guard let row = byAttachment[attachmentID], row.revision == expected,
          !row.isLocallyPresent
        else { throw CloudAttachmentStorageError.staleTransition }
        row.metadataAccepted = true
        row.metadataShadowData = shadow
        row.metadataSystemFields = systemFields
        row.lastFailure = nil
        row.revision += 1
      case .remoteMetadataDeleted(let metadataIdentity):
        guard let row = publications.first(where: { $0.metadataIdentity == metadataIdentity })
        else { continue }
        try removeCloudAttachmentCacheRow(
          namespaceKey: namespaceKey,
          attachmentID: row.attachmentID,
          context: context
        )
        try removeMaterializedCloudAttachment(
          attachmentID: row.attachmentID,
          snipID: row.snipID,
          context: context
        )
        context.delete(row)
      case .cleanupAccepted(let identity, let expected):
        guard let row = byCleanup[identity] else { continue }
        guard row.revision == expected else { throw CloudAttachmentStorageError.staleTransition }
        context.delete(row)
      case .cleanupConflict(let identity, let expected, let shadow):
        guard let row = byCleanup[identity], row.revision == expected else {
          throw CloudAttachmentStorageError.staleTransition
        }
        row.shadowData = shadow
        row.revision += 1
      }
    }
  }

  package func commitCloudAttachmentTransitions(
    namespaceKey: String,
    transitions: [CloudAttachmentTransition]
  ) throws {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let uploadRoot = try cloudAttachmentUploadRoot(namespaceKey: namespaceKey)
    let acceptedAttachmentIDs = Set(transitions.compactMap { transition -> UUID? in
      guard case .payloadAccepted(let attachmentID, _, _, _) = transition else { return nil }
      return attachmentID
    })
    let acceptedUploadFiles = try context.fetch(FetchDescriptor<StoredCloudAttachmentPublication>())
      .filter {
        $0.namespaceKey == namespaceKey && acceptedAttachmentIDs.contains($0.attachmentID)
      }
      .compactMap { row in
        try row.uploadRelativePath.map {
          try Self.validatedChild(relativePath: $0, root: uploadRoot)
        }
      }
    let invalidatedCacheFiles = try invalidatedCloudAttachmentCacheFiles(
      namespaceKey: namespaceKey,
      transitions: transitions,
      context: context
    )
    try applyCloudAttachmentTransitions(
      namespaceKey: namespaceKey,
      transitions: transitions,
      context: context
    )
    try materializeCloudAttachments(namespaceKey: namespaceKey, context: context)
    try afterMutationBeforeSave()
    try context.save()
    for file in acceptedUploadFiles {
      try? FileManager.default.removeItem(at: file)
      try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
    for file in invalidatedCacheFiles {
      try? FileManager.default.removeItem(at: file)
      try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
  }

  package func cloudAttachmentStagingRoot(namespaceKey: String) throws -> URL {
    let cacheRoot = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
    let root = cacheRoot.appendingPathComponent("Staging", isDirectory: true)
    try DurableFile.createDirectory(root)
    return root
  }

  package func installCloudAttachmentCacheFile(
    namespaceKey: String,
    attachmentID: UUID,
    stagedURL: URL,
    expectedByteCount: Int64,
    expectedSHA256: Data,
    maximumBytes: Int64,
    now: Date
  ) throws -> URL {
    guard maximumBytes >= 0, let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let cacheRoot = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
    let stagingRoot = try cloudAttachmentStagingRoot(namespaceKey: namespaceKey)
    try Self.requireChild(stagedURL, of: stagingRoot)
    let values = try stagedURL.resourceValues(
      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      Int64(values.fileSize ?? -1) == expectedByteCount
    else {
      throw CloudAttachmentStorageError.sizeMismatch
    }
    guard try Self.sha256(of: stagedURL) == expectedSHA256 else {
      throw CloudAttachmentStorageError.hashMismatch
    }
    let context = Self.makeContext(container: container)
    var filesToRemoveAfterCommit: [URL] = []
    guard let publication = try context.fetch(FetchDescriptor<StoredCloudAttachmentPublication>())
      .first(where: { $0.namespaceKey == namespaceKey && $0.attachmentID == attachmentID })
    else { throw CloudAttachmentStorageError.missingPublication }
    let filesRoot = cacheRoot.appendingPathComponent("Files", isDirectory: true)
    try DurableFile.createDirectory(filesRoot)
    let relativePath = "Files/\(attachmentID.uuidString.lowercased())/"
      + "\(UUID().uuidString.lowercased())-"
      + Self.safeCloudAttachmentFileName(publication.fileName)
    let destination = try Self.validatedChild(relativePath: relativePath, root: cacheRoot)
    try DurableFile.createDirectory(destination.deletingLastPathComponent())
    try FileManager.default.moveItem(at: stagedURL, to: destination)
    var didCommit = false
    defer { if !didCommit { try? FileManager.default.removeItem(at: destination) } }
    try DurableFile.syncFile(destination)
    try DurableFile.syncDirectory(filesRoot)
    let key = StoredCloudAttachmentCacheEntry.key(
      namespaceKey: namespaceKey,
      attachmentID: attachmentID
    )
    if let old = try context.fetch(FetchDescriptor<StoredCloudAttachmentCacheEntry>())
      .first(where: { $0.id == key })
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
      + Self.cloudAttachmentNamespaceDigest(namespaceKey) + "/" + relativePath
    if let attachment = try context.fetch(FetchDescriptor<StoredAttachmentRecord>())
      .first(where: { $0.id == attachmentID })
    {
      attachment.relativePath = domainRelativePath
      attachment.fileName = publication.fileName
      attachment.contentType = publication.contentType
      attachment.byteCount = publication.byteCount
    }
    let entries = try context.fetch(FetchDescriptor<StoredCloudAttachmentCacheEntry>())
      .filter { $0.namespaceKey == namespaceKey }
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
    if expectedByteCount > maximumBytes {
      context.rollback()
      throw CloudAttachmentStorageError.sizeMismatch
    }
    try afterMutationBeforeSave()
    try context.save()
    didCommit = true
    for url in filesToRemoveAfterCommit where url != destination {
      try? FileManager.default.removeItem(at: url)
    }
    return destination
  }

  package func clearCloudAttachmentCache(namespaceKey: String) throws {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let root = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
    let context = Self.makeContext(container: container)
    for directoryName in ["Files", "Staging"] {
      let directory = root.appendingPathComponent(directoryName, isDirectory: true)
      if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
      }
    }
    for entry in try context.fetch(FetchDescriptor<StoredCloudAttachmentCacheEntry>()) {
      if entry.namespaceKey == namespaceKey { context.delete(entry) }
    }
    try afterMutationBeforeSave()
    try context.save()
  }

  /// Repairs crashes between a cache file move, the matching database save, and old-file cleanup.
  package func sweepCloudAttachmentCache(
    namespaceKey: String,
    maximumBytes: Int64
  ) throws {
    guard maximumBytes >= 0, let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let root = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
    let context = Self.makeContext(container: container)
    let publications = Dictionary(uniqueKeysWithValues:
      try context.fetch(FetchDescriptor<StoredCloudAttachmentPublication>())
        .filter { $0.namespaceKey == namespaceKey }
        .map { ($0.attachmentID, $0) }
    )
    let entries = try context.fetch(FetchDescriptor<StoredCloudAttachmentCacheEntry>())
      .filter { $0.namespaceKey == namespaceKey }
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
        let values = try? url.resourceValues(
          forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        Int64(values.fileSize ?? -1) == publication.byteCount,
        (try? Self.sha256(of: url)) == publication.sha256
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
    for url in filesToRemove { try? FileManager.default.removeItem(at: url) }
    try Self.removeOrphanCloudAttachmentFiles(
      under: root.appendingPathComponent("Files", isDirectory: true),
      keeping: remainingPaths
    )
    let staging = root.appendingPathComponent("Staging", isDirectory: true)
    if FileManager.default.fileExists(atPath: staging.path) {
      try FileManager.default.removeItem(at: staging)
    }
  }

  package func touchCloudAttachmentCache(
    namespaceKey: String,
    attachmentID: UUID,
    now: Date
  ) throws -> URL? {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    guard let row = try context.fetch(FetchDescriptor<StoredCloudAttachmentCacheEntry>())
      .first(where: { $0.namespaceKey == namespaceKey && $0.attachmentID == attachmentID })
    else { return nil }
    guard let publication = try context.fetch(FetchDescriptor<StoredCloudAttachmentPublication>())
      .first(where: { $0.namespaceKey == namespaceKey && $0.attachmentID == attachmentID }),
      publication.metadataAccepted,
      publication.payloadIdentity == row.payloadIdentity
    else {
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
    let values = try? url.resourceValues(
      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    guard FileManager.default.fileExists(atPath: url.path), values?.isRegularFile == true,
      values?.isSymbolicLink != true, Int64(values?.fileSize ?? -1) == publication.byteCount,
      (try? Self.sha256(of: url)) == publication.sha256
    else {
      try? FileManager.default.removeItem(at: url)
      context.delete(row)
      try context.save()
      return nil
    }
    row.lastAccessedAt = now
    try context.save()
    return url
  }

  func cloudAttachmentCacheRoot(namespaceKey: String) throws -> URL {
    let namespaceDigest = Self.cloudAttachmentNamespaceDigest(namespaceKey)
    let root = attachmentRootURL
      .appendingPathComponent("CloudDownloads", isDirectory: true)
      .appendingPathComponent(namespaceDigest, isDirectory: true)
    try DurableFile.createDirectory(root)
    return root
  }

  func cloudAttachmentUploadRoot(namespaceKey: String) throws -> URL {
    let namespaceDigest = Self.cloudAttachmentNamespaceDigest(namespaceKey)
    let root = lockURL.deletingPathExtension().deletingLastPathComponent()
      .appendingPathComponent("CloudAttachmentUploads", isDirectory: true)
      .appendingPathComponent(namespaceDigest, isDirectory: true)
    try DurableFile.createDirectory(root)
    return root
  }

  private func stageCloudAttachmentUpload(
    sourceURL: URL,
    namespaceKey: String,
    payloadRecordName: String
  ) throws -> (relativePath: String, url: URL) {
    let root = try cloudAttachmentUploadRoot(namespaceKey: namespaceKey)
    let relativePath = "\(payloadRecordName)/payload"
    let destination = try Self.validatedChild(relativePath: relativePath, root: root)
    let directory = destination.deletingLastPathComponent()
    try DurableFile.createDirectory(directory)
    if FileManager.default.fileExists(atPath: destination.path) {
      let sourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      let stagedValues = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if sourceValues.isRegularFile == true, stagedValues.isRegularFile == true,
        sourceValues.fileSize == stagedValues.fileSize,
        try Self.sha256(of: sourceURL) == Self.sha256(of: destination)
      {
        return (relativePath, destination)
      }
      try FileManager.default.removeItem(at: destination)
    }
    do {
      try FileManager.default.copyItem(at: sourceURL, to: destination)
      try DurableFile.syncFile(destination)
      try DurableFile.syncDirectory(directory)
      try DurableFile.syncDirectory(root)
      return (relativePath, destination)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  private static func cloudAttachmentNamespaceDigest(_ namespaceKey: String) -> String {
    Data(SHA256.hash(data: Data(namespaceKey.utf8)))
      .map { String(format: "%02x", $0) }.joined()
  }

  private static func removeOrphanCloudAttachmentFiles(
    under root: URL,
    keeping paths: Set<String>
  ) throws {
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    var emptyDirectories: [URL] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      )
      if values.isSymbolicLink == true {
        enumerator.skipDescendants()
        try FileManager.default.removeItem(at: url)
      } else if values.isDirectory == true {
        emptyDirectories.append(url)
      } else if values.isRegularFile == true,
        !paths.contains(url.standardizedFileURL.path)
      {
        try FileManager.default.removeItem(at: url)
      }
    }
    for directory in emptyDirectories.reversed() {
      if (try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty {
        try FileManager.default.removeItem(at: directory)
      }
    }
  }

  package func materializeCloudAttachments(
    namespaceKey: String,
    context: ModelContext
  ) throws {
    let snipIDs = Set(try context.fetch(FetchDescriptor<StoredSnipRecord>()).map(\.id))
    let publications = try context.fetch(FetchDescriptor<StoredCloudAttachmentPublication>())
      .filter {
        $0.namespaceKey == namespaceKey && $0.isLocallyPresent && $0.metadataAccepted
          && $0.sourceRelativePath == nil && snipIDs.contains($0.snipID)
      }
    var attachments = Dictionary(uniqueKeysWithValues:
      try context.fetch(FetchDescriptor<StoredAttachmentRecord>()).map { ($0.id, $0) }
    )
    var references = Dictionary(uniqueKeysWithValues:
      try context.fetch(FetchDescriptor<StoredSnipAttachmentReference>()).map { ($0.id, $0) }
    )
    let cacheEntries = Dictionary(uniqueKeysWithValues:
      try context.fetch(FetchDescriptor<StoredCloudAttachmentCacheEntry>())
        .filter { $0.namespaceKey == namespaceKey }
        .map { ($0.attachmentID, $0) }
    )
    let namespaceDigest = Self.cloudAttachmentNamespaceDigest(namespaceKey)
    for publication in publications {
      let relativePath: String
      if let cache = cacheEntries[publication.attachmentID],
        cache.payloadIdentity == publication.payloadIdentity
      {
        relativePath = "CloudDownloads/\(namespaceDigest)/\(cache.relativePath)"
      } else {
        relativePath = Self.cloudAttachmentCacheRelativePath(
          namespaceKey: namespaceKey,
          attachmentID: publication.attachmentID,
          fileName: publication.fileName
        )
      }
      let attachment = SnipAttachment(
        id: publication.attachmentID,
        fileName: publication.fileName,
        relativePath: relativePath,
        contentType: publication.contentType,
        byteCount: publication.byteCount
      )
      if let stored = attachments[publication.attachmentID] {
        stored.update(from: attachment)
      } else {
        let stored = StoredAttachmentRecord(attachment)
        context.insert(stored)
        attachments[publication.attachmentID] = stored
      }
      let id = StoredSnipAttachmentReference.identifier(
        snipID: publication.snipID,
        attachmentID: publication.attachmentID
      )
      if let reference = references[id] {
        reference.update(position: publication.position)
      } else {
        let reference = StoredSnipAttachmentReference(
          snipID: publication.snipID,
          attachmentID: publication.attachmentID,
          position: publication.position
        )
        context.insert(reference)
        references[id] = reference
      }
    }
  }

  private func removeMaterializedCloudAttachment(
    attachmentID: UUID,
    snipID: UUID,
    context: ModelContext
  ) throws {
    let references = try context.fetch(FetchDescriptor<StoredSnipAttachmentReference>())
    for reference in references
      where reference.attachmentID == attachmentID && reference.snipID == snipID
    {
      context.delete(reference)
    }
    guard !references.contains(where: {
      $0.attachmentID == attachmentID && $0.snipID != snipID
    }) else { return }
    for attachment in try context.fetch(FetchDescriptor<StoredAttachmentRecord>())
      where attachment.id == attachmentID
    {
      context.delete(attachment)
    }
  }

  private func removeCloudAttachmentCacheRow(
    namespaceKey: String,
    attachmentID: UUID,
    context: ModelContext
  ) throws {
    for row in try context.fetch(FetchDescriptor<StoredCloudAttachmentCacheEntry>())
      where row.namespaceKey == namespaceKey && row.attachmentID == attachmentID
    {
      context.delete(row)
    }
  }

  func invalidatedCloudAttachmentCacheFiles(
    namespaceKey: String,
    transitions: [CloudAttachmentTransition],
    context: ModelContext
  ) throws -> [URL] {
    let publications = try context.fetch(FetchDescriptor<StoredCloudAttachmentPublication>())
      .filter { $0.namespaceKey == namespaceKey }
    var attachmentIDs: Set<UUID> = []
    for transition in transitions {
      switch transition {
      case .remoteMetadataAccepted(let metadata, _, _, _):
        if let current = publications.first(where: {
          $0.attachmentID == metadata.attachmentID
        }), current.payloadIdentity != metadata.payloadIdentity
          || current.byteCount != metadata.byteCount || current.sha256 != metadata.sha256
        {
          attachmentIDs.insert(metadata.attachmentID)
        }
      case .metadataDeleteAccepted(let attachmentID, _):
        attachmentIDs.insert(attachmentID)
      case .remoteMetadataDeleted(let metadataIdentity):
        if let current = publications.first(where: {
          $0.metadataIdentity == metadataIdentity
        }) {
          attachmentIDs.insert(current.attachmentID)
        }
      default:
        break
      }
    }
    let root = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
    return try context.fetch(FetchDescriptor<StoredCloudAttachmentCacheEntry>())
      .filter {
        $0.namespaceKey == namespaceKey && attachmentIDs.contains($0.attachmentID)
      }
      .compactMap { try? Self.validatedChild(relativePath: $0.relativePath, root: root) }
  }

  private static func cloudAttachmentCacheRelativePath(
    namespaceKey: String,
    attachmentID: UUID,
    fileName: String
  ) -> String {
    let digest = cloudAttachmentNamespaceDigest(namespaceKey)
    let safeName = safeCloudAttachmentFileName(fileName)
    return "CloudDownloads/\(digest)/Files/\(attachmentID.uuidString.lowercased())/\(safeName)"
  }

  private static func safeCloudAttachmentFileName(_ fileName: String) -> String {
    let value = URL(fileURLWithPath: fileName).lastPathComponent
    return value.isEmpty || value == "." || value == ".." ? "Attachment" : value
  }

  private static func insertCleanup(
    namespaceKey: String,
    identity: CloudTextStorageIdentity,
    shadowData: Data?,
    context: ModelContext
  ) throws {
    let id = StoredCloudAttachmentCleanup.key(namespaceKey: namespaceKey, identity: identity)
    if let current = try context.fetch(FetchDescriptor<StoredCloudAttachmentCleanup>())
      .first(where: { $0.id == id })
    {
      if current.shadowData == nil { current.shadowData = shadowData }
      return
    }
    context.insert(StoredCloudAttachmentCleanup(
      namespaceKey: namespaceKey,
      identity: identity,
      shadowData: shadowData
    ))
  }

  private static func sha256(of url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return Data(hasher.finalize())
  }

  static func validatedChild(relativePath: String, root: URL) throws -> URL {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
      !relativePath.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    else { throw CloudAttachmentStorageError.invalidPath }
    let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
    try requireChild(candidate, of: root)
    try requireNoSymlinkComponents(candidate, root: root)
    return candidate
  }

  private static func requireChild(_ candidate: URL, of root: URL) throws {
    let rootPath = root.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    guard candidatePath.hasPrefix(rootPath + "/") else {
      throw CloudAttachmentStorageError.invalidPath
    }
  }

  private static func requireNoSymlinkComponents(_ candidate: URL, root: URL) throws {
    let root = root.standardizedFileURL
    let candidate = candidate.standardizedFileURL
    let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard rootValues.isSymbolicLink != true else {
      throw CloudAttachmentStorageError.invalidPath
    }
    let suffix = candidate.path.dropFirst(root.path.count)
    var current = root
    for component in suffix.split(separator: "/") {
      current.appendPathComponent(String(component))
      guard FileManager.default.fileExists(atPath: current.path) else { continue }
      let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw CloudAttachmentStorageError.invalidPath
      }
    }
  }
}

private extension StoredCloudAttachmentPublication {
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
