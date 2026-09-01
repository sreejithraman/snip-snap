import Foundation
import SnipSnapCore
import SwiftData

@Model
final class StoredCloudTextRecord {
  @Attribute(.unique) var id: String
  var namespaceKey: String
  var zoneName: String
  var ownerName: String
  var recordName: String
  var snipID: UUID
  var schemaVersion: Int
  var acceptedText: String?
  var shadowData: Data?
  var systemFields: Data?
  var recoveryData: Data?

  init(
    namespaceKey: String,
    identity: CloudTextStorageIdentity,
    snipID: UUID,
    schemaVersion: Int = 1,
    acceptedText: String? = nil,
    shadowData: Data? = nil,
    systemFields: Data? = nil,
    recoveryData: Data? = nil
  ) {
    id = Self.key(namespaceKey: namespaceKey, identity: identity)
    self.namespaceKey = namespaceKey
    zoneName = identity.zoneName
    ownerName = identity.ownerName
    recordName = identity.recordName
    self.snipID = snipID
    self.schemaVersion = schemaVersion
    self.acceptedText = acceptedText
    self.shadowData = shadowData
    self.systemFields = systemFields
    self.recoveryData = recoveryData
  }

  var identity: CloudTextStorageIdentity {
    CloudTextStorageIdentity(
      zoneName: zoneName,
      ownerName: ownerName,
      recordName: recordName
    )
  }

  static func key(namespaceKey: String, identity: CloudTextStorageIdentity) -> String {
    "\(namespaceKey)|\(identity.key)"
  }

  func accept(_ value: CloudTextFetchedValue) {
    snipID = value.snipID
    schemaVersion = value.schemaVersion
    acceptedText = value.text
    shadowData = value.shadowData
    systemFields = value.systemFields
    recoveryData = nil
  }
}

@Model
final class StoredCloudEngineState {
  @Attribute(.unique) var namespaceKey: String
  var envelopeData: Data

  init(namespaceKey: String, envelopeData: Data) {
    self.namespaceKey = namespaceKey
    self.envelopeData = envelopeData
  }
}

@Model
final class StoredCloudStagedBatch {
  @Attribute(.unique) var id: String
  var namespaceKey: String
  var batchID: UUID
  var payload: Data

  init(namespaceKey: String, batchID: UUID, payload: Data) {
    id = "\(namespaceKey)|\(batchID.uuidString.lowercased())"
    self.namespaceKey = namespaceKey
    self.batchID = batchID
    self.payload = payload
  }
}

@Model
final class StoredCloudRecoveryEvent {
  @Attribute(.unique) var id: String
  var namespaceKey: String
  var eventKey: String
  var payload: Data

  init(namespaceKey: String, eventKey: String, payload: Data) {
    id = "\(namespaceKey)|\(eventKey)"
    self.namespaceKey = namespaceKey
    self.eventKey = eventKey
    self.payload = payload
  }
}

@Model
final class StoredCloudNamespaceState {
  @Attribute(.unique) var namespaceKey: String
  var phase: String
  var approvedSnipIDs: Data
  var excludedSnipIDs: Data
  var zoneCreationPending: Bool

  init(namespaceKey: String, value: CloudNamespaceStateStorage) throws {
    self.namespaceKey = namespaceKey
    phase = value.phase.rawValue
    approvedSnipIDs = try JSONEncoder().encode(value.approvedSnipIDs)
    excludedSnipIDs = try JSONEncoder().encode(value.excludedSnipIDs)
    zoneCreationPending = value.zoneCreationPending
  }

  func value() throws -> CloudNamespaceStateStorage {
    guard let phase = CloudNamespaceBootstrapPhase(rawValue: phase) else {
      throw SnipLibraryError.invalidStore
    }
    return try CloudNamespaceStateStorage(
      phase: phase,
      approvedSnipIDs: JSONDecoder().decode(Set<UUID>.self, from: approvedSnipIDs),
      excludedSnipIDs: JSONDecoder().decode(Set<UUID>.self, from: excludedSnipIDs),
      zoneCreationPending: zoneCreationPending
    )
  }

  func replace(with value: CloudNamespaceStateStorage) throws {
    phase = value.phase.rawValue
    approvedSnipIDs = try JSONEncoder().encode(value.approvedSnipIDs)
    excludedSnipIDs = try JSONEncoder().encode(value.excludedSnipIDs)
    zoneCreationPending = value.zoneCreationPending
  }
}

