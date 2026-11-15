import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  package func applyCloudAttachmentTransitions(
    namespaceKey: String,
    transitions: [CloudAttachmentTransition],
    context: ModelContext
  ) throws -> [UUID: CloudAttachmentMetadataValue] {
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
    var cleanupQueue = try CloudAttachmentCleanupQueue(
      namespaceKey: namespaceKey,
      context: context
    )
    var adoptedBases: [UUID: CloudAttachmentMetadataValue] = [:]
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
      grouping: publications.filter { $0.lifecycle.isPresentAwaitingMetadata },
      by: { "\($0.snipID.uuidString)|\($0.position)" }
    ).mapValues { rows in
      rows.map(\.attachmentID).sorted { $0.uuidString < $1.uuidString }
    }
    func removeCache(for attachmentID: UUID) {
      for row in cacheByAttachment.removeValue(forKey: attachmentID) ?? [] {
        context.delete(row)
      }
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
    /// Drops a publication another device deleted, with its download and its place on the snip.
    /// Queues no payload cleanup.
    func removeRemotelyDeleted(_ row: StoredCloudAttachmentPublication) {
      removeCache(for: row.attachmentID)
      removeMaterialized(attachmentID: row.attachmentID, snipID: row.snipID)
      context.delete(row)
      byAttachment.removeValue(forKey: row.attachmentID)
    }
    for transition in transitions {
      switch transition {
      case .remoteMetadataAccepted(
        let metadata,
        let metadataIdentity,
        let shadow,
        let systemFields
      ):
        let metadataRecord = CloudAttachmentAcceptedRecord(
          shadowData: shadow,
          systemFields: systemFields
        )
        if let row = byAttachment[metadata.attachmentID] {
          if row.lifecycle.hasAcceptedMetadata(metadataRecord) { continue }
          guard row.metadataIdentity == metadataIdentity else {
            throw CloudAttachmentStorageError.staleTransition
          }
          if row.metadata != metadata,
            row.lifecycle.keepsUnsentEdit(againstRecordNaming: metadata.payloadIdentity)
          {
            row.lifecycle.adoptBase(metadataRecord)
            continue
          }
          if row.lifecycle.isLocallyPresent && row.lifecycle.isMetadataAccepted {
            adoptedBases[metadata.attachmentID] = adoptedBases[metadata.attachmentID] ?? row.metadata
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
          row.lifecycle.acceptRemoteMetadata(
            payloadIdentity: metadata.payloadIdentity,
            metadataRecord: metadataRecord
          )
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
          row.lifecycle = .remoteAttachment(
            payloadIdentity: metadata.payloadIdentity,
            metadataRecord: metadataRecord
          )
          context.insert(row)
        }
      case .payloadAccepted(let attachmentID, let expected, let shadow, let systemFields):
        guard let row = byAttachment[attachmentID] else {
          throw CloudAttachmentStorageError.missingPublication
        }
        try row.lifecycle.acceptPayload(
          CloudAttachmentAcceptedRecord(shadowData: shadow, systemFields: systemFields),
          expectedRevision: expected
        )
      case .metadataAccepted(let attachmentID, let expected, let shadow, let systemFields):
        guard let row = byAttachment[attachmentID] else {
          throw CloudAttachmentStorageError.missingPublication
        }
        if let owedCleanup = try row.lifecycle.acceptMetadata(
          CloudAttachmentAcceptedRecord(shadowData: shadow, systemFields: systemFields),
          expectedRevision: expected
        ) {
          cleanupQueue.queue(owedCleanup)
        }
      case .metadataConflict(let attachmentID, let expected, let shadow, let systemFields):
        guard let row = byAttachment[attachmentID] else {
          throw CloudAttachmentStorageError.staleTransition
        }
        try row.lifecycle.recordMetadataConflict(
          CloudAttachmentAcceptedRecord(shadowData: shadow, systemFields: systemFields),
          expectedRevision: expected
        )
      case .payloadCollision(let attachmentID, let expected, let replacementIdentity):
        guard let row = byAttachment[attachmentID] else {
          throw CloudAttachmentStorageError.staleTransition
        }
        try row.lifecycle.adoptCollisionReplacement(
          replacementIdentity,
          expectedRevision: expected
        )
      case .metadataUnknown(
        let attachmentID,
        let expected,
        let replacementAttachmentID,
        let replacementMetadataIdentity
      ):
        guard let row = byAttachment[attachmentID],
          replacementAttachmentID != attachmentID,
          replacementMetadataIdentity.zoneName == row.metadataZoneName,
          replacementMetadataIdentity.ownerName == row.metadataOwnerName,
          replacementMetadataIdentity.recordName
            == "a-\(replacementAttachmentID.uuidString.lowercased())"
        else {
          throw CloudAttachmentStorageError.staleTransition
        }
        let replacementLifecycle = try row.lifecycle.remappedReplacement(
          expectedRevision: expected,
          freshPayload: CloudTextStorageIdentity(
            zoneName: row.payloadIdentity.zoneName,
            ownerName: row.payloadIdentity.ownerName,
            recordName: UUID().uuidString.lowercased()
          )
        )
        guard byAttachment[replacementAttachmentID] == nil,
          !storedAttachments.keys.contains(replacementAttachmentID)
        else {
          throw CloudAttachmentStorageError.staleTransition
        }
        guard row.lifecycle.republishesUnknownMetadata else {
          // The device that deleted it owns the payload's cleanup.
          removeRemotelyDeleted(row)
          continue
        }
        for cleanup in row.lifecycle.payloadCleanupsAfterMetadataDeletion {
          cleanupQueue.queue(cleanup, blockedBy: replacementAttachmentID)
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
          sourceRelativePath: replacementLifecycle.localSourceRelativePath,
          metadataIdentity: replacementMetadataIdentity,
          payloadIdentity: replacementLifecycle.payloadIdentity
        )
        replacement.lifecycle = replacementLifecycle
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
        cleanupQueue.remapBlockers(from: attachmentID, to: replacementAttachmentID)
      case .operationFailed(let attachmentID, let expected, let failure):
        guard let row = byAttachment[attachmentID] else {
          throw CloudAttachmentStorageError.staleTransition
        }
        try row.lifecycle.recordFailure(failure, expectedRevision: expected)
      case .metadataDeleteAccepted(let attachmentID, let expected):
        guard let row = byAttachment[attachmentID] else {
          throw CloudAttachmentStorageError.staleTransition
        }
        let owedCleanups = try row.lifecycle.acceptMetadataDeletion(expectedRevision: expected)
        let locationKey = "\(row.snipID.uuidString)|\(row.position)"
        let replacementAttachmentID = pendingReplacementIDsByLocation[locationKey]?.first(where: {
          $0 != attachmentID
        })
        for cleanup in owedCleanups {
          cleanupQueue.queue(cleanup, blockedBy: replacementAttachmentID)
        }
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
        guard let row = byAttachment[attachmentID] else {
          throw CloudAttachmentStorageError.staleTransition
        }
        if let owedCleanup = try row.lifecycle.recordMetadataDeletionConflict(
          CloudAttachmentAcceptedRecord(shadowData: shadow, systemFields: systemFields),
          payloadIdentity: payloadIdentity,
          expectedRevision: expected
        ) {
          cleanupQueue.queue(owedCleanup)
          removeCache(for: attachmentID)
        }
      case .remoteMetadataDeleted(let metadataIdentity):
        guard let row = byMetadataIdentity[metadataIdentity]
        else { continue }
        cleanupQueue.queue(row.lifecycle.payloadCleanup)
        for cleanup in row.lifecycle.payloadCleanupsAfterMetadataDeletion {
          cleanupQueue.queue(cleanup)
        }
        removeRemotelyDeleted(row)
      case .cleanupAccepted(let identity, let expected):
        try cleanupQueue.acceptDeletion(of: identity, expectedRevision: expected)
      case .cleanupConflict(let identity, let expected, let shadow):
        try cleanupQueue.recordConflict(
          for: identity,
          shadowData: shadow,
          expectedRevision: expected
        )
      case .cleanupFailed(let identity, let expected, let failure):
        try cleanupQueue.recordFailure(failure, for: identity, expectedRevision: expected)
      }
    }
    return adoptedBases
  }

  package func commitCloudAttachmentTransitions(
    namespaceKey: CloudSyncNamespaceKey,
    transitions: [CloudAttachmentTransition],
    afterSave: @Sendable () -> Void = {}
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
        try row.lifecycle.queuedUploadRelativePath.map {
          try Self.validatedChild(relativePath: $0, root: uploadRoot)
        }
      }
    let invalidatedCacheFiles = try invalidatedCloudAttachmentCacheFiles(
      namespaceKey: namespaceKey,
      transitions: transitions,
      context: context
    )
    let adoptedBases = try applyCloudAttachmentTransitions(
      namespaceKey: namespaceKey,
      transitions: transitions,
      context: context
    )
    try materializeCloudAttachments(
      namespaceKey: namespaceKey,
      adoptedBases: adoptedBases,
      context: context
    )
    try afterMutationBeforeSave()
    try lock.check()
    try context.save()
    afterSave()
    for file in acceptedUploadFiles + invalidatedCacheFiles {
      if (try? lock.check()) == nil { break }
      CloudAttachmentCacheFiles.remove(file, includingParentDirectory: true)
    }
  }

}
