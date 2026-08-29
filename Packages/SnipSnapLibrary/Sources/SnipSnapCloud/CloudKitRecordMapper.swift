import CloudKit
import Foundation

package enum CloudKitRecordMapper {
    package static func record(for draft: CloudRecordDraft) throws -> CKRecord {
        let record: CKRecord
        if let base = draft.base {
            record = try base.record()
            guard id(for: record.recordID) == draft.id,
                  record.recordType == draft.recordType
            else {
                throw CloudRecordError.mismatchedShadow
            }
        } else {
            record = CKRecord(
                recordType: draft.recordType,
                recordID: CKRecord.ID(
                    recordName: draft.id.name,
                    zoneID: zoneID(for: draft.id.zone)
                )
            )
        }

        let storedVersion = Int(record["schemaVersion"] as? Int64 ?? 0)
        record["schemaVersion"] = Int64(max(storedVersion, draft.schemaVersion))
        for (key, value) in draft.routingFields where key != "schemaVersion" {
            try set(value, on: record, key: key, encrypted: false)
        }
        for (key, value) in draft.encryptedFields {
            try set(value, on: record, key: key, encrypted: true)
        }
        for (key, asset) in draft.assetFields {
            record[key] = CKAsset(fileURL: asset.fileURL)
        }
        return record
    }

    package static func snapshot(
        _ record: CKRecord,
        desiredFields: Set<String>? = nil
    ) throws -> CloudRecordSnapshot {
        let version = record["schemaVersion"] as? Int64 ?? 0
        let routingKeys = Set(record.allKeys()).filter { desiredFields?.contains($0) ?? true }
        let encryptedKeys = Set(record.encryptedValues.allKeys()).filter {
            desiredFields?.contains($0) ?? true
        }
        var routing: [String: CloudFieldValue] = [:]
        var assets: Set<String> = []
        for key in routingKeys {
            if record[key] is CKAsset {
                assets.insert(key)
            } else if let value = fieldValue(record[key]) {
                routing[key] = value
            }
        }
        var encrypted: [String: CloudFieldValue] = [:]
        for key in encryptedKeys {
            if let value = fieldValue(record.encryptedValues[key]) {
                encrypted[key] = value
            }
        }
        return CloudRecordSnapshot(
            id: id(for: record.recordID),
            recordType: record.recordType,
            schemaVersion: Int(version),
            routingFields: routing,
            encryptedFields: encrypted,
            assetFields: assets,
            shadow: try CloudRecordShadow.archive(record)
        )
    }

    package static func id(for recordID: CKRecord.ID) -> CloudRecordID {
        CloudRecordID(
            zone: CloudZoneID(
                name: recordID.zoneID.zoneName,
                ownerName: recordID.zoneID.ownerName
            ),
            name: recordID.recordName
        )
    }

    package static func recordID(for id: CloudRecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.name, zoneID: zoneID(for: id.zone))
    }

    package static func id(for zoneID: CKRecordZone.ID) -> CloudZoneID {
        CloudZoneID(name: zoneID.zoneName, ownerName: zoneID.ownerName)
    }

    package static func zoneID(for id: CloudZoneID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: id.name, ownerName: id.ownerName)
    }

    private static func set(
        _ value: CloudFieldValue,
        on record: CKRecord,
        key: String,
        encrypted: Bool
    ) throws {
        switch value {
        case .string(let value):
            if encrypted { record.encryptedValues[key] = value } else { record[key] = value }
        case .int64(let value):
            if encrypted { record.encryptedValues[key] = value } else { record[key] = value }
        case .data(let value):
            if encrypted { record.encryptedValues[key] = value } else { record[key] = value }
        }
    }

    private static func fieldValue(_ value: (any CKRecordValueProtocol)?) -> CloudFieldValue? {
        switch value {
        case let value as String: .string(value)
        case let value as Int64: .int64(value)
        case let value as NSNumber: .int64(value.int64Value)
        case let value as Data: .data(value)
        default: nil
        }
    }
}

package struct CloudTextRecord: Equatable, Sendable {
    package let id: CloudRecordID
    package let snipID: UUID
    package let text: String
    package let schemaVersion: Int
    package let shadow: CloudRecordShadow

    package init(snapshot: CloudRecordSnapshot) throws {
        guard snapshot.recordType == "Snip" else { throw CloudRecordError.wrongRecordType }
        guard case .string(let snipIDValue)? = snapshot.routingFields["snipID"],
              let snipID = UUID(uuidString: snipIDValue)
        else {
            throw CloudRecordError.missingField("snipID")
        }
        guard case .string(let text)? = snapshot.encryptedFields["text"] else {
            throw CloudRecordError.missingField("text")
        }
        id = snapshot.id
        self.snipID = snipID
        self.text = text
        schemaVersion = snapshot.schemaVersion
        shadow = snapshot.shadow
    }
}
