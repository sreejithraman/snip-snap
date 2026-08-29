import CloudKit
import Foundation

package enum CloudCollectionControlCodec {
  package static let recordType = "SnipSnapCollectionControl"
  package static let schemaVersion: Int64 = 1

  package static func record(
    _ descriptor: CloudCollectionDescriptor,
    id: CloudRecordID,
    replacing version: Data?
  ) throws -> CKRecord {
    let expectedID = CloudKitRecordMapper.recordID(for: id)
    let record: CKRecord
    if let version {
      record = try CloudRecordShadow(data: version).record()
      guard record.recordID == expectedID, record.recordType == recordType else {
        throw CloudCollectionError.invalidDescriptor
      }
    } else {
      record = CKRecord(recordType: recordType, recordID: expectedID)
    }
    record["schemaVersion"] = schemaVersion as CKRecordValue
    record["generation"] = descriptor.generation.uuidString.lowercased() as CKRecordValue
    record["metadataZoneName"] = descriptor.metadataZone.name as CKRecordValue
    record["metadataZoneOwner"] = descriptor.metadataZone.ownerName as CKRecordValue
    record["payloadZoneName"] = descriptor.payloadZone.name as CKRecordValue
    record["payloadZoneOwner"] = descriptor.payloadZone.ownerName as CKRecordValue
    return record
  }

  package static func decode(
    _ record: CKRecord,
    expectedID: CloudRecordID
  ) throws -> CloudCollectionControlRecord {
    guard record.recordID == CloudKitRecordMapper.recordID(for: expectedID),
      record.recordType == recordType,
      record["schemaVersion"] as? Int64 == schemaVersion,
      let generationText = record["generation"] as? String,
      let generation = UUID(uuidString: generationText),
      let metadataName = record["metadataZoneName"] as? String,
      let metadataOwner = record["metadataZoneOwner"] as? String,
      let payloadName = record["payloadZoneName"] as? String,
      let payloadOwner = record["payloadZoneOwner"] as? String
    else { throw CloudCollectionError.invalidDescriptor }
    let descriptor = CloudCollectionDescriptor(
      generation: generation,
      metadataZone: CloudZoneID(name: metadataName, ownerName: metadataOwner),
      payloadZone: CloudZoneID(name: payloadName, ownerName: payloadOwner)
    )
    guard descriptor.metadataZone != descriptor.payloadZone else {
      throw CloudCollectionError.invalidDescriptor
    }
    return CloudCollectionControlRecord(
      descriptor: descriptor,
      version: try CloudRecordShadow.archive(record).data
    )
  }
}

/// Uses direct private-database calls for the small control record and zone lifecycle.
package actor CloudKitCollectionControlTransport: CloudCollectionControlTransport {
  private let database: CKDatabase
  private let controlID: CloudRecordID

  package init(database: CKDatabase, controlID: CloudRecordID) {
    self.database = database
    self.controlID = controlID
  }

  package nonisolated static func isMissingControl(_ code: CKError.Code) -> Bool {
    code == .unknownItem || code == .zoneNotFound
  }

  package func fetchControl() async throws -> CloudCollectionControlRecord? {
    do {
      let record = try await database.record(
        for: CloudKitRecordMapper.recordID(for: controlID)
      )
      return try CloudCollectionControlCodec.decode(record, expectedID: controlID)
    } catch let error as CKError where Self.isMissingControl(error.code) {
      return nil
    } catch let error as CloudCollectionError {
      throw error
    } catch {
      throw CloudTransportError.fetchFailed
    }
  }

  package func createZones(_ zones: Set<CloudZoneID>) async throws {
    let allZones = zones.union([controlID.zone])
    do {
      let result = try await database.modifyRecordZones(
        saving: allZones.map {
          CKRecordZone(zoneID: CloudKitRecordMapper.zoneID(for: $0))
        },
        deleting: []
      )
      for value in result.saveResults.values {
        _ = try value.get()
      }
    } catch {
      throw CloudTransportError.sendFailed
    }
  }

  package func saveControl(
    _ descriptor: CloudCollectionDescriptor,
    replacing version: Data?
  ) async throws -> CloudCollectionControlSaveResult {
    let record = try CloudCollectionControlCodec.record(
      descriptor,
      id: controlID,
      replacing: version
    )
    do {
      let result = try await database.modifyRecords(
        saving: [record],
        deleting: [],
        savePolicy: .ifServerRecordUnchanged,
        atomically: true
      )
      guard let saved = result.saveResults[record.recordID] else {
        throw CloudTransportError.sendFailed
      }
      do {
        return .accepted(
          try CloudCollectionControlCodec.decode(saved.get(), expectedID: controlID)
        )
      } catch let error as CKError {
        return try conflictOrThrow(error)
      }
    } catch let error as CKError {
      return try conflictOrThrow(error)
    } catch let error as CloudCollectionError {
      throw error
    } catch {
      throw CloudTransportError.sendFailed
    }
  }

  package func deleteZones(_ zones: Set<CloudZoneID>) async throws {
    guard !zones.isEmpty else { return }
    do {
      let result = try await database.modifyRecordZones(
        saving: [],
        deleting: zones.map(CloudKitRecordMapper.zoneID(for:))
      )
      for value in result.deleteResults.values {
        do {
          try value.get()
        } catch let error as CKError where error.code == .zoneNotFound {
          continue
        }
      }
    } catch let error as CKError where error.code == .zoneNotFound {
      return
    } catch {
      throw CloudTransportError.sendFailed
    }
  }

  private func conflictOrThrow(
    _ error: CKError
  ) throws -> CloudCollectionControlSaveResult {
    guard error.code == .serverRecordChanged,
      let server = error.serverRecord
    else { throw CloudTransportError.sendFailed }
    return .conflict(
      try CloudCollectionControlCodec.decode(server, expectedID: controlID)
    )
  }
}
