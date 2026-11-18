import CryptoKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

enum CloudSetupRetryCapture {
  static func offers(
    for outbound: CloudOutboundBatch,
    source: SnipLibrarySnapshot,
    dataZone: CloudZoneID
  ) throws -> [CloudSetupRetryOffer] {
    let snips = Dictionary(uniqueKeysWithValues: source.snips.map { ($0.id, $0) })
    let lists = Dictionary(uniqueKeysWithValues: source.lists.map { ($0.id, $0) })
    let encoder = fieldEncoder()
    return try outbound.operations.compactMap { operation in
      guard case .save(let draft) = operation, let key = key(for: draft, in: dataZone) else {
        return nil
      }
      let sourceFields: Data
      switch key.reference.kind {
      case .snip:
        guard let snip = snips[key.reference.domainID] else { return nil }
        let sourceDraft = try CloudFullRecordCodec.snipDraft(snip, in: dataZone)
        guard sameSnipIdentity(draft.encryptedFields, sourceDraft.encryptedFields) else {
          return nil
        }
        sourceFields = try encoder.encode(CloudFullSyncPersistence.snipFields(snip, accepted: nil))
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
    dataZone: CloudZoneID
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
        let key = key(for: draft, in: dataZone),
        let binding = bindings[key.identity], binding.action == .save,
        let result = byID[draft.id]
      else { return nil }

      let serverFields: Data?
      switch result {
      case .saved(let snapshot):
        guard upserts.contains(key),
          let fields = try? savedFields(snapshot, for: draft, key: key, encoder: encoder)
        else { return nil }
        serverFields = fields
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