@Model
final class StoredCloudEntityRecord {
  @Attribute(.unique) var id: String
  @Attribute(.unique) var identityID: String
  var namespaceKey: String
  var kind: String
  var domainID: UUID
  var zoneName: String
  var ownerName: String
  var recordName: String
  var schemaVersion: Int
  var acceptedData: Data
  var presenceData: Data
  var shadowData: Data
  var systemFields: Data
  var dependencyListID: UUID?
  var isDeferred: Bool
  var localRevision: UInt64
  var deferredMutationData: Data?

  init(
    namespaceKey: String,
    value: CloudAcceptedEntityInput,
    isDeferred: Bool,
    localRevision: UInt64 = 1,
    deferredMutationData: Data? = nil
  ) {
    id = Self.domainKey(namespaceKey: namespaceKey, reference: value.reference)
    identityID = Self.identityKey(namespaceKey: namespaceKey, identity: value.identity)
    self.namespaceKey = namespaceKey
    kind = value.reference.kind.rawValue
    domainID = value.reference.domainID
    zoneName = value.identity.zoneName
    ownerName = value.identity.ownerName
    recordName = value.identity.recordName
    schemaVersion = value.schemaVersion
    acceptedData = value.acceptedData
    presenceData = value.presenceData
    shadowData = value.shadowData
    systemFields = value.systemFields
    dependencyListID = value.dependencyListID
    self.isDeferred = isDeferred
    self.localRevision = localRevision
    self.deferredMutationData = deferredMutationData
  }

  var reference: CloudEntityReference? {
    guard let kind = CloudEntityKind(rawValue: kind) else { return nil }
    return CloudEntityReference(kind: kind, domainID: domainID)
  }

  var identity: CloudTextStorageIdentity {
    CloudTextStorageIdentity(zoneName: zoneName, ownerName: ownerName, recordName: recordName)
  }

  func replace(
    with value: CloudAcceptedEntityInput,
    isDeferred: Bool,
    deferredMutationData: Data? = nil
  ) {
    schemaVersion = value.schemaVersion
    acceptedData = value.acceptedData
    presenceData = value.presenceData
    shadowData = value.shadowData
    systemFields = value.systemFields
    dependencyListID = value.dependencyListID
    self.isDeferred = isDeferred
    localRevision += 1
    self.deferredMutationData = deferredMutationData
  }

  func matches(_ value: CloudAcceptedEntityInput, isDeferred: Bool) -> Bool {
    schemaVersion == value.schemaVersion
      && acceptedData == value.acceptedData
      && presenceData == value.presenceData
      && shadowData == value.shadowData
      && systemFields == value.systemFields
      && dependencyListID == value.dependencyListID
      && self.isDeferred == isDeferred
  }

  static func domainKey(namespaceKey: String, reference: CloudEntityReference) -> String {
    "\(namespaceKey)|domain|\(reference.kind.rawValue)|\(reference.domainID.uuidString.lowercased())"
  }

  static func identityKey(namespaceKey: String, identity: CloudTextStorageIdentity) -> String {
    "\(namespaceKey)|record|\(identity.key)"
  }
}

@Model
final class StoredCloudFullConflict {
  @Attribute(.unique) var id: String
  var namespaceKey: String
  var kind: String
  var domainID: UUID
  var payload: Data
  var format: String

  init(
    namespaceKey: String,
    key: String,
    reference: CloudEntityReference,
    format: CloudConflictFormat,
    payload: Data
  ) {
    id = Self.key(namespaceKey: namespaceKey, conflictKey: key)
    self.namespaceKey = namespaceKey
    kind = reference.kind.rawValue
    domainID = reference.domainID
    self.payload = payload
    self.format = format.rawValue
  }

  static func key(namespaceKey: String, conflictKey: String) -> String {
    "\(namespaceKey)|conflict|\(conflictKey)"
  }
}

@Model
final class StoredCloudFullEnrollment {
  @Attribute(.unique) var namespaceKey: String
  var referencesData: Data

  init(namespaceKey: String, referencesData: Data) {
    self.namespaceKey = namespaceKey
    self.referencesData = referencesData
  }
}

