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
