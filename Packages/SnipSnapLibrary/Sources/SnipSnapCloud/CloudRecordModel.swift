import CloudKit
import Foundation
import SnipSnapPersistence

package struct CloudZoneID: Codable, Equatable, Hashable, Sendable {
    package let name: String
    package let ownerName: String

    package init(name: String, ownerName: String) {
        self.name = name
        self.ownerName = ownerName
    }
}

package struct CloudRecordID: Codable, Equatable, Hashable, Sendable {
    package let zone: CloudZoneID
    package let name: String

    package init(zone: CloudZoneID, name: String) {
        self.zone = zone
        self.name = name
    }

    package static func random(in zone: CloudZoneID) -> CloudRecordID {
        CloudRecordID(zone: zone, name: UUID().uuidString.lowercased())
    }
}

package enum CloudFieldValue: Codable, Equatable, Sendable {
    case string(String)
    case int64(Int64)
    case data(Data)
}

package struct CloudAssetUpload: Codable, Equatable, Sendable {
    package let fileURL: URL

    package init(fileURL: URL) {
        self.fileURL = fileURL
    }
}

package struct CloudRecordShadow: Codable, Equatable, Sendable {
    package let data: Data
    package let systemFields: Data

    package init(data: Data) throws {
        let record = try Self.unarchive(data)
        self.data = data
        systemFields = Self.encodeSystemFields(record)
    }

    private init(data: Data, systemFields: Data) {
        self.data = data
        self.systemFields = systemFields
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try container.decode(Data.self, forKey: .data)
        let systemFields = try container.decode(Data.self, forKey: .systemFields)
        let validated = try CloudRecordShadow(data: data)
        guard validated.systemFields == systemFields else {
            throw CloudRecordError.invalidShadow
        }
        self = validated
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data, forKey: .data)
        try container.encode(systemFields, forKey: .systemFields)
    }

    private enum CodingKeys: String, CodingKey {
        case data
        case systemFields
    }

    package static func archive(_ record: CKRecord) throws -> CloudRecordShadow {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: record,
            requiringSecureCoding: true
        )
        return CloudRecordShadow(data: data, systemFields: encodeSystemFields(record))
    }

    package func record() throws -> CKRecord {
        try Self.unarchive(data)
    }

    private static func unarchive(_ data: Data) throws -> CKRecord {
        guard let record = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKRecord.self,
            from: data
        ) else {
            throw CloudRecordError.invalidShadow
        }
        return record
    }

    private static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }
}

package struct CloudRecordDraft: Codable, Equatable, Sendable {
    package let id: CloudRecordID
    package let recordType: String
    package let schemaVersion: Int
    package let routingFields: [String: CloudFieldValue]
    package let encryptedFields: [String: CloudFieldValue]
    package let assetFields: [String: CloudAssetUpload]
    package let removedRoutingFields: Set<String>
    package let removedEncryptedFields: Set<String>
    package let base: CloudRecordShadow?

    private enum CodingKeys: String, CodingKey {
        case id, recordType, schemaVersion, routingFields, encryptedFields, assetFields
        case removedRoutingFields, removedEncryptedFields, base
    }

    package init(
        id: CloudRecordID,
        recordType: String,
        schemaVersion: Int,
        routingFields: [String: CloudFieldValue],
        encryptedFields: [String: CloudFieldValue],
        assetFields: [String: CloudAssetUpload] = [:],
        removedRoutingFields: Set<String> = [],
        removedEncryptedFields: Set<String> = [],
        base: CloudRecordShadow? = nil
    ) {
        self.id = id
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.routingFields = routingFields
        self.encryptedFields = encryptedFields
        self.assetFields = assetFields
        self.removedRoutingFields = removedRoutingFields
        self.removedEncryptedFields = removedEncryptedFields
        self.base = base
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CloudRecordID.self, forKey: .id)
        recordType = try container.decode(String.self, forKey: .recordType)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        routingFields = try container.decode([String: CloudFieldValue].self, forKey: .routingFields)
        encryptedFields = try container.decode(
            [String: CloudFieldValue].self, forKey: .encryptedFields)
        assetFields = try container.decodeIfPresent(
            [String: CloudAssetUpload].self, forKey: .assetFields) ?? [:]
        removedRoutingFields = try container.decodeIfPresent(
            Set<String>.self, forKey: .removedRoutingFields) ?? []
        removedEncryptedFields = try container.decodeIfPresent(
            Set<String>.self, forKey: .removedEncryptedFields) ?? []
        base = try container.decodeIfPresent(CloudRecordShadow.self, forKey: .base)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(recordType, forKey: .recordType)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(routingFields, forKey: .routingFields)
        try container.encode(encryptedFields, forKey: .encryptedFields)
        try container.encode(assetFields, forKey: .assetFields)
        try container.encode(removedRoutingFields, forKey: .removedRoutingFields)
        try container.encode(removedEncryptedFields, forKey: .removedEncryptedFields)
        try container.encodeIfPresent(base, forKey: .base)
    }

    package static func text(
        id: CloudRecordID,
        snipID: UUID,
        text: String,
        base: CloudRecordShadow? = nil
    ) -> CloudRecordDraft {
        CloudRecordDraft(
            id: id,
            recordType: "Snip",
            schemaVersion: 1,
            routingFields: [
                "schemaVersion": .int64(1),
                "snipID": .string(snipID.uuidString.lowercased()),
            ],
            encryptedFields: ["text": .string(text)],
            base: base
        )
    }
}

