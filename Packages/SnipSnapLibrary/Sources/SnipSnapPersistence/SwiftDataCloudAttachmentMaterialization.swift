import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  /// Shows fetched attachments on their snips, then merges the order of every snip another
  /// device's change touched. This device's own acknowledgements touch no snip (ADR 0028).
  func materializeCloudAttachments(
    namespaceKey: String,
    changes: CloudAttachmentRemoteChanges,
    acknowledgedValues: CloudAttachmentAcknowledgedValues,
    context: ModelContext
  ) throws {
    let adoptions = changes.adoptions
    let allPublications = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    )
    let publications = allPublications.filter {
      $0.lifecycle.materializesFromCloud
        || ($0.lifecycle.isLocallyPresent && adoptions[$0.attachmentID] != nil)
    }
    let snipIDs = Array(Set(publications.map(\.snipID)).union(changes.removedSnipIDs))
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
    var touchedSnipIDs = Set(
      publications.filter { adoptions[$0.attachmentID] != nil }.map(\.snipID)
    ).union(changes.removedSnipIDs)
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
      if let adoption = adoptions[publication.attachmentID], let base = adoption.base,
        let stored = attachments[publication.attachmentID],
        references[referenceID] != nil
      {
        let fileName = CloudAttachmentMerge.field(
          base: base.fileName, local: stored.fileName, remote: adoption.record.fileName
        )
        if stored.fileName != fileName { stored.fileName = fileName }
        let contentType = CloudAttachmentMerge.field(
          base: base.contentType, local: stored.contentType, remote: adoption.record.contentType
        )
        if stored.contentType != contentType { stored.contentType = contentType }
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
        touchedSnipIDs.insert(publication.snipID)
      }
    }
    let presentRows = Dictionary(uniqueKeysWithValues:
      allPublications.filter { $0.lifecycle.isLocallyPresent }.map { ($0.attachmentID, $0) }
    )
    let membersBySnip = Dictionary(grouping: references.values, by: \.snipID)
    for snipID in touchedSnipIDs {
      let members = membersBySnip[snipID] ?? []
      let localOrder = localOrdersBySnip[snipID] ?? []
      var basePositions: [UUID: Int] = [:]
      var remotePositions: [UUID: Int] = [:]
      for member in members {
        guard let row = presentRows[member.attachmentID], row.snipID == snipID else { continue }
        if let adoption = adoptions[row.attachmentID] {
          basePositions[row.attachmentID] = adoption.base?.position
          remotePositions[row.attachmentID] = adoption.record.position
        } else if let acknowledged = row.acknowledgedMetadata(acknowledgedValues) {
          basePositions[row.attachmentID] = acknowledged.position
          remotePositions[row.attachmentID] = acknowledged.position
        }
      }
      let order = CloudAttachmentMerge.order(
        local: localOrder,
        arrived: members.map(\.attachmentID).filter { !localOrder.contains($0) },
        base: basePositions,
        remote: remotePositions
      )
      // Stored positions are local order; the shadows hold the cloud coordinates.
      for (position, attachmentID) in order.enumerated() {
        let referenceID = StoredSnipAttachmentReference.identifier(
          snipID: snipID, attachmentID: attachmentID
        )
        if let reference = references[referenceID], reference.position != position {
          reference.update(position: position)
        }
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
