import CryptoKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

enum CloudSetupRetryCapture {
  static func removedOfferedAttachmentIDsBySnip(
    source: SnipLibraryTransferSnapshot,
    publications: [CloudAttachmentPublication],
    evidence: CloudSetupRetryEvidence
  ) -> [UUID: Set<UUID>] {
    let sourceIDs = Dictionary(uniqueKeysWithValues: source.snips.map { ($0.id, Set($0.attachments.map(\.id))) })
    let decoder = JSONDecoder()
    return publications.reduce(into: [:]) { removed, publication in
      let metadata = publication.metadata
      guard publication.metadataAccepted, publication.isLocallyPresent,
        let currentIDs = sourceIDs[metadata.snipID], !currentIDs.contains(metadata.attachmentID),
        let key = attachmentKey(metadata, identity: publication.metadataIdentity),
        !evidence.requiresRecovery(for: key), let proof = evidence.baseline(for: key),
        let acknowledged = try? decoder.decode(CloudAttachmentMetadataValue.self, from: proof.serverFields),
        acknowledged == metadata
      else { return }
      removed[metadata.snipID, default: []].insert(metadata.attachmentID)
    }
  }

  static func removedAttachmentIDsBySnip(
    source: SnipLibraryTransferSnapshot,
    accepted: [CloudAcceptedEntity],
    evidence: CloudSetupRetryEvidence,
    namespace: CloudSyncNamespace,
    dataZone: CloudZoneID
  ) throws -> [UUID: Set<UUID>] {
    let acceptedByReference = Dictionary(uniqueKeysWithValues: accepted.map { ($0.reference, $0.identity) })
    let dormant = try CloudDormantAcceptedBaseBundle.decode(source.opaqueSyncStatePayload)
    let dormantByReference = Dictionary(uniqueKeysWithValues: dormant.entries
      .filter { $0.namespaceKey == namespace.namespaceKey.rawValue }
      .map { ($0.reference, $0.identity) })
    let decoder = JSONDecoder()
    return source.snips.reduce(into: [:]) { removedBySnip, snip in
      let reference = CloudEntityReference(kind: .snip, domainID: snip.id)
      let identity = CloudFullSyncPersistence.storageIdentity(.snip(snip.id, in: dataZone))
      let key = CloudSetupRetryRecordKey(reference: reference, identity: identity)
      guard acceptedByReference[reference] == identity,
        !evidence.requiresRecovery(for: key),
        let baseline = evidence.baseline(for: key),
        let local = try? decoder.decode(CloudSnipMergeFields.self, from: baseline.sourceFields),
        let server = try? decoder.decode(CloudSnipMergeFields.self, from: baseline.serverFields),
        local.id == snip.id, server.id == snip.id,
        let prior = local.setupSourceAttachmentIDs
      else { return }
      if let dormantIdentity = dormantByReference[reference],
        evidence.requiresRecovery(for: CloudSetupRetryRecordKey(reference: reference, identity: dormantIdentity))
      { return }
      let removed = prior.subtracting(snip.attachments.map(\.id))
      if !removed.isEmpty { removedBySnip[snip.id] = removed }
    }
  }

  static func offers(
    for outbound: CloudOutboundBatch,
    source: SnipLibrarySnapshot,
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID? = nil
  ) throws -> [CloudSetupRetryOffer] {
    let snips = Dictionary(uniqueKeysWithValues: source.snips.map { ($0.id, $0) })
    let lists = Dictionary(uniqueKeysWithValues: source.lists.map { ($0.id, $0) })
    let encoder = fieldEncoder()
    return try outbound.operations.compactMap { operation in
      guard case .save(let draft) = operation else { return nil }
      if let payloadZone,
        let pointer = try? CloudAttachmentRecordCodec.metadata(from: draft, metadataZone: dataZone, payloadZone: payloadZone),
        let key = attachmentKey(pointer, identity: CloudFullSyncPersistence.storageIdentity(draft.id)),
        let parent = snips[pointer.snipID],
        let attachment = parent.attachments.first(where: { $0.id == pointer.attachmentID }),
        attachment.byteCount == pointer.byteCount,
        let url = source.attachmentURLs[attachment.id],
        (try? AttachmentFileIO.digest(at: url)) == pointer.sha256
      {
        return CloudSetupRetryOffer(
          key: key, sourceFields: try encoder.encode(pointer),
          operationDigest: operationDigest(try CloudFullSyncPersistence.outboundBinding(operation))
        )
      }
      guard let key = key(for: draft, in: dataZone) else { return nil }
      let sourceFields: Data
      switch key.reference.kind {
      case .snip:
        guard let snip = snips[key.reference.domainID] else { return nil }
        let sourceDraft = try CloudFullRecordCodec.snipDraft(snip, in: dataZone)
        guard sameSnipIdentity(draft.encryptedFields, sourceDraft.encryptedFields) else {
          return nil
        }
        var fields = CloudFullSyncPersistence.snipFields(snip, accepted: nil)
        fields.setupSourceAttachmentIDs = Set(snip.attachments.map(\.id))
        sourceFields = try encoder.encode(fields)
      case .list:
        guard let list = lists[key.reference.domainID] else { return nil }
        sourceFields = try encoder.encode(CloudFullSyncPersistence.listFields(list, updatedAt: .distantPast))
      }
      // The candidate can contain merged fields that differ from the frozen source.
      return CloudSetupRetryOffer(
        key: key,
        sourceFields: sourceFields,
        operationDigest: operationDigest(try CloudFullSyncPersistence.outboundBinding(operation))
      )
    }
  }