package struct CloudRecordSnapshot: Codable, Equatable, Sendable {
    package enum Completeness: String, Codable, Equatable, Sendable {
        case full
        case projected
        case legacyUnknown
    }

    package let id: CloudRecordID
    package let recordType: String
    package let schemaVersion: Int
    package let routingFields: [String: CloudFieldValue]
    package let encryptedFields: [String: CloudFieldValue]
    package let assetFields: Set<String>
    package let shadow: CloudRecordShadow
    package let completeness: Completeness

    private enum CodingKeys: String, CodingKey {
        case id, recordType, schemaVersion, routingFields, encryptedFields, assetFields, shadow
        case completeness
    }

    package init(
        id: CloudRecordID,
        recordType: String,
        schemaVersion: Int,
        routingFields: [String: CloudFieldValue],
        encryptedFields: [String: CloudFieldValue],
        assetFields: Set<String>,
        shadow: CloudRecordShadow,
        completeness: Completeness
    ) {
        self.id = id
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.routingFields = routingFields
        self.encryptedFields = encryptedFields
        self.assetFields = assetFields
        self.shadow = shadow
        self.completeness = completeness
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CloudRecordID.self, forKey: .id)
        recordType = try container.decode(String.self, forKey: .recordType)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        routingFields = try container.decode([String: CloudFieldValue].self, forKey: .routingFields)
        encryptedFields = try container.decode(
            [String: CloudFieldValue].self, forKey: .encryptedFields)
        assetFields = try container.decode(Set<String>.self, forKey: .assetFields)
        shadow = try container.decode(CloudRecordShadow.self, forKey: .shadow)
        completeness = try container.decodeIfPresent(Completeness.self, forKey: .completeness)
            ?? .legacyUnknown
    }
}

package enum CloudRecordError: Error, Equatable, Sendable {
    case invalidShadow
    case mismatchedShadow
    case unsupportedValue
    case missingField(String)
    case invalidField(String)
    case projectedSnapshot
    case wrongRecordType
    case invalidAssetDestination
    case missingAsset
}

package enum CloudTransportError: Error, Equatable, Sendable {
    case stateNamespaceMismatch
    case invalidEngineState
    case invalidRecord
    case fetchFailed
    case sendFailed
    case wrongBatchConfirmation
    case notStarted
    case syncAlreadyRunning
}

package struct CloudSyncNamespace: Codable, Equatable, Sendable {
    package let cloudScope: String
    package let accountLineage: String
    package let generation: UUID
    package let zones: Set<CloudZoneID>

    package var namespaceKey: CloudSyncNamespaceKey {
        ICloudSyncNamespaceBinding(
            scope: cloudScope,
            accountLineage: accountLineage,
            generation: generation,
            zones: Set(zones.map {
                ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
            })
        ).namespaceKey
    }
}

package struct CloudEngineStateEnvelope: Codable, Equatable, Sendable {
    package let namespace: CloudSyncNamespace
    package let serialization: Data
}

package enum CloudFetchScope: Codable, Equatable, Sendable {
    case all
    case zones(Set<CloudZoneID>)

    package func contains(_ zone: CloudZoneID) -> Bool {
        switch self {
        case .all: true
        case .zones(let zones): zones.contains(zone)
        }
    }
}

package enum CloudOperationFailure: String, Codable, Equatable, Sendable {
    case retryable
    case quotaExceeded
    case rejected
    case invalidRecord
    case zoneMissing
}

package enum CloudZoneDeletionReason: String, Codable, Equatable, Sendable {
    case deleted
    case purged
    case encryptedDataReset
}

package enum CloudDatabaseEvent: Codable, Equatable, Sendable {
    case zoneChanged(CloudZoneID)
    case zoneDeleted(CloudZoneID, reason: CloudZoneDeletionReason)
    case zoneSaved(CloudZoneID)
    case failed(CloudZoneID?, CloudOperationFailure)
}

