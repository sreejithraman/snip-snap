import Foundation
import SnipSnapCore
import SwiftData

/// Evidence of an accepted pointer delete and the cleanup authority of its original publication.
/// The enclosing setup history supplies the account and collection generation.
package struct CloudSetupPointerDelete: Codable, Equatable, Sendable {
  package struct Key: Codable, Hashable, Sendable {
    package let batchID: UUID
    package let pointer: CloudTextStorageIdentity

    package init(batchID: UUID, pointer: CloudTextStorageIdentity) {
      self.batchID = batchID
      self.pointer = pointer
    }
  }

  struct Payload: Codable, Equatable, Sendable {
    let identity: CloudTextStorageIdentity
    let shadowData: Data?
  }

  package let key: Key
  let bindingDigest: Data
  package let snipID: UUID
  let payloads: [Payload]

  func isValid(in namespace: ICloudSyncNamespaceBinding) -> Bool {
    namespace.contains(key.pointer) && bindingDigest.count == 32
      && CloudSetupRetryRecordKey(
        reference: CloudEntityReference(kind: .snip, domainID: snipID), identity: key.pointer
      ).attachmentID != nil
      && payloads.allSatisfy {
        namespace.contains($0.identity) && ($0.identity.zoneName != key.pointer.zoneName
          || $0.identity.ownerName != key.pointer.ownerName)
      }
      && Set(payloads.map(\.identity)).count == payloads.count
  }
}

extension SwiftDataSnipLibrary {
  func setupPointerDelete(
    namespaceKey: CloudSyncNamespaceKey,
    key: CloudSetupPointerDelete.Key,
    attachmentID: UUID,
    expectedRevision: UInt64,
    bindingDigest: Data,
    metadataShadowData: Data?
  ) throws -> CloudSetupPointerDelete {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    guard let row = try Self.cloudAttachmentPublications(
      namespaceKey: namespaceKey.rawValue, context: context
    ).first(where: {
      $0.attachmentID == attachmentID && $0.metadataIdentity == key.pointer
        && $0.metadataShadowData == metadataShadowData
    })
    else { throw CloudAttachmentStorageError.staleTransition }
    let owed = try row.lifecycle.acceptMetadataDeletion(expectedRevision: expectedRevision)
    let payloads = owed.map {
      CloudSetupPointerDelete.Payload(identity: $0.identity, shadowData: $0.shadowData)
    }.sorted { $0.identity.key < $1.identity.key }
    return CloudSetupPointerDelete(
      key: key, bindingDigest: bindingDigest, snipID: row.snipID, payloads: payloads
    )
  }

  func installSetupPointerDeleteCleanups(
    _ receipts: [CloudSetupPointerDelete], namespaceKey: CloudSyncNamespaceKey
  ) throws {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    var queue = try CloudAttachmentCleanupQueue(namespaceKey: namespaceKey.rawValue, context: context)
    for receipt in receipts {
      for payload in receipt.payloads {
        queue.queue(CloudAttachmentOwedCleanup(identity: payload.identity, shadowData: payload.shadowData))
      }
    }
    try afterMutationBeforeSave()
    try lock.check()
    try context.save()
  }
}
