import CloudKit
import Foundation

/// The direct private-database calls the control and clipboard transports make. Each call
/// takes its `CloudKitCallBound.Kind`, and `live` applies that kind's configuration.
package struct CloudKitDatabaseCalls: Sendable {
  package typealias RecordResults = (
    saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
    deleteResults: [CKRecord.ID: Result<Void, any Error>]
  )
  package typealias ZoneResults = (
    saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
    deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
  )

  package let record: @Sendable (CKRecord.ID, CloudKitCallBound.Kind) async throws -> CKRecord
  package let modifyRecords: @Sendable (
    [CKRecord],
    [CKRecord.ID],
    CKModifyRecordsOperation.RecordSavePolicy,
    Bool,
    CloudKitCallBound.Kind
  ) async throws -> RecordResults
  package let modifyRecordZones: @Sendable (
    [CKRecordZone],
    [CKRecordZone.ID],
    CloudKitCallBound.Kind
  ) async throws -> ZoneResults
  package let saveZone: @Sendable (CKRecordZone, CloudKitCallBound.Kind) async throws -> CKRecordZone

  package init(
    record: @escaping @Sendable (CKRecord.ID, CloudKitCallBound.Kind) async throws -> CKRecord,
    modifyRecords: @escaping @Sendable (
      [CKRecord],
      [CKRecord.ID],
      CKModifyRecordsOperation.RecordSavePolicy,
      Bool,
      CloudKitCallBound.Kind
    ) async throws -> RecordResults,
    modifyRecordZones: @escaping @Sendable (
      [CKRecordZone],
      [CKRecordZone.ID],
      CloudKitCallBound.Kind
    ) async throws -> ZoneResults,
    saveZone: @escaping @Sendable (CKRecordZone, CloudKitCallBound.Kind) async throws
      -> CKRecordZone
  ) {
    self.record = record
    self.modifyRecords = modifyRecords
    self.modifyRecordZones = modifyRecordZones
    self.saveZone = saveZone
  }

  package static func live(database: CKDatabase, bound: CloudKitCallBound) -> Self {
    Self(
      record: { id, kind in
        try await database.configuredWith(configuration: bound.configuration(kind)) {
          try await $0.record(for: id)
        }
      },
      modifyRecords: { saving, deleting, savePolicy, atomically, kind in
        try await database.configuredWith(configuration: bound.configuration(kind)) {
          try await $0.modifyRecords(
            saving: saving,
            deleting: deleting,
            savePolicy: savePolicy,
            atomically: atomically
          )
        }
      },
      modifyRecordZones: { saving, deleting, kind in
        try await database.configuredWith(configuration: bound.configuration(kind)) {
          try await $0.modifyRecordZones(saving: saving, deleting: deleting)
        }
      },
      saveZone: { zone, kind in
        try await database.configuredWith(configuration: bound.configuration(kind)) {
          try await $0.save(zone)
        }
      }
    )
  }
}