package enum CloudZoneEvent: Codable, Equatable, Sendable {
    case fetched(CloudZoneID)
    case failed(CloudZoneID, CloudOperationFailure)
}

package enum CloudFetchItemResult: Codable, Equatable, Sendable {
    case record(CloudRecordSnapshot)
    case deleted(CloudRecordID)
    case failed(CloudRecordID?, CloudOperationFailure)

    package var id: CloudRecordID? {
        switch self {
        case .record(let snapshot): snapshot.id
        case .deleted(let id): id
        case .failed(let id, _): id
        }
    }
}

package struct CloudFetchedBatch: Codable, Equatable, Sendable {
    package let id: UUID
    package let items: [CloudFetchItemResult]
    package let databaseEvents: [CloudDatabaseEvent]
    package let zoneEvents: [CloudZoneEvent]
    package let engineState: CloudEngineStateEnvelope?

    package init(
        id: UUID,
        items: [CloudFetchItemResult],
        databaseEvents: [CloudDatabaseEvent] = [],
        zoneEvents: [CloudZoneEvent] = [],
        engineState: CloudEngineStateEnvelope?
    ) {
        self.id = id
        self.items = items
        self.databaseEvents = databaseEvents
        self.zoneEvents = zoneEvents
        self.engineState = engineState
    }
}

package enum CloudOutboundOperation: Codable, Equatable, Sendable {
    case save(CloudRecordDraft)
    case delete(CloudRecordID, base: CloudRecordShadow?)

    package var id: CloudRecordID {
        switch self {
        case .save(let draft): draft.id
        case .delete(let id, _): id
        }
    }
}

package struct CloudOutboundBatch: Codable, Equatable, Sendable {
    package let operations: [CloudOutboundOperation]
    package let zonesToSave: Set<CloudZoneID>

    package init(
        operations: [CloudOutboundOperation],
        zonesToSave: Set<CloudZoneID> = []
    ) {
        self.operations = operations
        self.zonesToSave = zonesToSave
    }
}

package enum CloudSendItemResult: Codable, Equatable, Sendable {
    case saved(CloudRecordSnapshot)
    case deleted(CloudRecordID)
    case conflict(CloudRecordID, server: CloudRecordSnapshot)
    case unknownItem(CloudRecordID)
    case failed(CloudRecordID, CloudOperationFailure)

    package var id: CloudRecordID {
        switch self {
        case .saved(let snapshot): snapshot.id
        case .deleted(let id), .unknownItem(let id), .failed(let id, _): id
        case .conflict(let id, _): id
        }
    }
}

package struct CloudSentBatch: Codable, Equatable, Sendable {
    package let id: UUID
    package let items: [CloudSendItemResult]
    package let databaseEvents: [CloudDatabaseEvent]
    package let zoneEvents: [CloudZoneEvent]
    package let engineState: CloudEngineStateEnvelope?

    package init(
        id: UUID,
        items: [CloudSendItemResult],
        databaseEvents: [CloudDatabaseEvent] = [],
        zoneEvents: [CloudZoneEvent] = [],
        engineState: CloudEngineStateEnvelope?
    ) {
        self.id = id
        self.items = items
        self.databaseEvents = databaseEvents
        self.zoneEvents = zoneEvents
        self.engineState = engineState
    }
}

package enum CloudSyncBatch: Codable, Equatable, Sendable {
    case fetched(CloudFetchedBatch)
    case sent(CloudSentBatch)

    package var id: UUID {
        switch self {
        case .fetched(let batch): batch.id
        case .sent(let batch): batch.id
        }
    }

    package var engineState: CloudEngineStateEnvelope? {
        switch self {
        case .fetched(let batch): batch.engineState
        case .sent(let batch): batch.engineState
        }
    }
}

package struct CloudAssetDestination: Equatable, Sendable {
    package let directoryURL: URL

    package init(validating directoryURL: URL) throws {
        let values = try directoryURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CloudRecordError.invalidAssetDestination
        }
        self.directoryURL = directoryURL.standardizedFileURL
    }
}

package struct CloudAssetReceipt: Codable, Equatable, Sendable {
    package let recordID: CloudRecordID
    package let field: String
    package let fileURL: URL
    package let byteCount: Int64
    package let sha256: Data
}

package protocol CloudRecordTransport: Sendable {
    func start(state: CloudEngineStateEnvelope?) async throws
    func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch
    func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch
    func confirmApplied(_ batchID: UUID) async throws
    func fetchRecord(_ id: CloudRecordID, fields: Set<String>) async throws -> CloudRecordSnapshot?
    func fetchAsset(
        _ id: CloudRecordID,
        field: String,
        destination: CloudAssetDestination
    ) async throws -> CloudAssetReceipt?
}