@Model
final class StoredCloudDormantBaseRecord {
  @Attribute(.unique) var id: String
  @Attribute(.unique) var identityID: String
  var namespaceKey: String
  var kind: String
  var domainID: UUID
  var zoneName: String
  var ownerName: String
  var recordName: String
  var payload: Data

  init(
    namespaceKey: String,
    reference: CloudEntityReference,
    identity: CloudTextStorageIdentity,
    payload: Data
  ) {
    id = Self.key(namespaceKey: namespaceKey, reference: reference)
    identityID = Self.identityKey(namespaceKey: namespaceKey, identity: identity)
    self.namespaceKey = namespaceKey
    kind = reference.kind.rawValue
    domainID = reference.domainID
    zoneName = identity.zoneName
    ownerName = identity.ownerName
    recordName = identity.recordName
    self.payload = payload
  }

  static func key(namespaceKey: String, reference: CloudEntityReference) -> String {
    "\(namespaceKey)|dormant|\(reference.kind.rawValue)|\(reference.domainID.uuidString.lowercased())"
  }

  static func identityKey(namespaceKey: String, identity: CloudTextStorageIdentity) -> String {
    "\(namespaceKey)|dormant-record|\(identity.key)"
  }
}

@Model
final class StoredCloudMappingQuarantine {
  @Attribute(.unique) var id: String
  var namespaceKey: String
  var kind: String
  var domainID: UUID
  var zoneName: String
  var ownerName: String
  var recordName: String
  var format: String
  var payload: Data

  init(namespaceKey: String, value: CloudQuarantineInput) {
    id = Self.key(namespaceKey: namespaceKey, key: value.key)
    self.namespaceKey = namespaceKey
    kind = value.reference.kind.rawValue
    domainID = value.reference.domainID
    zoneName = value.identity.zoneName
    ownerName = value.identity.ownerName
    recordName = value.identity.recordName
    format = value.format.rawValue
    payload = value.payload
  }

  static func key(namespaceKey: String, key: String) -> String {
    "\(namespaceKey)|quarantine|\(key)"
  }
}

@Model
final class StoredCloudFullBatchReceipt {
  @Attribute(.unique) var id: String
  var namespaceKey: String
  var batchID: UUID
  var digest: Data
  var createdAt: Date

  init(namespaceKey: String, batchID: UUID, digest: Data) {
    id = Self.key(namespaceKey: namespaceKey, batchID: batchID)
    self.namespaceKey = namespaceKey
    self.batchID = batchID
    self.digest = digest
    createdAt = Date()
  }

  static func key(namespaceKey: String, batchID: UUID) -> String {
    "\(namespaceKey)|full-batch|\(batchID.uuidString.lowercased())"
  }
}

@Model
final class StoredCloudPendingDelete {
  @Attribute(.unique) var id: String
  @Attribute(.unique) var identityID: String
  var namespaceKey: String
  var kind: String
  var domainID: UUID
  var zoneName: String
  var ownerName: String
  var recordName: String

  init(namespaceKey: String, value: CloudPendingDelete) {
    id = Self.domainKey(namespaceKey: namespaceKey, reference: value.reference)
    identityID = Self.identityKey(namespaceKey: namespaceKey, identity: value.identity)
    self.namespaceKey = namespaceKey
    kind = value.reference.kind.rawValue
    domainID = value.reference.domainID
    zoneName = value.identity.zoneName
    ownerName = value.identity.ownerName
    recordName = value.identity.recordName
  }

  var value: CloudPendingDelete? {
    guard let kind = CloudEntityKind(rawValue: kind) else { return nil }
    return CloudPendingDelete(
      reference: CloudEntityReference(kind: kind, domainID: domainID),
      identity: CloudTextStorageIdentity(
        zoneName: zoneName,
        ownerName: ownerName,
        recordName: recordName
      )
    )
  }

  static func domainKey(namespaceKey: String, reference: CloudEntityReference) -> String {
    "\(namespaceKey)|pending-delete|\(reference.kind.rawValue)|\(reference.domainID.uuidString.lowercased())"
  }

  static func identityKey(namespaceKey: String, identity: CloudTextStorageIdentity) -> String {
    "\(namespaceKey)|pending-delete-record|\(identity.key)"
  }
}
