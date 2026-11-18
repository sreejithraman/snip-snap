import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  func applyCloudAttachmentTransitions(
    namespaceKey: String,
    transitions: [CloudAttachmentTransition],
    resolveMetadata: CloudAttachmentMetadataRebase.Resolve? = nil,
    context: ModelContext
  ) throws -> Set<UUID> {
    guard !transitions.isEmpty else { return [] }
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
    var materializedAttachmentIDs: Set<UUID> = []
    var fetchedOrderSnips: Set<UUID> = []
    var fetchedMetadata: [UUID: CloudAttachmentMetadataValue] = [:]
    var fetchedDeletions: Set<UUID> = []
    var legacyOrderSnips: Set<UUID> = []
    for transition in transitions {
      switch transition {
      case .remoteMetadataAccepted(let metadata, let identity, let shadow, _) where resolveMetadata != nil:
        materializedAttachmentIDs.insert(metadata.attachmentID)
        let row = byAttachment[metadata.attachmentID]
        guard case .fetched(let base)? = resolveMetadata?(identity, row?.metadataShadowData, shadow) else {
          continue
        }
        fetchedMetadata[metadata.attachmentID] = metadata
        if let row, let base,
          row.lifecycle.isPayloadAccepted,
          row.metadata.namesSamePayload(as: metadata), base.namesSamePayload(as: metadata)
        {
          if base.position != metadata.position { fetchedOrderSnips.insert(metadata.snipID) }
        } else {
          legacyOrderSnips.insert(metadata.snipID)
          if let row { legacyOrderSnips.insert(row.snipID) }
        }
      case .metadataConflict(let attachmentID, _, _, _) where resolveMetadata != nil:
        materializedAttachmentIDs.insert(attachmentID)
      case .metadataUnknown(let attachmentID, _, let replacementAttachmentID, _):
        materializedAttachmentIDs.insert(attachmentID)
        materializedAttachmentIDs.insert(replacementAttachmentID)
      case .remoteMetadataDeleted(let metadataIdentity):
        if let row = byMetadataIdentity[metadataIdentity] {
          materializedAttachmentIDs.insert(row.attachmentID)
          if case .fetched? = resolveMetadata?(metadataIdentity, row.metadataShadowData, nil) {
            fetchedOrderSnips.insert(row.snipID)
            fetchedDeletions.insert(row.attachmentID)
          }
        }
      default:
        break
      }
    }
    let materializedIDs = Array(materializedAttachmentIDs)
    let orderSnipIDs = Array(fetchedOrderSnips.union(legacyOrderSnips))
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
          materializedIDs.contains($0.attachmentID) || orderSnipIDs.contains($0.snipID)
        }
      ))
    }
    if let resolveMetadata, !orderSnipIDs.isEmpty {
      applyFetchedAttachmentOrder(
        snipIDs: Set(orderSnipIDs),
        publications: publications,
        references: storedReferenceRows,
        fetchedMetadata: fetchedMetadata,
        deletedAttachmentIDs: fetchedDeletions,
        legacyOrderSnips: legacyOrderSnips,
        resolveMetadata: resolveMetadata
      )
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
    var refreshedAttachmentIDs: Set<UUID> = []

    func liveAttachment(
      for row: StoredCloudAttachmentPublication
    ) -> (StoredAttachmentRecord, StoredSnipAttachmentReference)? {
      guard let attachment = storedAttachments[row.attachmentID]?.first,
        let reference = storedReferences[row.attachmentID]?.first(where: { $0.snipID == row.snipID }),
        attachment.byteCount == row.byteCount
      else { return nil }
      if let source = row.lifecycle.localSourceRelativePath {
        guard attachment.relativePath == source else { return nil }
      } else {
        guard attachment.relativePath.hasPrefix("CloudDownloads/") else { return nil }
      }
      return (attachment, reference)
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
          if case .fetched(let base?)? = resolveMetadata?(metadataIdentity, row.metadataShadowData, shadow),
            row.lifecycle.isPayloadAccepted,
            row.metadata.namesSamePayload(as: metadata), base.namesSamePayload(as: metadata)
          {
            if let (attachment, reference) = liveAttachment(for: row) {
              let ownsSource = row.lifecycle.localSourceRelativePath != nil
              // A pending local-source row can be undoing a save whose result was lost.
              let preservesLocalName = ownsSource
                && (!row.lifecycle.isMetadataAccepted || attachment.fileName != base.fileName)
              if !preservesLocalName, attachment.fileName == base.fileName || metadata.fileName != base.fileName {
                attachment.fileName = metadata.fileName
              }
              row.fileName = attachment.fileName
              row.position = reference.position
              if !ownsSource, metadata.contentType != base.contentType {
                attachment.contentType = metadata.contentType
              }
              row.contentType = attachment.contentType
            } else {
              row.position = metadata.position
              row.fileName = metadata.fileName
              row.contentType = metadata.contentType
            }
            row.lifecycle.acceptRemoteMetadata(
              payloadIdentity: metadata.payloadIdentity,
              metadataRecord: metadataRecord
            )
            if row.metadata != metadata { row.lifecycle.editMetadataLocally() }
            continue
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
          refreshedAttachmentIDs.insert(metadata.attachmentID)
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
          refreshedAttachmentIDs.insert(metadata.attachmentID)
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
        let priorShadow = row.metadataShadowData
        try row.lifecycle.recordMetadataConflict(
          CloudAttachmentAcceptedRecord(shadowData: shadow, systemFields: systemFields),
          expectedRevision: expected
        )
        // This transition also advances the shadow for an acknowledged save superseded locally.
        // Only an actual server conflict rebases live fields.
        if case .conflict(let base, let prior, let sent, let server)? = resolveMetadata?(
          row.metadataIdentity, priorShadow, shadow
        ),
          row.lifecycle.isPayloadAccepted,
          row.metadata.namesSamePayload(as: server), base.namesSamePayload(as: server),
          sent.namesSamePayload(as: server),
          let (attachment, reference) = liveAttachment(for: row)
        {
          let priorName = prior.flatMap { $0.namesSamePayload(as: server) ? $0.fileName : nil } ?? base.fileName
          // A newer shadow can explain a live name that differs from the frozen draft.
          if attachment.fileName == priorName,
            attachment.fileName == sent.fileName || priorName != base.fileName
          {
            attachment.fileName = server.fileName
          }
          row.fileName = attachment.fileName
          row.position = reference.position
        }
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
          expectedRevision: expected
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
    return refreshedAttachmentIDs
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
    let refreshedAttachmentIDs = try applyCloudAttachmentTransitions(
      namespaceKey: namespaceKey,
      transitions: transitions,
      context: context
    )
    try materializeCloudAttachments(
      namespaceKey: namespaceKey,
      refreshedAttachmentIDs: refreshedAttachmentIDs,
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

private extension CloudAttachmentMetadataValue {
  func namesSamePayload(as other: Self) -> Bool {
    attachmentID == other.attachmentID && snipID == other.snipID
      && payloadIdentity == other.payloadIdentity && byteCount == other.byteCount
      && sha256 == other.sha256
  }
}

private extension SwiftDataSnipLibrary {
  func applyFetchedAttachmentOrder(
    snipIDs: Set<UUID>,
    publications: [StoredCloudAttachmentPublication],
    references: [StoredSnipAttachmentReference],
    fetchedMetadata: [UUID: CloudAttachmentMetadataValue],
    deletedAttachmentIDs: Set<UUID>,
    legacyOrderSnips: Set<UUID>,
    resolveMetadata: CloudAttachmentMetadataRebase.Resolve
  ) {
    let publicationsBySnip = Dictionary(grouping: publications.filter {
      snipIDs.contains($0.snipID) && !deletedAttachmentIDs.contains($0.attachmentID)
    }, by: \.snipID)
    let referencesBySnip = Dictionary(grouping: references.filter {
      snipIDs.contains($0.snipID) && !deletedAttachmentIDs.contains($0.attachmentID)
    }, by: \.snipID)
    for (snipID, references) in referencesBySnip {
      let publications = publicationsBySnip[snipID] ?? []
      let rows = Dictionary(uniqueKeysWithValues: publications.map { ($0.attachmentID, $0) })
      let publishedMetadata = publications.compactMap { row -> (UUID, CloudAttachmentMetadataValue)? in
        guard row.lifecycle.isPayloadAccepted,
          case .fetched(let base?)? = resolveMetadata(row.metadataIdentity, row.metadataShadowData, nil),
          base.namesSamePayload(as: row.metadata)
        else { return nil }
        return (row.attachmentID, base)
      }
      let previous = Dictionary(uniqueKeysWithValues: publishedMetadata)
      guard !legacyOrderSnips.contains(snipID), previous.count == publications.count,
        references.allSatisfy({ previous[$0.attachmentID] != nil })
      else {
        // New or replaced payloads still use the existing cached order rules.
        for reference in references {
          guard let row = rows[reference.attachmentID], row.lifecycle.localSourceRelativePath == nil else {
            continue
          }
          if let metadata = fetchedMetadata[reference.attachmentID], metadata.snipID == snipID {
            reference.update(position: metadata.position)
          } else if row.lifecycle.materializesFromCloud {
            reference.update(position: row.position)
          }
        }
        continue
      }
      var remote = previous.mapValues(\.position)
      for id in previous.keys {
        if let metadata = fetchedMetadata[id] { remote[id] = metadata.position }
      }
      let complete = Set(remote.values) == Set(0..<remote.count)
      let localOrderChanged = references.contains { previous[$0.attachmentID]?.position != $0.position }
      let hasOnePendingAttachment = previous.count == references.count
        && Set(previous.values.map(\.position)) == Set(0..<previous.count)
        && publications.filter { !$0.lifecycle.isMetadataAccepted }.count == 1
      let ownerKeepsOrder = references.contains { reference in
        let id = reference.attachmentID
        guard let row = rows[id], row.lifecycle.localSourceRelativePath != nil,
          let base = previous[id]
        else {
          return false
        }
        if !complete || base.position != reference.position { return true }
        // An undo of an unacknowledged reorder can leave several attachments pending at their old ranks.
        let queuedRename = hasOnePendingAttachment && row.position == base.position && row.fileName != base.fileName
          && row.contentType == base.contentType
        return !row.lifecycle.isMetadataAccepted && !queuedRename && remote[id] != reference.position
      }
      // Keep the existing cache behavior for a partial fetch with no overlapping local order.
      guard !ownerKeepsOrder, complete || !localOrderChanged else { continue }
      for reference in references {
        guard let position = remote[reference.attachmentID] else { continue }
        reference.update(position: position)
      }
    }
  }
}
