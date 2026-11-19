import Foundation

package struct CloudSetupRetryRecordKey: Codable, Hashable, Sendable {
  /// An attachment pointer's reference identifies its parent snip.
  package let reference: CloudEntityReference
  package let identity: CloudTextStorageIdentity

  package init(reference: CloudEntityReference, identity: CloudTextStorageIdentity) {
    self.reference = reference
    self.identity = identity
  }

  package var attachmentID: UUID? {
    guard reference.kind == .snip, identity.recordName.hasPrefix("a-"),
      let id = UUID(uuidString: String(identity.recordName.dropFirst(2))),
      identity.recordName == "a-\(id.uuidString.lowercased())"
    else { return nil }
    return id
  }
}

package struct CloudSetupRetryOffer: Sendable {
  package let key: CloudSetupRetryRecordKey
  package let sourceFields: Data
  package let operationDigest: Data

  package init(key: CloudSetupRetryRecordKey, sourceFields: Data, operationDigest: Data) {
    self.key = key
    self.sourceFields = sourceFields
    self.operationDigest = operationDigest
  }
}

package struct CloudSetupRetryResult: Sendable {
  package let key: CloudSetupRetryRecordKey
  package let operationDigest: Data
  package let serverFields: Data?

  package init(key: CloudSetupRetryRecordKey, operationDigest: Data, serverFields: Data?) {
    self.key = key
    self.operationDigest = operationDigest
    self.serverFields = serverFields
  }
}

package struct CloudSetupRetryBaseline: Codable, Equatable, Sendable {
  package let sourceFields: Data
  package let serverFields: Data

  package init(sourceFields: Data, serverFields: Data) {
    self.sourceFields = sourceFields
    self.serverFields = serverFields
  }
}

