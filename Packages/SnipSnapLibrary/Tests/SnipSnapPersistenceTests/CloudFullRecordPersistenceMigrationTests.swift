import Foundation
import SwiftData
import XCTest

@testable import SnipSnapCore
@testable import SnipSnapPersistence

extension CloudFullRecordPersistenceTests {
  func testV3StoreMigratesToPendingDeleteSchemaWithoutChangingAcceptedRecords() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
    let namespace = "private|account-a|generation-v4"
    let accepted = entity(.snip, UUID(), identity("v3-record"))

    do {
      let schema = Schema(versionedSchema: SnipSnapSchemaV3.self)
      let configuration = ModelConfiguration(
        "Legacy",
        schema: schema,
        url: location.store,
        cloudKitDatabase: .none
      )
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let context = ModelContext(container)
      context.insert(
        StoredCloudEntityRecord(namespaceKey: namespace, value: accepted, isDeferred: false)
      )
      try context.save()
    }

    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let snapshot = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    let migrated = try XCTUnwrap(snapshot.readyEntities.first)
    XCTAssertEqual(snapshot.readyEntities.count, 1)
    XCTAssertEqual(migrated.reference, accepted.reference)
    XCTAssertEqual(migrated.identity, accepted.identity)
    XCTAssertEqual(migrated.acceptedData, accepted.acceptedData)
    XCTAssertTrue(snapshot.pendingDeletes.isEmpty)
  }

  func testV2TextRecordMaterializesDeterministicV1FieldsWithoutTouchingAttachments() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let namespace = "private|account-a|generation-a"
    let snipID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    let identity = identity("legacy-record")
    let attachmentURL = location.root.appendingPathComponent("Attachments/keep/data.bin")
    try FileManager.default.createDirectory(
      at: attachmentURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let attachmentBytes = Data([0, 1, 2, 3, 255])
    try attachmentBytes.write(to: attachmentURL)
    let attachmentID = UUID()
    let localSnipID = snipID
    let customListID = UUID()
    let stagedPayload = Data("legacy-staged".utf8)
    let recoveryPayload = Data("legacy-recovery".utf8)
    let batchID = UUID()

    do {
      let schema = Schema(versionedSchema: SnipSnapSchemaV2.self)
      let configuration = ModelConfiguration(
        "Legacy",
        schema: schema,
        url: location.store,
        cloudKitDatabase: .none
      )
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let context = ModelContext(container)
      let attachment = SnipAttachment(
        id: attachmentID,
        fileName: "data.bin",
        relativePath: "keep/data.bin",
        contentType: "application/octet-stream",
        byteCount: Int64(attachmentBytes.count)
      )
      let localSnip = Snip(
        id: localSnipID,
        requestID: localSnipID,
        createdAt: Date(timeIntervalSince1970: 5),
        content: "local with attachment",
        origin: .quickEntry,
        listID: customListID,
        attachments: [attachment]
      )
      context.insert(StoredListRecord(.inbox))
      context.insert(
        StoredListRecord(
          SnipList(
            id: customListID,
            name: "Custom",
            systemImage: "folder",
            position: 1
          )
        )
      )
      context.insert(StoredSnipRecord(localSnip))
      context.insert(StoredAttachmentRecord(attachment))
      context.insert(
        StoredSnipAttachmentReference(snipID: localSnipID, attachmentID: attachmentID, position: 0)
      )
      context.insert(StoredRequestRecord(id: localSnipID))
      context.insert(
        StoredCloudTextRecord(
          namespaceKey: namespace,
          identity: identity,
          snipID: snipID,
          schemaVersion: 1,
          acceptedText: "old text",
          shadowData: Data("shadow".utf8),
          systemFields: Data("system".utf8),
          recoveryData: recoveryPayload
        )
      )
      context.insert(
        StoredCloudTextRecord(
          namespaceKey: namespace,
          identity: self.identity("legacy-record-duplicate"),
          snipID: snipID,
          schemaVersion: 1,
          acceptedText: "duplicate text",
          shadowData: Data("duplicate-shadow".utf8),
          systemFields: Data("duplicate-system".utf8)
        )
      )
      context.insert(
        StoredCloudStagedBatch(
          namespaceKey: namespace,
          batchID: batchID,
          payload: stagedPayload
        )
      )
      context.insert(
        StoredCloudRecoveryEvent(
          namespaceKey: namespace,
          eventKey: "legacy-event",
          payload: recoveryPayload
        )
      )
      context.insert(
        try StoredCloudNamespaceState(
          namespaceKey: namespace,
          value: CloudNamespaceStateStorage(
            phase: .seeding,
            approvedSnipIDs: [snipID]
          )
        )
      )
      try context.save()
    }

    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let snapshot = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(snapshot.readyEntities.count, 1)
    XCTAssertEqual(snapshot.conflicts.count, 1)
    let accepted = try XCTUnwrap(snapshot.readyEntities.first)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let value = try decoder.decode(CloudLegacySnipMaterialization.self, from: accepted.acceptedData)
    XCTAssertEqual(value.version, 1)
    XCTAssertEqual(value.snipID, snipID)
    XCTAssertEqual(value.requestID, snipID)
    XCTAssertEqual(value.createdAt, Date(timeIntervalSince1970: 0))
    XCTAssertEqual(value.updatedAt, Date(timeIntervalSince1970: 0))
    XCTAssertEqual(value.content, "old text")
    XCTAssertEqual(value.origin, SnipOrigin.quickEntry.rawValue)
    XCTAssertEqual(value.listID, SnipList.inbox.id)
    XCTAssertFalse(value.isDone)
    XCTAssertEqual(value.remotePresentFields, ["snipID", "text"])
    XCTAssertEqual(value.orderKey, Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x80]))
    XCTAssertEqual(try Data(contentsOf: attachmentURL), attachmentBytes)
    let wire = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
    let stagedEnvelope = try XCTUnwrap(
      CloudWirePayloadEnvelope.decode(try XCTUnwrap(wire.stagedBatches.first).payload)
    )
    let recoveryEnvelope = try XCTUnwrap(
      CloudWirePayloadEnvelope.decode(try XCTUnwrap(wire.recoveryEvents.first).payload)
    )
    let recordEnvelope = try XCTUnwrap(
      CloudWirePayloadEnvelope.decode(
        try XCTUnwrap(wire.records.first(where: { $0.recoveryData != nil })).recoveryData ?? Data()
      )
    )
    XCTAssertEqual(stagedEnvelope.format, .legacyTextV1)
    XCTAssertEqual(stagedEnvelope.payload, stagedPayload)
    XCTAssertEqual(recoveryEnvelope.payload, recoveryPayload)
    XCTAssertEqual(recordEnvelope.payload, recoveryPayload)
    XCTAssertEqual(
      snapshot.enrolledEntities,
      [
        CloudEntityReference(kind: .snip, domainID: snipID),
        CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
        CloudEntityReference(kind: .list, domainID: customListID),
      ]
    )
    let reopened = try SwiftDataSnipLibrary(storeURL: location.store)
    let reopenedFull = try await reopened.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(reopenedFull.readyEntities.count, 1)
    XCTAssertEqual(reopenedFull.conflicts.count, 1)
  }

  func testCloudBackfillRecoversBeforeAndAfterSaveWithoutDoubleWrapping() async throws {
    for crashPoint in CloudFullRecordBackfillPoint.allCases {
      let location = temporaryStore()
      defer { try? FileManager.default.removeItem(at: location.root) }
      let namespace = "private|account-a|generation-a"
      let payload = Data("one legacy payload".utf8)
      try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
      do {
        let schema = Schema(versionedSchema: SnipSnapSchemaV2.self)
        let configuration = ModelConfiguration(
          "Legacy",
          schema: schema,
          url: location.store,
          cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(
          StoredCloudStagedBatch(namespaceKey: namespace, batchID: UUID(), payload: payload)
        )
        try context.save()
      }

      XCTAssertThrowsError(
        try SwiftDataSnipLibrary(
          storeURL: location.store,
          cloudFullRecordBackfillHook: { point in
            if point == crashPoint { throw Crash.expected }
          }
        )
      )
      let reopened = try SwiftDataSnipLibrary(storeURL: location.store)
      let firstSnapshot = try await reopened.cloudTextSyncSnapshot(namespaceKey: namespace)
      let first = try XCTUnwrap(firstSnapshot.stagedBatches.first)
      let envelope = try XCTUnwrap(CloudWirePayloadEnvelope.decode(first.payload))
      XCTAssertEqual(envelope.payload, payload)

      let reopenedAgain = try SwiftDataSnipLibrary(storeURL: location.store)
      let secondSnapshot = try await reopenedAgain.cloudTextSyncSnapshot(namespaceKey: namespace)
      let second = try XCTUnwrap(secondSnapshot.stagedBatches.first)
      XCTAssertEqual(second.payload, first.payload)
    }
  }

  func testActiveLegacyNamespaceWithNoApprovedSnipsEnrollsEveryLocalList() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
    let namespace = "private|account-a|generation-list-only"
    let customList = SnipList(
      id: UUID(),
      name: "Empty",
      systemImage: "tray",
      position: 1
    )
    do {
      let schema = Schema(versionedSchema: SnipSnapSchemaV2.self)
      let configuration = ModelConfiguration(
        "Legacy",
        schema: schema,
        url: location.store,
        cloudKitDatabase: .none
      )
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let context = ModelContext(container)
      context.insert(StoredListRecord(.inbox))
      context.insert(StoredListRecord(customList))
      context.insert(
        try StoredCloudNamespaceState(
          namespaceKey: namespace,
          value: CloudNamespaceStateStorage(phase: .active)
        )
      )
      try context.save()
    }

    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let snapshot = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(
      snapshot.enrolledEntities,
      [
        CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
        CloudEntityReference(kind: .list, domainID: customList.id),
      ]
    )
  }

  func testLegacySeedProvenanceDefaultsToTheOriginalDigestVersion() throws {
    let provenance = SyncModeSeedProvenance(
      sourceSnipID: UUID(),
      candidateSnipID: UUID(),
      candidateRequestID: UUID(),
      baseDigest: Data(repeating: 1, count: 32),
      baseRemoteDigest: Data(repeating: 2, count: 32)
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(provenance)) as? [String: Any]
    )
    object.removeValue(forKey: "digestVersion")
    let oldData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

    let decoded = try JSONDecoder().decode(SyncModeSeedProvenance.self, from: oldData)
    XCTAssertEqual(decoded.digestVersion, 1)
  }

  func testLegacySeedDigestUsesTheStoredV2PositionAfterOrderBackfill() throws {
    let id = UUID()
    let old = Snip(
      id: id,
      requestID: id,
      createdAt: Date(timeIntervalSinceReferenceDate: 10),
      content: "same",
      origin: .quickEntry,
      manualPosition: 42
    )
    let backfilled = Snip(
      id: id,
      requestID: id,
      createdAt: old.createdAt,
      content: old.content,
      origin: old.origin,
      manualSortKey: try XCTUnwrap(SnipOrderKey.rebalanced(count: 1).first)
    )
    let oldDigest = SnipLibraryTransferPlanner.digest(
      snip: old,
      attachmentData: [:],
      version: 1
    )
    let reopenedDigest = SnipLibraryTransferPlanner.digest(
      snip: backfilled,
      attachmentData: [:],
      version: 1,
      legacyManualPosition: 42
    )
    XCTAssertEqual(reopenedDigest, oldDigest)
    XCTAssertNotEqual(
      SnipLibraryTransferPlanner.digest(snip: backfilled, attachmentData: [:], version: 1),
      oldDigest
    )
  }

  func testFutureWireEnvelopeIsNeitherRewrittenNorFedToTheLegacyReader() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
    let namespace = "private|account-a|generation-a"
    let future = Data(
      #"{"format":"futureV2","marker":"snipsnap-cloud-wire","payload":"YWJj","storageVersion":99}"#.utf8
    )
    do {
      let schema = Schema(versionedSchema: SnipSnapSchemaV2.self)
      let configuration = ModelConfiguration(
        "Legacy",
        schema: schema,
        url: location.store,
        cloudKitDatabase: .none
      )
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let context = ModelContext(container)
      context.insert(
        StoredCloudStagedBatch(namespaceKey: namespace, batchID: UUID(), payload: future)
      )
      try context.save()
    }

    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let snapshot = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
    XCTAssertEqual(snapshot.stagedBatches.first?.payload, future)
    XCTAssertTrue(CloudWirePayloadEnvelope.hasEnvelopeMarker(future))
    XCTAssertNil(CloudWirePayloadEnvelope.decode(future))
    XCTAssertNil(CloudWirePayloadEnvelope.legacyPayload(from: future))
  }

}
