import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
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
    namespaceKey: CloudSyncNamespaceKey,
    transitions: [CloudAttachmentTransition]
  ) throws {
    let namespaceKey = namespaceKey.rawValue
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
      CloudAttachmentCacheFiles.remove(file, includingParentDirectory: true)
    }
    for file in invalidatedCacheFiles {
      CloudAttachmentCacheFiles.remove(file, includingParentDirectory: true)
    }
  }

}