package struct CloudSetupRetryEvidence: Codable, Equatable, Sendable {
  let namespace: ICloudSyncNamespaceBinding
  private var records: [CloudSetupRetryRecordKey: Record] = [:]
  private var unidentifiedLegacySend = false
  private var legacyIdentities: Set<CloudTextStorageIdentity> = []

  private struct Pending: Codable, Equatable, Sendable {
    let candidateStoreID: UUID
    let sourceFields: Data
    let operationDigest: Data
  }

  private struct Record: Codable, Equatable, Sendable {
    let key: CloudSetupRetryRecordKey
    var baseline: CloudSetupRetryBaseline?
    var pending: Pending?
    // A later rejection cannot clear an earlier send that might have reached iCloud.
    var earlierUnprovenSend = false
    var provedAfterLegacySend = false

    var isEmpty: Bool { baseline == nil && pending == nil && !earlierUnprovenSend }
  }

  init(namespace: ICloudSyncNamespaceBinding) {
    self.namespace = namespace
  }

  package func baseline(for key: CloudSetupRetryRecordKey) -> CloudSetupRetryBaseline? {
    records[key]?.baseline
  }

  package var acknowledgedSnipKeys: Set<CloudSetupRetryRecordKey> {
    Set(records.values.compactMap { record in
      let key = record.key
      guard record.baseline != nil, key.reference.kind == .snip,
        key.identity.recordName == "s-\(key.reference.domainID.uuidString.lowercased())"
      else { return nil }
      return key
    })
  }

  package func requiresRecovery(for key: CloudSetupRetryRecordKey) -> Bool {
    let record = records[key]
    return record?.pending != nil || record?.earlierUnprovenSend == true
      || (record?.provedAfterLegacySend != true
        && namespace.contains(key.identity)
        && (unidentifiedLegacySend || legacyIdentities.contains(key.identity)))
  }

  package var isEmpty: Bool {
    records.isEmpty && legacyIdentities.isEmpty && !unidentifiedLegacySend
  }

  mutating func recordOffers(_ offers: [CloudSetupRetryOffer], candidateStoreID: UUID) {
    for offer in offers {
      let pending = Pending(
        candidateStoreID: candidateStoreID,
        sourceFields: offer.sourceFields,
        operationDigest: offer.operationDigest
      )
      var record = records[offer.key] ?? Record(key: offer.key)
      if record.pending != nil {
        record.earlierUnprovenSend = true
      }
      record.pending = pending
      records[offer.key] = record
    }
  }

  mutating func recordResults(
    _ results: [CloudSetupRetryResult],
    candidateStoreID: UUID,
    afterStagingFirst: () throws -> Void
  ) throws -> Bool {
    let matchingResults = results.filter {
      guard let pending = records[$0.key]?.pending else { return false }
      return pending.candidateStoreID == candidateStoreID
        && pending.operationDigest == $0.operationDigest
    }
    guard !matchingResults.isEmpty else { return false }
    guard Set(matchingResults.map(\.key)).count == matchingResults.count else {
      throw SyncModePersistenceError.invalidManifest
    }
    for (index, result) in matchingResults.enumerated() {
      guard var record = records[result.key], let pending = record.pending else { continue }
      if let serverFields = result.serverFields {
        record.baseline = CloudSetupRetryBaseline(
          sourceFields: pending.sourceFields,
          serverFields: serverFields
        )
        record.earlierUnprovenSend = false
        record.provedAfterLegacySend = true
      }
      record.pending = nil
      records[result.key] = record.isEmpty ? nil : record
      if index == 0 {
        try afterStagingFirst()
      }
    }
    return true
  }

  mutating func recordLegacySend(_ operations: [SyncModeSendOperation]) {
    for operation in operations where namespace.contains(operation.recordIdentity) {
      guard let reference = operation.reference else {
        legacyIdentities.insert(operation.recordIdentity)
        for key in records.keys where key.identity == operation.recordIdentity {
          records[key]?.provedAfterLegacySend = false
        }
        continue
      }
      let key = CloudSetupRetryRecordKey(reference: reference, identity: operation.recordIdentity)
      records[key, default: Record(key: key)].earlierUnprovenSend = true
    }
  }

  mutating func recordUnidentifiedLegacySend() {
    unidentifiedLegacySend = true
    for key in records.keys {
      records[key]?.provedAfterLegacySend = false
    }
  }

  private enum CodingKeys: String, CodingKey {
    case namespace, records, unidentifiedLegacySend, legacyIdentities
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    namespace = try values.decode(ICloudSyncNamespaceBinding.self, forKey: .namespace)
    unidentifiedLegacySend = try values.decode(Bool.self, forKey: .unidentifiedLegacySend)
    legacyIdentities = try values.decode(Set<CloudTextStorageIdentity>.self, forKey: .legacyIdentities)
    let entries = try values.decode([Record].self, forKey: .records)
    guard legacyIdentities.allSatisfy(namespace.contains) else {
      throw SyncModePersistenceError.invalidManifest
    }
    for entry in entries {
      guard namespace.contains(entry.key.identity), !entry.isEmpty,
        records.updateValue(entry, forKey: entry.key) == nil
      else { throw SyncModePersistenceError.invalidManifest }
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(namespace, forKey: .namespace)
    try values.encode(unidentifiedLegacySend, forKey: .unidentifiedLegacySend)
    try values.encode(legacyIdentities.sorted { $0.key < $1.key }, forKey: .legacyIdentities)
    try values.encode(records.values.sorted {
      ($0.key.reference.kind.rawValue, $0.key.reference.domainID.uuidString, $0.key.identity.key)
        < ($1.key.reference.kind.rawValue, $1.key.reference.domainID.uuidString, $1.key.identity.key)
    }, forKey: .records)
  }
}

struct CloudSetupRetryHistory: Codable, Equatable, Sendable {
  // A missing marker on a loaded setup means it may predate offer capture.
  var trackedCandidateStoreID: UUID?
  var namespaces: [CloudSetupRetryEvidence] = []

  mutating func update(
    namespace: ICloudSyncNamespaceBinding,
    _ change: (inout CloudSetupRetryEvidence) throws -> Void
  ) rethrows {
    if let index = namespaces.firstIndex(where: { $0.namespace == namespace }) {
      try change(&namespaces[index])
      if namespaces[index].isEmpty { namespaces.remove(at: index) }
    } else {
      var evidence = CloudSetupRetryEvidence(namespace: namespace)
      try change(&evidence)
      if !evidence.isEmpty { namespaces.append(evidence) }
    }
  }
}

extension ICloudSyncNamespaceBinding {
  fileprivate func contains(_ identity: CloudTextStorageIdentity) -> Bool {
    zones.contains(ICloudSyncZoneBinding(name: identity.zoneName, ownerName: identity.ownerName))
  }
}
