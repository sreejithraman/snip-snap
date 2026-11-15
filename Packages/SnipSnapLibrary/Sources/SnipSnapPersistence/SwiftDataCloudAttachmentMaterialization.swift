import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  package func materializeCloudAttachments(
    namespaceKey: String,
    adoptedBases: [UUID: CloudAttachmentMetadataValue],
    context: ModelContext
  ) throws {
    let publications = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey,
      context: context
    )
      .filter {
        $0.lifecycle.materializesFromCloud
          || ($0.lifecycle.isLocallyPresent && $0.lifecycle.isMetadataAccepted
            && adoptedBases[$0.attachmentID] != nil)
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
    let namespaceDigest = CloudAttachmentCacheFiles.namespaceDigest(namespaceKey)
    var writtenReferenceIDs: Set<String> = []
    var touchedSnipIDs: Set<UUID> = []
    for publication in publications {
      guard storedSnipIDs.contains(publication.snipID) else { continue }
      let referenceID = StoredSnipAttachmentReference.identifier(
        snipID: publication.snipID,
        attachmentID: publication.attachmentID
      )
      if let base = adoptedBases[publication.attachmentID],
        let stored = attachments[publication.attachmentID],
        let reference = references[referenceID]
      {
        if stored.fileName == base.fileName {
          stored.fileName = publication.fileName
        }
        if stored.contentType == base.contentType {
          stored.contentType = publication.contentType
        }
        if reference.position == base.position {
          reference.update(position: publication.position)
          writtenReferenceIDs.insert(referenceID)
          touchedSnipIDs.insert(publication.snipID)
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
        writtenReferenceIDs.insert(referenceID)
        touchedSnipIDs.insert(publication.snipID)
      }
    }
    guard !touchedSnipIDs.isEmpty else { return }
    let affectedSnipIDs = Array(touchedSnipIDs)
    let affectedReferences = try context.fetch(FetchDescriptor<StoredSnipAttachmentReference>(
      predicate: #Predicate<StoredSnipAttachmentReference> { affectedSnipIDs.contains($0.snipID) }
    ))
    for snipReferences in Dictionary(grouping: affectedReferences, by: \.snipID).values {
      let ordered = snipReferences.sorted { lhs, rhs in
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        // Local positions win ties with adopted positions; attachment IDs settle other ties.
        let lhsWasWritten = writtenReferenceIDs.contains(lhs.id)
        let rhsWasWritten = writtenReferenceIDs.contains(rhs.id)
        if lhsWasWritten != rhsWasWritten { return !lhsWasWritten }
        return lhs.attachmentID.uuidString < rhs.attachmentID.uuidString
      }
      for (position, reference) in ordered.enumerated() where reference.position != position {
        reference.update(position: position)
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
