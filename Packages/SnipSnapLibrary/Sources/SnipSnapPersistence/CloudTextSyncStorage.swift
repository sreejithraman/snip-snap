import Foundation
import SnipSnapCore

package struct CloudTextStorageIdentity: Codable, Equatable, Hashable, Sendable {
  package let zoneName: String
  package let ownerName: String
  package let recordName: String

  package init(zoneName: String, ownerName: String, recordName: String) {
    self.zoneName = zoneName
    self.ownerName = ownerName
    self.recordName = recordName
  }

  package var key: String {
    var data = Data()
    for value in [ownerName, zoneName, recordName] {
      let bytes = Data(value.utf8)
      var count = UInt64(bytes.count).bigEndian
      withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
      data.append(bytes)
    }
    return data.base64EncodedString()
  }
}

package struct CloudTextStorageRecord: Equatable, Sendable {
  package let identity: CloudTextStorageIdentity
  package let snipID: UUID
  package let schemaVersion: Int
  package let acceptedText: String?
  package let shadowData: Data?
  package let systemFields: Data?
  package let recoveryData: Data?
}

package struct CloudTextRecordReservation: Equatable, Sendable {
  package let identity: CloudTextStorageIdentity
  package let snipID: UUID

  package init(identity: CloudTextStorageIdentity, snipID: UUID) {
    self.identity = identity
    self.snipID = snipID
  }
}

package struct CloudTextStorageSnapshot: Equatable, Sendable {
  package let snips: [Snip]
  package let records: [CloudTextStorageRecord]
  package let namespaceState: CloudNamespaceStateStorage
  package let engineState: Data?
  package let stagedBatches: [CloudStagedBatchStorage]
  package let recoveryEvents: [CloudRecoveryEventStorage]
}

package enum CloudNamespaceBootstrapPhase: String, Codable, Equatable, Sendable {
  case notEnrolled
  case remoteChecked
  case remoteCheckedMissingZone
  case seeding
  case active
  case blocked
}

package struct CloudNamespaceStateStorage: Codable, Equatable, Sendable {
  package let phase: CloudNamespaceBootstrapPhase
  package let approvedSnipIDs: Set<UUID>
  package let excludedSnipIDs: Set<UUID>
  package let zoneCreationPending: Bool

  package init(
    phase: CloudNamespaceBootstrapPhase,
    approvedSnipIDs: Set<UUID> = [],
    excludedSnipIDs: Set<UUID> = [],
    zoneCreationPending: Bool = false
  ) {
    self.phase = phase
    self.approvedSnipIDs = approvedSnipIDs
    self.excludedSnipIDs = excludedSnipIDs
    self.zoneCreationPending = zoneCreationPending
  }

  package static let notEnrolled = CloudNamespaceStateStorage(phase: .notEnrolled)
}

package struct CloudStagedBatchStorage: Equatable, Sendable {
  package let id: UUID
  package let payload: Data

  package init(id: UUID, payload: Data) {
    self.id = id
    self.payload = payload
  }
}

package struct CloudRecoveryEventStorage: Equatable, Sendable {
  package let key: String
  package let payload: Data

  package init(key: String, payload: Data) {
    self.key = key
    self.payload = payload
  }
}

package struct CloudTextFetchedValue: Equatable, Sendable {
  package let identity: CloudTextStorageIdentity
  package let snipID: UUID
  package let text: String
  package let schemaVersion: Int
  package let shadowData: Data
  package let systemFields: Data

  package init(
    identity: CloudTextStorageIdentity,
    snipID: UUID,
    text: String,
    schemaVersion: Int,
    shadowData: Data,
    systemFields: Data
  ) {
    self.identity = identity
    self.snipID = snipID
    self.text = text
    self.schemaVersion = schemaVersion
    self.shadowData = shadowData
    self.systemFields = systemFields
  }
}

package enum CloudTextLocalMutation: Equatable, Sendable {
  case insert(Snip)
  case replace(id: UUID, expectedText: String, text: String, updatedAt: Date)
  case keep(id: UUID, expectedText: String)
  case requireMissing(id: UUID)
  case delete(id: UUID, expectedText: String)
  case none
}

package enum CloudTextRecordMutation: Equatable, Sendable {
  case accept(CloudTextFetchedValue)
  case acceptAndRecover(CloudTextFetchedValue, recoveryData: Data)
  case clearAndRecover(CloudTextStorageIdentity, recoveryData: Data)
  case recover(CloudTextStorageIdentity, recoveryData: Data)
  case remove(CloudTextStorageIdentity)
}

package struct CloudTextFetchedMutation: Equatable, Sendable {
  package let record: CloudTextRecordMutation
  package let local: CloudTextLocalMutation

  package init(record: CloudTextRecordMutation, local: CloudTextLocalMutation) {
    self.record = record
    self.local = local
  }
}
