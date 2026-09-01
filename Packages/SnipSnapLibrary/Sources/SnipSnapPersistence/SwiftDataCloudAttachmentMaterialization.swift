import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
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
    let namespaceDigest = CloudAttachmentCacheFiles.namespaceDigest(namespaceKey)
    for publication in publications {
      guard storedSnipIDs.contains(publication.snipID) else { continue }
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
}
