import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  package func materializeCloudAttachments(
    namespaceKey: String,
    adoptedBases: [UUID: CloudAttachmentMetadataValue],
    metadataAcknowledgedAttachmentIDs: Set<UUID>,
    context: ModelContext
  ) throws {
    let allPublications = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    )
    let publications = allPublications.filter {
      $0.lifecycle.materializesFromCloud
        || ($0.lifecycle.isLocallyPresent && $0.lifecycle.isMetadataAccepted
          && adoptedBases[$0.attachmentID] != nil)
    }
    let metadataAcknowledgedSnipIDs = Set(allPublications.filter {
      metadataAcknowledgedAttachmentIDs.contains($0.attachmentID)
    }.map(\.snipID))
    let snipIDs = Array(Set(publications.map(\.snipID)).union(metadataAcknowledgedSnipIDs))
    guard !snipIDs.isEmpty else { return }
    let attachmentIDs = Array(Set(publications.map(\.attachmentID)))
    let storedSnipIDs = Set(try context.fetch(FetchDescriptor<StoredSnipRecord>(
      predicate: #Predicate<StoredSnipRecord> { snipIDs.contains($0.id) }
    )).map(\.id))
    var attachments = Dictionary(uniqueKeysWithValues:
      try context.fetch(FetchDescriptor<StoredAttachmentRecord>(
        predicate: #Predicate<StoredAttachmentRecord> { attachmentIDs.contains($0.id) }
      )).map { ($0.id, $0) }
    )
    let storedReferences = try context.fetch(FetchDescriptor<StoredSnipAttachmentReference>(
      predicate: #Predicate<StoredSnipAttachmentReference> { snipIDs.contains($0.snipID) }
    ))
    let localOrdersBySnip = Dictionary(grouping: storedReferences, by: \.snipID).mapValues {
      $0.sorted { lhs, rhs in
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        return lhs.attachmentID.uuidString < rhs.attachmentID.uuidString
      }.map(\.attachmentID)
    }
    var references = Dictionary(uniqueKeysWithValues: storedReferences.map { ($0.id, $0) })
    let presentRowsBySnip = Dictionary(
      grouping: allPublications.filter { $0.lifecycle.isLocallyPresent }, by: \.snipID
    )
    var adoptedOrInsertedSnipIDs = Set(
      publications.filter { adoptedBases[$0.attachmentID] != nil }.map(\.snipID)
    )
    let cacheEntries = Dictionary(uniqueKeysWithValues:
      try Self.cloudAttachmentCacheEntries(namespaceKey: namespaceKey, context: context)
        .map { ($0.attachmentID, $0) }
    )
    let namespaceDigest = CloudAttachmentCacheFiles.namespaceDigest(namespaceKey)
    for publication in publications {
      guard storedSnipIDs.contains(publication.snipID) else { continue }
      let referenceID = StoredSnipAttachmentReference.identifier(
        snipID: publication.snipID,
        attachmentID: publication.attachmentID
      )
      if let base = adoptedBases[publication.attachmentID],
        let stored = attachments[publication.attachmentID],
        references[referenceID] != nil
      {
        if stored.fileName == base.fileName {
          stored.fileName = publication.fileName
        }
        if stored.contentType == base.contentType {
          stored.contentType = publication.contentType
        }
      }
      guard publication.lifecycle.materializesFromCloud else { continue }
      let relativePath: String
      if let cache = cacheEntries[publication.attachmentID],
        cache.payloadIdentity == publication.payloadIdentity
      {
        relativePath = "CloudDownloads/\(namespaceDigest)/\(cache.relativePath)"
      } else {
        relativePath = CloudAttachmentCacheFiles.cacheRelativePath(
          namespaceKey: namespaceKey,
          attachmentID: publication.attachmentID,
          fileName: publication.fileName
        )
      }
      if let stored = attachments[publication.attachmentID] {
        stored.relativePath = relativePath
        stored.byteCount = publication.byteCount
      } else {
        let stored = StoredAttachmentRecord(SnipAttachment(
          id: publication.attachmentID,
          fileName: publication.fileName,
          relativePath: relativePath,
          contentType: publication.contentType,
          byteCount: publication.byteCount
        ))
        context.insert(stored)
        attachments[publication.attachmentID] = stored
      }
      if references[referenceID] == nil {
        let reference = StoredSnipAttachmentReference(
          snipID: publication.snipID,
          attachmentID: publication.attachmentID,
          position: publication.position
        )
        context.insert(reference)
        references[referenceID] = reference
        adoptedOrInsertedSnipIDs.insert(publication.snipID)
      }
    }
    let touchedSnipIDs = metadataAcknowledgedSnipIDs.union(adoptedOrInsertedSnipIDs)
    // Adoptions and inserts compare shared order, acknowledgement-only restores require the whole
    // list to match, and pending published edits block both.
    let snipsAdoptingOrder = Set(touchedSnipIDs.filter { snipID in
      let presentRows = presentRowsBySnip[snipID] ?? []
      guard !presentRows.contains(where: {
        $0.lifecycle.isPresentAwaitingMetadata && $0.lifecycle.hasPublishedMetadata
      }) else {
        return false
      }
      let localOrder = localOrdersBySnip[snipID] ?? []
      let baseOrder = presentRows.sorted { lhs, rhs in
        let lhsPosition = adoptedBases[lhs.attachmentID]?.position ?? lhs.position
        let rhsPosition = adoptedBases[rhs.attachmentID]?.position ?? rhs.position
        if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
        return lhs.attachmentID.uuidString < rhs.attachmentID.uuidString
      }.map(\.attachmentID)
      if !adoptedOrInsertedSnipIDs.contains(snipID) { return localOrder == baseOrder }
      let sharedIDs = Set(localOrder).intersection(baseOrder)
      return localOrder.filter { sharedIDs.contains($0) }
        == baseOrder.filter { sharedIDs.contains($0) }
    })
    for snipID in snipsAdoptingOrder {
      for row in presentRowsBySnip[snipID] ?? [] {
        let referenceID = StoredSnipAttachmentReference.identifier(
          snipID: snipID, attachmentID: row.attachmentID
        )
        references[referenceID]?.update(position: row.position)
      }
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
    return try Self.cloudAttachmentCacheEntries(
      namespaceKey: namespaceKey,
      context: context
    )
      .filter { attachmentIDs.contains($0.attachmentID) }
      .compactMap {
        try? cloudAttachmentCacheFileURL(
          relativePath: $0.relativePath,
          namespaceKey: namespaceKey
        )
      }
  }
}
