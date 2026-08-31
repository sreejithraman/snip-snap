import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  /// Moves any downloaded bytes into the durable local attachment tree, then removes all
  /// namespace-bound attachment queues, shadows, uploads, staging files, and cache rows.
  package func quarantineCloudNamespaceState(namespaceKey: String) throws {
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
          try FileManager.default.copyItem(at: source, to: destination)
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
    for root in [
      try cloudAttachmentCacheRoot(namespaceKey: namespaceKey),
      try cloudAttachmentUploadRoot(namespaceKey: namespaceKey),
    ] where FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
  }

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
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
      }
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
    namespaceKey: String,
    publicationIDs: Set<UUID>,
    cleanupIdentities: Set<CloudTextStorageIdentity>
  ) throws {
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

  package func applyCloudAttachmentTransitions(
    namespaceKey: String,
    transitions: [CloudAttachmentTransition],
    context: ModelContext
  ) throws {
    let publications = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    )
    var byAttachment = Dictionary(
      uniqueKeysWithValues: publications.map { ($0.attachmentID, $0) }
    )
    let byMetadataIdentity = Dictionary(
      publications.map { ($0.metadataIdentity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let cleanups = try Self.cloudAttachmentCleanups(
      namespaceKey: namespaceKey,
      context: context
    )
    var byCleanup = Dictionary(uniqueKeysWithValues: cleanups.map { ($0.identity, $0) })
    var materializedAttachmentIDs: Set<UUID> = []
    for transition in transitions {
      switch transition {
      case .metadataUnknown(let attachmentID, _, let replacementAttachmentID, _):
        materializedAttachmentIDs.insert(attachmentID)
        materializedAttachmentIDs.insert(replacementAttachmentID)
      case .remoteMetadataDeleted(let metadataIdentity):
        if let row = byMetadataIdentity[metadataIdentity] {
          materializedAttachmentIDs.insert(row.attachmentID)
        }
      default:
        break
      }
    }
    let materializedIDs = Array(materializedAttachmentIDs)
    let storedAttachmentRows: [StoredAttachmentRecord]
    let storedReferenceRows: [StoredSnipAttachmentReference]
    if materializedIDs.isEmpty {
      storedAttachmentRows = []
      storedReferenceRows = []
    } else {
      storedAttachmentRows = try context.fetch(FetchDescriptor<StoredAttachmentRecord>(
        predicate: #Predicate<StoredAttachmentRecord> { materializedIDs.contains($0.id) }
      ))
      storedReferenceRows = try context.fetch(FetchDescriptor<StoredSnipAttachmentReference>(
        predicate: #Predicate<StoredSnipAttachmentReference> {
          materializedIDs.contains($0.attachmentID)
        }
      ))
    }
    var storedAttachments = Dictionary(grouping:
      storedAttachmentRows,
      by: \.id
    )
    var storedReferences = Dictionary(grouping:
      storedReferenceRows,
      by: \.attachmentID
    )
    let cacheRows = try Self.cloudAttachmentCacheEntries(
      namespaceKey: namespaceKey,
      context: context
    )
    var cacheByAttachment = Dictionary(grouping: cacheRows, by: \.attachmentID)
    var pendingReplacementIDsByLocation = Dictionary(
      grouping: publications.filter { $0.isLocallyPresent && !$0.metadataAccepted },
      by: { "\($0.snipID.uuidString)|\($0.position)" }
    ).mapValues { rows in
      rows.map(\.attachmentID).sorted { $0.uuidString < $1.uuidString }
    }
    func removeCache(for attachmentID: UUID) {
      for row in cacheByAttachment.removeValue(forKey: attachmentID) ?? [] {
        context.delete(row)
      }
    }
    func insertCleanup(
      identity: CloudTextStorageIdentity,
      shadowData: Data?,
      blockedByAttachmentID: UUID? = nil
    ) {
      if let current = byCleanup[identity] {
        if current.shadowData == nil { current.shadowData = shadowData }
        if current.blockedByAttachmentID == nil {
          current.blockedByAttachmentID = blockedByAttachmentID
        }
        return
      }
      let row = StoredCloudAttachmentCleanup(
        namespaceKey: namespaceKey,
        identity: identity,
        shadowData: shadowData,
        blockedByAttachmentID: blockedByAttachmentID
      )
      context.insert(row)
      byCleanup[identity] = row
    }
    func removeMaterialized(attachmentID: UUID, snipID: UUID) {
      let references = storedReferences[attachmentID] ?? []
      for reference in references where reference.snipID == snipID {
        context.delete(reference)
      }
      let remaining = references.filter { $0.snipID != snipID }
      storedReferences[attachmentID] = remaining
      guard remaining.isEmpty else { return }
      for attachment in storedAttachments.removeValue(forKey: attachmentID) ?? [] {
        context.delete(attachment)
      }
    }
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
            removeCache(for: metadata.attachmentID)
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
          insertCleanup(identity: prior, shadowData: row.priorPayloadShadowData)
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
      case .metadataUnknown(
        let attachmentID,
        let expected,
        let replacementAttachmentID,
        let replacementMetadataIdentity
      ):
        guard let row = byAttachment[attachmentID], row.revision == expected,
          row.isLocallyPresent,
          replacementAttachmentID != attachmentID,
          replacementMetadataIdentity.zoneName == row.metadataZoneName,
          replacementMetadataIdentity.ownerName == row.metadataOwnerName,
          replacementMetadataIdentity.recordName
            == "a-\(replacementAttachmentID.uuidString.lowercased())"
        else {
          throw CloudAttachmentStorageError.staleTransition
        }
        guard byAttachment[replacementAttachmentID] == nil,
          !storedAttachments.keys.contains(replacementAttachmentID)
        else {
          throw CloudAttachmentStorageError.staleTransition
        }
        let oldAttachments = storedAttachments.removeValue(forKey: attachmentID) ?? []
        var newAttachments: [StoredAttachmentRecord] = []
        for attachment in oldAttachments {
          let replacementAttachment = StoredAttachmentRecord(SnipAttachment(
            id: replacementAttachmentID,
            fileName: attachment.fileName,
            relativePath: attachment.relativePath,
            contentType: attachment.contentType,
            byteCount: attachment.byteCount
          ))
          context.insert(replacementAttachment)
          newAttachments.append(replacementAttachment)
          context.delete(attachment)
        }
        storedAttachments[replacementAttachmentID] = newAttachments
        let oldReferences = storedReferences.removeValue(forKey: attachmentID) ?? []
        var newReferences: [StoredSnipAttachmentReference] = []
        for reference in oldReferences {
          let replacementReference = StoredSnipAttachmentReference(
            snipID: reference.snipID,
            attachmentID: replacementAttachmentID,
            position: reference.position
          )
          context.insert(replacementReference)
          newReferences.append(replacementReference)
          context.delete(reference)
        }
        storedReferences[replacementAttachmentID] = newReferences
        removeCache(for: attachmentID)
        let replacement = StoredCloudAttachmentPublication(
          namespaceKey: namespaceKey,
          attachmentID: replacementAttachmentID,
          snipID: row.snipID,
          position: row.position,
          fileName: row.fileName,
          contentType: row.contentType,
          byteCount: row.byteCount,
          sha256: row.sha256,
          sourceRelativePath: row.sourceRelativePath,
          metadataIdentity: replacementMetadataIdentity,
          payloadIdentity: row.payloadIdentity
        )
        replacement.isLocallyPresent = row.isLocallyPresent
        replacement.uploadRelativePath = row.uploadRelativePath
        replacement.payloadAccepted = row.payloadAccepted
        replacement.payloadShadowData = row.payloadShadowData
        replacement.payloadSystemFields = row.payloadSystemFields
        replacement.priorPayloadZoneName = row.priorPayloadZoneName
        replacement.priorPayloadOwnerName = row.priorPayloadOwnerName
        replacement.priorPayloadRecordName = row.priorPayloadRecordName
        replacement.priorPayloadShadowData = row.priorPayloadShadowData
        replacement.revision = row.revision + 1
        context.insert(replacement)
        context.delete(row)
        byAttachment.removeValue(forKey: attachmentID)
        byAttachment[replacementAttachmentID] = replacement
        let locationKey = "\(row.snipID.uuidString)|\(row.position)"
        var replacementIDs = pendingReplacementIDsByLocation[locationKey] ?? []
        replacementIDs.removeAll { $0 == attachmentID }
        replacementIDs.append(replacementAttachmentID)
        pendingReplacementIDsByLocation[locationKey] = Array(Set(replacementIDs)).sorted {
          $0.uuidString < $1.uuidString
        }
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
        let locationKey = "\(row.snipID.uuidString)|\(row.position)"
        let replacementAttachmentID = pendingReplacementIDsByLocation[locationKey]?.first(where: {
          $0 != attachmentID
        })
        insertCleanup(
          identity: row.payloadIdentity,
          shadowData: row.payloadShadowData,
          blockedByAttachmentID: replacementAttachmentID
        )
        removeCache(for: attachmentID)
        context.delete(row)
        byAttachment.removeValue(forKey: attachmentID)
      case .metadataDeleteConflict(
        let attachmentID,
        let expected,
        let shadow,
        let systemFields,
        let payloadIdentity
      ):
        guard let row = byAttachment[attachmentID], row.revision == expected,
          !row.isLocallyPresent
        else { throw CloudAttachmentStorageError.staleTransition }
        if row.payloadIdentity != payloadIdentity {
          insertCleanup(identity: row.payloadIdentity, shadowData: row.payloadShadowData)
          removeCache(for: attachmentID)
          row.payloadZoneName = payloadIdentity.zoneName
          row.payloadOwnerName = payloadIdentity.ownerName
          row.payloadRecordName = payloadIdentity.recordName
          row.payloadShadowData = nil
          row.payloadSystemFields = nil
        }
        row.payloadAccepted = true
        row.metadataAccepted = true
        row.metadataShadowData = shadow
        row.metadataSystemFields = systemFields
        row.lastFailure = nil
        row.revision += 1
      case .remoteMetadataDeleted(let metadataIdentity):
        guard let row = byMetadataIdentity[metadataIdentity]
        else { continue }
        insertCleanup(identity: row.payloadIdentity, shadowData: row.payloadShadowData)
        removeCache(for: row.attachmentID)
        removeMaterialized(attachmentID: row.attachmentID, snipID: row.snipID)
        context.delete(row)
        byAttachment.removeValue(forKey: row.attachmentID)
      case .cleanupAccepted(let identity, let expected):
        guard let row = byCleanup[identity] else { continue }
        guard row.revision == expected else { throw CloudAttachmentStorageError.staleTransition }
        context.delete(row)
      case .cleanupConflict(let identity, let expected, let shadow):
        guard let row = byCleanup[identity], row.revision == expected else {
          throw CloudAttachmentStorageError.staleTransition
        }
        row.shadowData = shadow
        row.lastFailure = nil
        row.revision += 1
      case .cleanupFailed(let identity, let expected, let failure):
        guard let row = byCleanup[identity], row.revision == expected else {
          throw CloudAttachmentStorageError.staleTransition
        }
        row.lastFailure = failure.rawValue
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
    let acceptedUploadFiles = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    )
      .filter {
        acceptedAttachmentIDs.contains($0.attachmentID)
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
    expectedPayloadIdentity: CloudTextStorageIdentity,
    stagedURL: URL,
    expectedByteCount: Int64,
    expectedSHA256: Data,
    maximumBytes: Int64,
    now: Date
  ) throws -> URL {
    guard maximumBytes >= 0, let container else { throw SnipLibraryError.storeUnavailable }
    guard expectedByteCount <= maximumBytes else {
      throw CloudAttachmentStorageError.sizeMismatch
    }
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
    guard let publication = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    ).first(where: { $0.attachmentID == attachmentID })
    else { throw CloudAttachmentStorageError.missingPublication }
    guard publication.payloadIdentity == expectedPayloadIdentity,
      publication.byteCount == expectedByteCount,
      publication.sha256 == expectedSHA256
    else { throw CloudAttachmentStorageError.staleTransition }
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
    try DurableFile.syncDirectory(destination.deletingLastPathComponent())
    try DurableFile.syncDirectory(filesRoot)
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
      + Self.cloudAttachmentNamespaceDigest(namespaceKey) + "/" + relativePath
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
    for entry in try Self.cloudAttachmentCacheEntries(
      namespaceKey: namespaceKey,
      context: context
    ) { context.delete(entry) }
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
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
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

  /// Removes only direct, unowned upload directories so recovery work stays bounded.
  private func sweepCloudAttachmentUploads(
    namespaceKey: String,
    keeping recordNames: Set<String>
  ) throws {
    let root = try cloudAttachmentUploadRoot(namespaceKey: namespaceKey)
    for child in try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) {
      let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true, values.isDirectory == true,
        recordNames.contains(child.lastPathComponent)
      else {
        try FileManager.default.removeItem(at: child)
        continue
      }
      for item in try FileManager.default.contentsOfDirectory(
        at: child,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      ) where item.lastPathComponent != "payload"
      {
        try FileManager.default.removeItem(at: item)
      }
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
    let publications = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    )
      .filter {
        $0.isLocallyPresent && $0.metadataAccepted
          && $0.sourceRelativePath == nil
      }
    guard !publications.isEmpty else { return }
    let snipIDs = Array(Set(publications.map(\.snipID)))
    let attachmentIDs = Array(Set(publications.map(\.attachmentID)))
    let referenceIDs = publications.map {
      StoredSnipAttachmentReference.identifier(
        snipID: $0.snipID,
        attachmentID: $0.attachmentID
      )
    }
    let storedSnipIDs = Set(try context.fetch(FetchDescriptor<StoredSnipRecord>(
      predicate: #Predicate<StoredSnipRecord> { snipIDs.contains($0.id) }
    )).map(\.id))
    var attachments = Dictionary(uniqueKeysWithValues:
      try context.fetch(FetchDescriptor<StoredAttachmentRecord>(
        predicate: #Predicate<StoredAttachmentRecord> { attachmentIDs.contains($0.id) }
      )).map { ($0.id, $0) }
    )
    var references = Dictionary(uniqueKeysWithValues:
      try context.fetch(FetchDescriptor<StoredSnipAttachmentReference>(
        predicate: #Predicate<StoredSnipAttachmentReference> { referenceIDs.contains($0.id) }
      )).map { ($0.id, $0) }
    )
    let cacheEntries = Dictionary(uniqueKeysWithValues:
      try Self.cloudAttachmentCacheEntries(namespaceKey: namespaceKey, context: context)
        .map { ($0.attachmentID, $0) }
    )
    let namespaceDigest = Self.cloudAttachmentNamespaceDigest(namespaceKey)
    for publication in publications {
      guard storedSnipIDs.contains(publication.snipID) else { continue }
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
      let referenceID = StoredSnipAttachmentReference.identifier(
        snipID: publication.snipID,
        attachmentID: publication.attachmentID
      )
      if let reference = references[referenceID] {
        reference.update(position: publication.position)
      } else {
        let reference = StoredSnipAttachmentReference(
          snipID: publication.snipID,
          attachmentID: publication.attachmentID,
          position: publication.position
        )
        context.insert(reference)
        references[referenceID] = reference
      }
    }
  }

  private func removeMaterializedCloudAttachment(
    attachmentID: UUID,
    snipID: UUID,
    context: ModelContext
  ) throws {
    let references = try Self.storedAttachmentReferences(
      attachmentID: attachmentID,
      context: context
    )
    for reference in references
      where reference.attachmentID == attachmentID && reference.snipID == snipID
    {
      context.delete(reference)
    }
    guard !references.contains(where: {
      $0.attachmentID == attachmentID && $0.snipID != snipID
    }) else { return }
    for attachment in try Self.storedAttachments(
      attachmentID: attachmentID,
      context: context
    ) {
      context.delete(attachment)
    }
  }

  private func removeCloudAttachmentCacheRow(
    namespaceKey: String,
    attachmentID: UUID,
    context: ModelContext
  ) throws {
    for row in try Self.cloudAttachmentCacheEntries(
      namespaceKey: namespaceKey,
      context: context
    ) where row.attachmentID == attachmentID {
      context.delete(row)
    }
  }

  func invalidatedCloudAttachmentCacheFiles(
    namespaceKey: String,
    transitions: [CloudAttachmentTransition],
    context: ModelContext
  ) throws -> [URL] {
    let publications = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    )
    let publicationByAttachment = Dictionary(
      uniqueKeysWithValues: publications.map { ($0.attachmentID, $0) }
    )
    let publicationByMetadataIdentity = Dictionary(
      publications.map { ($0.metadataIdentity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var attachmentIDs: Set<UUID> = []
    for transition in transitions {
      switch transition {
      case .remoteMetadataAccepted(let metadata, _, _, _):
        if let current = publicationByAttachment[metadata.attachmentID],
          current.payloadIdentity != metadata.payloadIdentity
          || current.byteCount != metadata.byteCount || current.sha256 != metadata.sha256
        {
          attachmentIDs.insert(metadata.attachmentID)
        }
      case .metadataDeleteAccepted(let attachmentID, _):
        attachmentIDs.insert(attachmentID)
      case .metadataUnknown(let attachmentID, _, _, _):
        attachmentIDs.insert(attachmentID)
      case .remoteMetadataDeleted(let metadataIdentity):
        if let current = publicationByMetadataIdentity[metadataIdentity] {
          attachmentIDs.insert(current.attachmentID)
        }
      default:
        break
      }
    }
    let root = try cloudAttachmentCacheRoot(namespaceKey: namespaceKey)
    return try Self.cloudAttachmentCacheEntries(
      namespaceKey: namespaceKey,
      context: context
    )
      .filter { attachmentIDs.contains($0.attachmentID) }
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

  private static func cloudAttachmentPublications(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredCloudAttachmentPublication] {
    let key = namespaceKey
    return try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredCloudAttachmentPublication> { $0.namespaceKey == key }
    ))
  }

  private static func cloudAttachmentCleanups(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredCloudAttachmentCleanup] {
    let key = namespaceKey
    return try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredCloudAttachmentCleanup> { $0.namespaceKey == key }
    ))
  }

  private static func cloudAttachmentCacheEntries(
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

  private static func storedAttachmentReferences(
    attachmentID: UUID,
    context: ModelContext
  ) throws -> [StoredSnipAttachmentReference] {
    let id = attachmentID
    return try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredSnipAttachmentReference> { $0.attachmentID == id }
    ))
  }

  private static func safeCloudAttachmentFileName(_ fileName: String) -> String {
    let value = URL(fileURLWithPath: fileName).lastPathComponent
    return value.isEmpty || value == "." || value == ".."
      ? String(localized: LocalizedStringResource.attachmentGenericName)
      : value
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