  static func results(
    for sent: CloudSentBatch,
    outbound: CloudOutboundBatch,
    commit: CloudFullBatchCommit,
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID? = nil
  ) -> [CloudSetupRetryResult] {
    let byID = Dictionary(uniqueKeysWithValues: sent.items.map { ($0.id, $0) })
    let bindings = Dictionary(uniqueKeysWithValues: commit.outboundBindings.map { ($0.identity, $0) })
    let upserts = Set(commit.items.compactMap { item -> CloudSetupRetryRecordKey? in
      guard item.acceptedAction == .upsert else { return nil }
      return CloudSetupRetryRecordKey(reference: item.accepted.reference, identity: item.accepted.identity)
    })
    let encoder = fieldEncoder()
    return outbound.operations.compactMap { operation in
      guard case .save(let draft) = operation,
        let binding = bindings[CloudFullSyncPersistence.storageIdentity(draft.id)], binding.action == .save,
        let result = byID[draft.id]
      else { return nil }
      let pointer = payloadZone.flatMap {
        try? CloudAttachmentRecordCodec.metadata(from: draft, metadataZone: dataZone, payloadZone: $0)
      }
      let pointerKey = pointer.flatMap { attachmentKey($0, identity: binding.identity) }
      guard let key = pointerKey ?? key(for: draft, in: dataZone) else { return nil }

      let serverFields: Data?
      switch result {
      case .saved(let snapshot):
        if let pointer, let payloadZone {
          guard snapshot.id == draft.id,
            let saved = try? CloudAttachmentRecordCodec.metadata(from: snapshot, metadataZone: dataZone, payloadZone: payloadZone),
            saved == pointer, commit.attachmentTransitions.contains(where: { transition in
              guard case .metadataAccepted(let id, _, let shadow, _) = transition else { return false }
              return id == pointer.attachmentID && shadow == snapshot.shadow.data
            }), let fields = try? encoder.encode(saved)
          else { return nil }
          serverFields = fields
        } else {
          guard upserts.contains(key),
            let fields = try? savedFields(snapshot, for: draft, key: key, encoder: encoder)
          else { return nil }
          serverFields = fields
        }
      case .conflict(_, let server) where server.id == draft.id && server.recordType == draft.recordType:
        serverFields = nil
      case .unknownItem:
        serverFields = nil
      case .failed(_, let failure) where definitivelyDidNotSave(failure):
        serverFields = nil
      default:
        return nil
      }
      return CloudSetupRetryResult(
        key: key,
        operationDigest: operationDigest(binding),
        serverFields: serverFields
      )
    }
  }

  private static func attachmentKey(
    _ metadata: CloudAttachmentMetadataValue,
    identity: CloudTextStorageIdentity
  ) -> CloudSetupRetryRecordKey? {
    let key = CloudSetupRetryRecordKey(
      reference: CloudEntityReference(kind: .snip, domainID: metadata.snipID), identity: identity
    )
    return key.attachmentID == metadata.attachmentID ? key : nil
  }

  private static func key(for draft: CloudRecordDraft, in dataZone: CloudZoneID) -> CloudSetupRetryRecordKey? {
    guard draft.id.zone == dataZone else { return nil }
    let kind: CloudEntityKind
    let routingKey: String
    switch draft.recordType {
    case "Snip": (kind, routingKey) = (.snip, "snipID")
    case "List": (kind, routingKey) = (.list, "listID")
    default: return nil
    }
    guard case .string(let value)? = draft.routingFields[routingKey],
      let id = UUID(uuidString: value)
    else { return nil }
    let expectedID: CloudRecordID = switch kind {
    case .snip: .snip(id, in: dataZone)
    case .list: .list(id, in: dataZone)
    }
    guard draft.id == expectedID else { return nil }
    return CloudSetupRetryRecordKey(
      reference: CloudEntityReference(kind: kind, domainID: id),
      identity: CloudFullSyncPersistence.storageIdentity(draft.id)
    )
  }

  private static func savedFields(
    _ snapshot: CloudRecordSnapshot,
    for draft: CloudRecordDraft,
    key: CloudSetupRetryRecordKey,
    encoder: JSONEncoder
  ) throws -> Data? {
    switch key.reference.kind {
    case .snip:
      guard sameSnipIdentity(draft.encryptedFields, snapshot.encryptedFields) else { return nil }
      let record = try CloudFullRecordCodec.snip(from: snapshot)
      return try encoder.encode(CloudFullSyncPersistence.snipFields(record))
    case .list:
      let record = try CloudFullRecordCodec.list(from: snapshot)
      return try encoder.encode(CloudFullSyncPersistence.listFields(record))
    }
  }

  private static func sameSnipIdentity(
    _ lhs: [String: CloudFieldValue],
    _ rhs: [String: CloudFieldValue]
  ) -> Bool {
    ["requestID", "createdAt", "origin"].allSatisfy { lhs[$0] == rhs[$0] }
  }

  private static func definitivelyDidNotSave(_ failure: CloudOperationFailure) -> Bool {
    // The transport uses .retryable for a missing result, .iCloudUnavailable for
    // a lost response, and .invalidRecord when a saved record cannot be decoded.
    switch failure {
    case .rateLimited, .authenticationRequired, .accountTemporarilyUnavailable,
      .quotaExceeded, .updateRequired, .accessDenied, .attachmentMissing, .rejected, .zoneMissing:
      true
    case .networkUnavailable, .iCloudUnavailable, .retryable, .attachmentUnavailable,
      .changeTokenExpired, .invalidRecord:
      false
    }
  }

  private static func fieldEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static func operationDigest(_ binding: CloudFullOutboundBinding) -> Data {
    Data(SHA256.hash(data: binding.operationData))
  }
}
