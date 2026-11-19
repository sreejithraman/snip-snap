import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData

package struct CloudSetupPointerDeleteOffer: Sendable {
  let pointer: CloudTextStorageIdentity
  let metadataShadow: Data?

  package init(pointer: CloudTextStorageIdentity, metadataShadow: Data?) {
    self.pointer = pointer
    self.metadataShadow = metadataShadow
  }

  package static func isPointer(_ identity: CloudTextStorageIdentity) -> Bool {
    guard identity.recordName.hasPrefix("a-"),
      let id = UUID(uuidString: String(identity.recordName.dropFirst(2)))
    else { return false }
    return identity.recordName == "a-\(id.uuidString.lowercased())"
  }
}

struct CloudSetupPointerDeleteHold: Codable, Equatable, Sendable {
  let pointer: CloudTextStorageIdentity
  let payloads: Set<CloudTextStorageIdentity>

  func isValid(in namespace: ICloudSyncNamespaceBinding) -> Bool {
    CloudSetupPointerDeleteOffer.isPointer(pointer) && namespace.contains(pointer)
      && payloads.allSatisfy {
        namespace.contains($0) && ($0.zoneName != pointer.zoneName || $0.ownerName != pointer.ownerName)
      }
  }
}

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

  package struct Replacement: Codable, Hashable, Sendable {
    package let attachmentID: UUID
    let snipID: UUID
    let payloadIdentity: CloudTextStorageIdentity
    let sha256: Data
    let byteCount: Int64

    package init(_ metadata: CloudAttachmentMetadataValue) {
      attachmentID = metadata.attachmentID
      snipID = metadata.snipID
      payloadIdentity = metadata.payloadIdentity
      sha256 = metadata.sha256
      byteCount = metadata.byteCount
    }

    func matchesSource(snipID: UUID, sha256: Data, byteCount: Int64) -> Bool {
      self.snipID == snipID && self.sha256 == sha256 && self.byteCount == byteCount
    }
  }

  package struct ReplacementRemap: Codable, Equatable, Sendable {
    let source: Replacement
    let target: Replacement

    var isValid: Bool {
      source != target && source.snipID == target.snipID
        && source.sha256 == target.sha256 && source.byteCount == target.byteCount
        && source.payloadIdentity.zoneName == target.payloadIdentity.zoneName
        && source.payloadIdentity.ownerName == target.payloadIdentity.ownerName
    }
  }

  package typealias ReplacementRemaps = [Replacement: ReplacementRemap]

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
  private var boundReplacements: [Replacement]?
  // Older draft receipts retain their evidence but cannot prove a nonempty dependency.
  private var replacementAttachmentIDs: [UUID]? = nil
  private var position: Int? = nil
  private var replacements: [LegacyReplacement]? = nil
  package var payloadIdentities: Set<CloudTextStorageIdentity> { Set(payloads.map(\.identity)) }

  init(key: Key, bindingDigest: Data, snipID: UUID, payloads: [Payload], boundReplacements: [Replacement]) {
    self.key = key
    self.bindingDigest = bindingDigest
    self.snipID = snipID
    self.payloads = payloads
    self.boundReplacements = boundReplacements
  }

  package var replacementDependencies: [Replacement]? {
    if let boundReplacements { return boundReplacements }
    if let replacementAttachmentIDs { return replacementAttachmentIDs.isEmpty ? [] : nil }
    return replacements?.isEmpty == true ? [] : nil
  }

  mutating func applyReplacementRemaps(_ remaps: ReplacementRemaps) throws {
    if let boundReplacements {
      self.boundReplacements = try boundReplacements.map { try Self.currentReplacement($0, remaps: remaps) }
    }
  }

  package static func currentReplacement(
    _ dependency: Replacement, remaps: ReplacementRemaps
  ) throws -> Replacement {
    var current = dependency
    var visited: Set<Replacement> = []
    while let remap = remaps[current] {
      guard visited.insert(current).inserted else { throw SyncModePersistenceError.invalidManifest }
      current = remap.target
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
      && replacementDependencies.map { dependencies in
        Set(dependencies.map(\.attachmentID)).count == dependencies.count
          && dependencies.allSatisfy { $0.snipID == snipID && namespace.contains($0.payloadIdentity)
            && $0.sha256.count == 32 && $0.byteCount >= 0 }
      } != false
  }
}

extension SwiftDataSnipLibrary {
  func setupPointerDeleteHolds(
    namespaceKey: CloudSyncNamespaceKey,
    offers: [CloudSetupPointerDeleteOffer]
  ) throws -> [CloudSetupPointerDeleteHold] {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let publications = try Self.cloudAttachmentPublications(namespaceKey: namespaceKey.rawValue, context: context)
    return try offers.map { offer in
      guard let row = publications.first(where: {
        $0.metadataIdentity == offer.pointer && $0.metadataShadowData == offer.metadataShadow
      }) else { throw CloudAttachmentStorageError.staleTransition }
      let owed = try row.lifecycle.acceptMetadataDeletion(expectedRevision: row.revision)
      return CloudSetupPointerDeleteHold(pointer: offer.pointer, payloads: Set(owed.map(\.identity)))
    }
  }

  func setupPointerDeletes(
    namespaceKey: CloudSyncNamespaceKey,
    bindings: [CloudSetupPointerDelete.Binding]
  ) throws -> [CloudSetupPointerDelete] {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let publications = try Self.cloudAttachmentPublications(namespaceKey: namespaceKey.rawValue, context: context)
    return try bindings.map { binding in
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
        boundReplacements: replacements.map { .init($0.metadata) }
      )
    }
  }

  package func setupPointerReplacementRemaps(
    namespaceKey: CloudSyncNamespaceKey
  ) throws -> CloudSetupPointerDelete.ReplacementRemaps {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    return try Self.setupPointerReplacementRemaps(
      namespaceKey: namespaceKey.rawValue, context: Self.makeContext(container: container)
    )
  }

  static func setupPointerReplacementRemaps(
    namespaceKey: String, context: ModelContext
  ) throws -> CloudSetupPointerDelete.ReplacementRemaps {
    let prefix = "\(namespaceKey)|setup-replacement-v2-"
    var remaps: CloudSetupPointerDelete.ReplacementRemaps = [:]
    for row in try setupPointerReplacementReceipts(namespaceKey: namespaceKey, context: context) {
      guard row.id.hasPrefix(prefix) else { continue }
      let fields = row.id.dropFirst(prefix.count).split(separator: "|")
      guard fields.count == 2, let data = Data(base64Encoded: String(fields[0])),
        let remap = try? JSONDecoder().decode(CloudSetupPointerDelete.ReplacementRemap.self, from: data),
        remap.isValid, remap.source.attachmentID == row.batchID,
        CloudFullReceiptOperation.setupReplacementRemap(from: row.batchID, proof: String(fields[0]))
          .matches(row, namespaceKey: namespaceKey),
        row.digest == Data(SHA256.hash(data: Data(row.id.utf8))),
        remaps.updateValue(remap, forKey: remap.source) == nil
      else { throw SyncModePersistenceError.invalidManifest }
    }
    return remaps
  }

  static func recordSetupPointerReplacementRemap(
    _ remap: CloudSetupPointerDelete.ReplacementRemap, namespaceKey: String, context: ModelContext
  ) throws {
    guard remap.isValid else { throw SyncModePersistenceError.invalidManifest }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let proof = try encoder.encode(remap).base64EncodedString()
    let operation = CloudFullReceiptOperation.setupReplacementRemap(from: remap.source.attachmentID, proof: proof)
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

}
