import CryptoKit
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

  private struct LegacyReplacement: Codable, Equatable, Sendable {
    let sha256: Data
    let byteCount: Int64
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
  package private(set) var replacementAttachmentIDs: [UUID]?
  // Older draft receipts retain their evidence but cannot prove a nonempty dependency.
  private var position: Int? = nil
  private var replacements: [LegacyReplacement]? = nil
  package var payloadIdentities: Set<CloudTextStorageIdentity> { Set(payloads.map(\.identity)) }

  init(key: Key, bindingDigest: Data, snipID: UUID, payloads: [Payload], replacementAttachmentIDs: [UUID]) {
    self.key = key
    self.bindingDigest = bindingDigest
    self.snipID = snipID
    self.payloads = payloads
    self.replacementAttachmentIDs = replacementAttachmentIDs
  }

  package var replacementIDs: [UUID]? {
    replacementAttachmentIDs ?? (replacements?.isEmpty == true ? [] : nil)
  }

  mutating func applyReplacementRemaps(_ remaps: [UUID: UUID]) throws {
    if let ids = replacementAttachmentIDs {
      replacementAttachmentIDs = try ids.map { try Self.currentReplacementID($0, remaps: remaps) }
    }
  }

  package static func currentReplacementID(_ id: UUID, remaps: [UUID: UUID]) throws -> UUID {
    var current = id
    var visited: Set<UUID> = []
    while let next = remaps[current] {
      guard visited.insert(current).inserted else { throw SyncModePersistenceError.invalidManifest }
      current = next
    }
    return current
  }

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
      && replacementIDs.map { Set($0).count == $0.count } != false
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
      payloads: CloudSetupPointerDelete.payloads(for: owed),
      replacementAttachmentIDs: replacements.map(\.attachmentID)
    )
  }

  package func setupPointerReplacementRemaps(namespaceKey: CloudSyncNamespaceKey) throws -> [UUID: UUID] {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    return try Self.setupPointerReplacementRemaps(
      namespaceKey: namespaceKey.rawValue, context: Self.makeContext(container: container)
    )
  }

  static func setupPointerReplacementRemaps(namespaceKey: String, context: ModelContext) throws -> [UUID: UUID] {
    let prefix = "\(namespaceKey)|setup-replacement-"
    var remaps: [UUID: UUID] = [:]
    for row in try setupPointerReplacementReceipts(namespaceKey: namespaceKey, context: context) {
      let fields = row.id.dropFirst(prefix.count).split(separator: "|")
      guard fields.count == 2, let to = UUID(uuidString: String(fields[0])),
        CloudFullReceiptOperation.setupReplacementRemap(from: row.batchID, to: to)
          .matches(row, namespaceKey: namespaceKey),
        row.digest == Data(SHA256.hash(data: Data(row.id.utf8))),
        remaps.updateValue(to, forKey: row.batchID) == nil
      else { throw SyncModePersistenceError.invalidManifest }
    }
    return remaps
  }

  static func recordSetupPointerReplacementRemap(
    from: UUID, to: UUID, namespaceKey: String, context: ModelContext
  ) {
    let operation = CloudFullReceiptOperation.setupReplacementRemap(from: from, to: to)
    let key = operation.storageKey(namespaceKey: namespaceKey)
    SwiftDataCloudFullOperationReceipts.record(
      operation, namespaceKey: namespaceKey, digest: Data(SHA256.hash(data: Data(key.utf8))), context: context
    )
  }

  private static func setupPointerReplacementReceipts(
    namespaceKey: String, context: ModelContext
  ) throws -> [StoredCloudFullBatchReceipt] {
    let prefix = "\(namespaceKey)|setup-replacement-"
    return try context.fetch(FetchDescriptor<StoredCloudFullBatchReceipt>(
      predicate: #Predicate { $0.namespaceKey == namespaceKey }
    )).filter { $0.id.hasPrefix(prefix) }
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
    for row in try Self.setupPointerReplacementReceipts(namespaceKey: namespaceKey.rawValue, context: context) {
      context.delete(row)
    }
    try afterMutationBeforeSave()
    try lock.check()
    try context.save()
  }
}
