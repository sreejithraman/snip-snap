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

  package struct Replacement: Codable, Equatable, Sendable {
    package let sha256: Data
    package let byteCount: Int64

    package init(sha256: Data, byteCount: Int64) {
      self.sha256 = sha256
      self.byteCount = byteCount
    }
  }

  package struct Binding: Sendable {
    let key: Key
    let digest: Data
    let metadataShadow: Data?
    package let attachmentID: UUID
    let revision: UInt64?

    package init(key: Key, digest: Data, metadataShadow: Data?, attachmentID: UUID, revision: UInt64?) {
      self.key = key
      self.digest = digest
      self.metadataShadow = metadataShadow
      self.attachmentID = attachmentID
      self.revision = revision
    }
  }

  package struct Deferral: Sendable {
    let receipt: CloudSetupPointerDelete
    let metadataShadow: Data?

    package init(receipt: CloudSetupPointerDelete, metadataShadow: Data?) {
      self.receipt = receipt
      self.metadataShadow = metadataShadow
    }
  }

  package let key: Key
  let bindingDigest: Data
  package let snipID: UUID
  let payloads: [Payload]
  /// Optional on disk for receipts from the initial implementation.
  package let position: Int?
  package let replacements: [Replacement]?
  package var payloadIdentities: Set<CloudTextStorageIdentity> { Set(payloads.map(\.identity)) }

  static func payloads(for owed: [CloudAttachmentOwedCleanup]) -> [Payload] {
    owed.map { Payload(identity: $0.identity, shadowData: $0.shadowData) }
      .sorted { $0.identity.key < $1.identity.key }
  }

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
    binding: CloudSetupPointerDelete.Binding
  ) throws -> CloudSetupPointerDelete {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let publications = try Self.cloudAttachmentPublications(namespaceKey: namespaceKey.rawValue, context: context)
    guard let row = publications.first(where: {
      $0.attachmentID == binding.attachmentID && $0.metadataIdentity == binding.key.pointer
        && $0.metadataShadowData == binding.metadataShadow
    })
    else { throw CloudAttachmentStorageError.staleTransition }
    let lifecycle = row.lifecycle
    // A single failure update advances the revision but preserves the bound publication.
    guard let revision = binding.revision,
      row.revision == revision
        || (row.revision > revision && row.revision - revision == 1 && lifecycle.lastFailure != nil)
    else { throw CloudAttachmentStorageError.staleTransition }
    let owed = try lifecycle.acceptMetadataDeletion(expectedRevision: row.revision)
    let replacements = publications.filter {
      $0.attachmentID != row.attachmentID && $0.snipID == row.snipID
        && $0.position == row.position && $0.lifecycle.isPresentAwaitingMetadata
    }.sorted { $0.attachmentID.uuidString < $1.attachmentID.uuidString }
    return CloudSetupPointerDelete(
      key: binding.key, bindingDigest: binding.digest, snipID: row.snipID,
      payloads: CloudSetupPointerDelete.payloads(for: owed), position: row.position,
      replacements: replacements.map { .init(sha256: $0.sha256, byteCount: $0.byteCount) }
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
