import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData


extension SwiftDataSnipLibrary {
  static func backfillCloudFullRecords(context: ModelContext) throws -> Bool {
    let legacy = try context.fetch(FetchDescriptor<StoredCloudTextRecord>())
    let current = try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
    var changed = false
    var identityByDomainKey = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.identityID) })
    var domainKeyByIdentity = Dictionary(uniqueKeysWithValues: current.map { ($0.identityID, $0.id) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    for record in legacy.sorted(by: { $0.id < $1.id }) where record.acceptedText != nil {
      let reference = CloudEntityReference(kind: .snip, domainID: record.snipID)
      let id = StoredCloudEntityRecord.domainKey(
        namespaceKey: record.namespaceKey,
        reference: reference
      )
      let identityID = StoredCloudEntityRecord.identityKey(
        namespaceKey: record.namespaceKey,
        identity: record.identity
      )
      if identityByDomainKey[id] == identityID, domainKeyByIdentity[identityID] == id {
        continue
      }
      if identityByDomainKey[id] != nil || domainKeyByIdentity[identityID] != nil {
        let payload = try encoder.encode(record.identity)
        let conflict = CloudConflictInput(
          key: "legacy-binding|\(record.identity.key)",
          reference: reference,
          format: .legacyBindingV1,
          payload: payload
        )
        try insertConflictIfNeeded(
          conflict,
          namespaceKey: record.namespaceKey,
          context: context
        )
        changed = true
        continue
      }
      guard let text = record.acceptedText,
        let shadow = record.shadowData,
        let systemFields = record.systemFields
      else { throw CloudFullStorageError.invalidLegacyRecord }
      var orderKey = Data()
      withUnsafeBytes(of: record.snipID.uuid) { orderKey.append(contentsOf: $0) }
      orderKey.append(0x80)
      let materialized = CloudLegacySnipMaterialization(
        version: CloudLegacySnipMaterialization.storageVersion,
        snipID: record.snipID,
        requestID: record.snipID,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        content: text,
        origin: SnipOrigin.quickEntry.rawValue,
        listID: SnipList.inbox.id,
        isDone: false,
        orderKey: orderKey,
        remotePresentFields: ["snipID", "text"]
      )
      let data = try encoder.encode(materialized)
      let input = CloudAcceptedEntityInput(
        reference: reference,
        identity: record.identity,
        schemaVersion: record.schemaVersion,
        acceptedData: data,
        presenceData: data,
        shadowData: shadow,
        systemFields: systemFields,
        dependencyListID: SnipList.inbox.id
      )
      context.insert(
        StoredCloudEntityRecord(namespaceKey: record.namespaceKey, value: input, isDeferred: false)
      )
      identityByDomainKey[id] = identityID
      domainKeyByIdentity[identityID] = id
      changed = true
    }
    for record in legacy {
      if let data = record.recoveryData, !CloudWirePayloadEnvelope.hasEnvelopeMarker(data) {
        record.recoveryData = try CloudWirePayloadEnvelope(
          format: .legacyTextV1,
          payload: data
        ).encoded()
        changed = true
      }
    }
    for batch in try context.fetch(FetchDescriptor<StoredCloudStagedBatch>())
      where !CloudWirePayloadEnvelope.hasEnvelopeMarker(batch.payload)
    {
      batch.payload = try CloudWirePayloadEnvelope(
        format: .legacyTextV1,
        payload: batch.payload
      ).encoded()
      changed = true
    }
    for event in try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
      where !CloudWirePayloadEnvelope.hasEnvelopeMarker(event.payload)
    {
      event.payload = try CloudWirePayloadEnvelope(
        format: .legacyTextV1,
        payload: event.payload
      ).encoded()
      changed = true
    }
    let enrollments = try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
    let localLists = try context.fetch(FetchDescriptor<StoredListRecord>())
    let localSnips = Dictionary(uniqueKeysWithValues:
      try context.fetch(FetchDescriptor<StoredSnipRecord>()).map { ($0.id, $0) }
    )
    for state in try context.fetch(FetchDescriptor<StoredCloudNamespaceState>()) {
      guard !enrollments.contains(where: { $0.namespaceKey == state.namespaceKey }) else {
        continue
      }
      let value = try state.value()
      guard value.phase == .seeding || value.phase == .active else { continue }
      var references = Set(value.approvedSnipIDs.map {
        CloudEntityReference(kind: .snip, domainID: $0)
      })
      references.formUnion(localLists.map {
        CloudEntityReference(kind: .list, domainID: $0.id)
      })
      for snipID in value.approvedSnipIDs {
        let listID = localSnips[snipID]?.listID ?? SnipList.inbox.id
        references.insert(CloudEntityReference(kind: .list, domainID: listID))
      }
      context.insert(
        StoredCloudFullEnrollment(
          namespaceKey: state.namespaceKey,
          referencesData: try encoder.encode(references)
        )
      )
      changed = true
    }
    return changed
  }

}

