import CloudKit
import Foundation
@testable import SnipSnapCloud
@testable import SnipSnapCore
import XCTest

final class CloudFullRecordTests: XCTestCase {
  func testCanonicalIDsAreStableAcrossClientsAndLegacyNamesAreQuarantined() {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let id = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    XCTAssertEqual(CloudRecordID.snip(id, in: zone), CloudRecordID.snip(id, in: zone))
    XCTAssertEqual(CloudRecordID.snip(id, in: zone).name, "s-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    XCTAssertEqual(CloudRecordID.list(id, in: zone).name, "l-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    XCTAssertEqual(CloudRecordID.snip(id, in: zone).binding(for: id, kind: .snip), .canonical)
    XCTAssertEqual(
      CloudRecordID(zone: zone, name: UUID().uuidString.lowercased())
        .binding(for: id, kind: .snip),
      .legacyQuarantined
    )
  }

  func testTypedSnipRoundTripTracksPresenceAndExplicitSourceClearWithoutTouchingAsset() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let attachmentURL = directory.appendingPathComponent("proof.bin")
    let attachmentBytes = Data([0, 1, 2, 255])
    try attachmentBytes.write(to: attachmentURL)
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let snipID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    let recordID = CloudRecordID.snip(snipID, in: zone)
    let sourceRecord = CKRecord(
      recordType: "Snip",
      recordID: CloudKitRecordMapper.recordID(for: recordID)
    )
    sourceRecord["schemaVersion"] = Int64(7)
    sourceRecord["snipID"] = snipID.uuidString.lowercased()
    sourceRecord["futureRouting"] = "keep ordinary"
    sourceRecord.encryptedValues["sourceState"] = Int64(1)
    sourceRecord.encryptedValues["sourceValue"] = try JSONEncoder().encode(
      SnipSource(applicationName: "Before")
    )
    sourceRecord.encryptedValues["futurePrivate"] = "keep encrypted"
    sourceRecord["attachment"] = CKAsset(fileURL: attachmentURL)
    let snip = Snip(
      id: snipID,
      requestID: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
      createdAt: Date(timeIntervalSince1970: 10),
      updatedAt: Date(timeIntervalSince1970: 20),
      content: "text",
      origin: .share,
      source: nil,
      listID: SnipList.inboxID,
      isDone: true,
      manualSortKey: SnipOrderKey(rawDigits: [64])
    )

    let accepted = try CloudFullRecordCodec.snip(
      from: CloudKitRecordMapper.snapshot(sourceRecord))
    let draft = try CloudFullRecordCodec.snipDraft(snip, accepted: accepted)
    let edited = try CloudKitRecordMapper.record(for: draft)
    let typed = try CloudFullRecordCodec.snip(
      from: CloudKitRecordMapper.snapshot(edited)
    )

    XCTAssertEqual(typed.source, .value(nil))
    XCTAssertEqual(typed.placement, .value(CloudSnipPlacement(
      listID: SnipList.inboxID, orderKey: snip.manualSortKey)))
    XCTAssertNil(edited.encryptedValues["sourceValue"])
    XCTAssertEqual(edited.encryptedValues["sourceState"] as? Int64, 0)
    XCTAssertEqual(edited["futureRouting"] as? String, "keep ordinary")
    XCTAssertEqual(edited.encryptedValues["futurePrivate"] as? String, "keep encrypted")
    XCTAssertEqual((edited["attachment"] as? CKAsset)?.fileURL, attachmentURL)
    XCTAssertEqual(try Data(contentsOf: attachmentURL), attachmentBytes)
    XCTAssertEqual(edited["schemaVersion"] as? Int64, 7)
  }

  func testOldTypedSnipKeepsMissingKnownFieldsDistinctFromExplicitClear() throws {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let id = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
    let record = CKRecord(
      recordType: "Snip",
      recordID: CloudKitRecordMapper.recordID(for: .snip(id, in: zone))
    )
    record["schemaVersion"] = Int64(1)
    record["snipID"] = id.uuidString.lowercased()
    record.encryptedValues["text"] = "old"

    let typed = try CloudFullRecordCodec.snip(from: CloudKitRecordMapper.snapshot(record))

    XCTAssertEqual(typed.text, .value("old"))
    XCTAssertEqual(typed.source, .missing)
    XCTAssertEqual(typed.placement, .missing)
    XCTAssertEqual(typed.requestID, .missing)
  }

  func testOldStagedDraftDecodesWithEmptyRemovalSets() throws {
    let draft = CloudRecordDraft.text(
      id: .random(in: CloudZoneID(name: "metadata", ownerName: "owner")),
      snipID: UUID(),
      text: "legacy"
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    object.removeValue(forKey: "removedRoutingFields")
    object.removeValue(forKey: "removedEncryptedFields")

    let decoded = try JSONDecoder().decode(
      CloudRecordDraft.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertEqual(decoded.removedRoutingFields, [])
    XCTAssertEqual(decoded.removedEncryptedFields, [])
  }

  func testTypedListRoundTripCarriesDesiredNameAndOrderKey() throws {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let list = SnipList(
      id: UUID(uuidString: "abababab-abab-abab-abab-abababababab")!,
      name: "  Wörk  ",
      systemImage: "briefcase",
      position: 0,
      sortKey: SnipOrderKey(rawDigits: [72])
    )
    let updatedAt = Date(timeIntervalSince1970: 33)

    let typed = try CloudFullRecordCodec.list(from: CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: try CloudFullRecordCodec.listDraft(
        list, updatedAt: updatedAt, in: zone))))

    XCTAssertEqual(typed.binding, .canonical)
    XCTAssertEqual(typed.desiredName, .value("Wörk"))
    XCTAssertEqual(typed.systemImage, .value("briefcase"))
    XCTAssertEqual(typed.orderKey, .value(list.sortKey))
    XCTAssertEqual(typed.updatedAt, .value(updatedAt))
  }

  func testSnipMergeCombinesIndependentGroupsAndTreatsPlacementAtomically() throws {
    let base = snipFields(text: "base", source: nil, isDone: false,
                          listID: SnipList.inboxID, key: [64], updatedAt: 1)
    var local = base
    local.text = "local text"
    local.placement = CloudSnipPlacement(listID: UUID(), orderKey: SnipOrderKey(rawDigits: [80]))
    local.updatedAt = Date(timeIntervalSince1970: 900)
    var server = base
    server.source = SnipSource(applicationName: "Server")
    server.isDone = true
    server.updatedAt = Date(timeIntervalSince1970: 2)

    let result = try CloudThreeWayMerge.snip(base: base, local: local, server: server)

    XCTAssertEqual(result.merged.text, "local text")
    XCTAssertEqual(result.merged.source?.applicationName, "Server")
    XCTAssertTrue(result.merged.isDone)
    XCTAssertEqual(result.merged.placement, local.placement)
    XCTAssertEqual(result.merged.updatedAt, server.updatedAt)
    XCTAssertNil(result.conflict)
  }

  func testSnipSameFieldConflictKeepsServerAndReturnsLocalPayloadButOrderOnlyDoesNotWarn() throws {
    let base = snipFields(text: "base", source: nil, isDone: false,
                          listID: SnipList.inboxID, key: [64], updatedAt: 1)
    var local = base
    local.text = "local"
    local.placement.orderKey = SnipOrderKey(rawDigits: [80])
    var server = base
    server.text = "server"
    server.placement.orderKey = SnipOrderKey(rawDigits: [96])

    let result = try CloudThreeWayMerge.snip(base: base, local: local, server: server)

    XCTAssertEqual(result.merged.text, "server")
    XCTAssertEqual(result.merged.placement, server.placement)
    XCTAssertEqual(result.conflict?.fields, [.text])
    XCTAssertEqual(result.conflict?.local.text, "local")
  }

  func testPlacementListConflictAndListNameConflictProduceDurablePayloads() throws {
    let base = snipFields(text: "base", source: nil, isDone: false,
                          listID: SnipList.inboxID, key: [64], updatedAt: 1)
    var local = base
    local.placement = CloudSnipPlacement(listID: UUID(), orderKey: SnipOrderKey(rawDigits: [80]))
    var server = base
    server.placement = CloudSnipPlacement(listID: UUID(), orderKey: SnipOrderKey(rawDigits: [96]))

    let snipResult = try CloudThreeWayMerge.snip(base: base, local: local, server: server)
    XCTAssertEqual(snipResult.conflict?.fields, [.placement])
    XCTAssertEqual(snipResult.merged.placement, server.placement)

    let listID = UUID()
    let listBase = CloudListMergeFields(
      id: listID, desiredName: "Work", systemImage: "folder",
      orderKey: SnipOrderKey(rawDigits: [64]), updatedAt: Date(timeIntervalSince1970: 1))
    var listLocal = listBase
    listLocal.desiredName = "Local"
    var listServer = listBase
    listServer.desiredName = "Server"
    let listResult = try CloudThreeWayMerge.list(
      base: listBase, local: listLocal, server: listServer)
    XCTAssertEqual(listResult.merged.desiredName, "Server")
    XCTAssertEqual(listResult.conflict?.fields, [.desiredName])
    XCTAssertEqual(listResult.conflict?.local.desiredName, "Local")
  }

  func testImmutableSnipMetadataMismatchIsRejectedAndUpdatedAtNeverCreatesConflict() throws {
    let base = snipFields(text: "base", source: nil, isDone: false,
                          listID: SnipList.inboxID, key: [64], updatedAt: 1)
    var local = base
    local.updatedAt = Date(timeIntervalSince1970: 100)
    var server = base
    server.updatedAt = Date(timeIntervalSince1970: 200)
    XCTAssertNil(try CloudThreeWayMerge.snip(base: base, local: local, server: server).conflict)

    server.requestID = UUID()
    XCTAssertThrowsError(try CloudThreeWayMerge.snip(base: base, local: local, server: server)) {
      XCTAssertEqual($0 as? CloudMergeError, .immutableMetadata)
    }
  }

  func testListMergeRejectsEveryIdentityMismatch() {
    let base = CloudListMergeFields(
      id: UUID(), desiredName: "Work", systemImage: "folder",
      orderKey: SnipOrderKey(rawDigits: [64]), updatedAt: .distantPast)
    var local = base
    local.id = UUID()
    XCTAssertThrowsError(try CloudThreeWayMerge.list(base: base, local: local, server: base))
    var server = base
    server.id = UUID()
    XCTAssertThrowsError(try CloudThreeWayMerge.list(base: base, local: base, server: server))
  }

  func testProjectedSnapshotCannotBecomeAnAcceptedTypedBase() throws {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let snip = Snip(content: "text", origin: .quickEntry)
    let record = try CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    let projected = try CloudKitRecordMapper.snapshot(
      record, desiredFields: ["schemaVersion", "snipID", "text"])

    XCTAssertEqual(projected.completeness, .projected)
    XCTAssertThrowsError(try CloudFullRecordCodec.snip(from: projected)) {
      XCTAssertEqual($0 as? CloudRecordError, .projectedSnapshot)
    }
  }

  func testLegacyBindingAndUnknownOriginSurviveNewOldNewEdit() throws {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let snipID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
    let legacyID = CloudRecordID(zone: zone, name: UUID().uuidString.lowercased())
    let baseSnip = Snip(
      id: snipID,
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2),
      content: "before",
      origin: .quickEntry,
      listID: SnipList.inboxID,
      manualSortKey: SnipOrderKey(rawDigits: [64])
    )
    let newDraft = try CloudFullRecordCodec.snipDraft(baseSnip, in: zone)
    let first = try CloudKitRecordMapper.record(for: CloudRecordDraft(
      id: legacyID,
      recordType: newDraft.recordType,
      schemaVersion: newDraft.schemaVersion,
      routingFields: newDraft.routingFields,
      encryptedFields: newDraft.encryptedFields,
      removedEncryptedFields: newDraft.removedEncryptedFields
    ))
    first["schemaVersion"] = Int64(7)
    first["futureRouting"] = "keep"
    first.encryptedValues["origin"] = "future-origin"
    first.encryptedValues["futurePrivate"] = "keep private"
    let accepted = try CloudFullRecordCodec.snip(from: CloudKitRecordMapper.snapshot(first))
    guard case .value = accepted.origin else {
      return XCTFail("Expected an accepted raw origin.")
    }
    XCTAssertEqual(accepted.localOriginFallback, .quickEntry)

    var editedSnip = baseSnip
    editedSnip.content = "after"
    let edited = try CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(
      editedSnip,
      accepted: accepted
    ))

    XCTAssertEqual(CloudKitRecordMapper.id(for: edited.recordID), legacyID)
    XCTAssertEqual(edited.encryptedValues["origin"] as? String, "future-origin")
    XCTAssertEqual(edited.encryptedValues["text"] as? String, "after")
    XCTAssertEqual(edited["futureRouting"] as? String, "keep")
    XCTAssertEqual(edited.encryptedValues["futurePrivate"] as? String, "keep private")
    XCTAssertEqual(edited["schemaVersion"] as? Int64, 7)
  }

  func testTypedStorageRoundTripKeepsPresenceAndVersion() throws {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let id = UUID()
    let record = CKRecord(
      recordType: "Snip",
      recordID: CloudKitRecordMapper.recordID(for: .snip(id, in: zone)))
    record["schemaVersion"] = Int64(1)
    record["snipID"] = id.uuidString.lowercased()
    record.encryptedValues["sourceState"] = Int64(0)
    let typed = try CloudFullRecordCodec.snip(from: CloudKitRecordMapper.snapshot(record))

    let reopened = try JSONDecoder().decode(
      CloudTypedSnipRecord.self, from: JSONEncoder().encode(typed))

    XCTAssertEqual(reopened, typed)
    XCTAssertEqual(reopened.storageVersion, 1)
    XCTAssertEqual(reopened.source, .value(nil))
    XCTAssertEqual(reopened.text, .missing)
  }

  func testConflictKeyUsesNamespaceRecordAndBothSystemIdentities() {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let recordID = CloudRecordID.snip(UUID(), in: zone)
    let first = CloudConflictKey.make(
      namespaceKey: "namespace",
      recordID: recordID,
      ancestorSystemFields: Data([1]),
      serverSystemFields: Data([2]))
    let same = CloudConflictKey.make(
      namespaceKey: "namespace",
      recordID: recordID,
      ancestorSystemFields: Data([1]),
      serverSystemFields: Data([2]))
    let next = CloudConflictKey.make(
      namespaceKey: "namespace",
      recordID: recordID,
      ancestorSystemFields: Data([1]),
      serverSystemFields: Data([3]))

    XCTAssertEqual(first, same)
    XCTAssertNotEqual(first, next)
  }

  func testFullRecordDraftCannotRemoveOwnedDataOrNameAttachmentFields() throws {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let snip = Snip(content: "text", origin: .quickEntry)
    let draft = try CloudFullRecordCodec.snipDraft(snip, in: zone)

    XCTAssertTrue(draft.assetFields.isEmpty)
    XCTAssertFalse(draft.routingFields.keys.contains { $0.localizedCaseInsensitiveContains("attachment") })
    XCTAssertFalse(draft.encryptedFields.keys.contains { $0.localizedCaseInsensitiveContains("attachment") })
    XCTAssertThrowsError(try CloudKitRecordMapper.record(for: CloudRecordDraft(
      id: draft.id,
      recordType: draft.recordType,
      schemaVersion: draft.schemaVersion,
      routingFields: draft.routingFields,
      encryptedFields: draft.encryptedFields,
      removedRoutingFields: ["snipID"]
    )))
    XCTAssertThrowsError(try CloudKitRecordMapper.record(for: CloudRecordDraft(
      id: draft.id,
      recordType: draft.recordType,
      schemaVersion: draft.schemaVersion,
      routingFields: draft.routingFields,
      encryptedFields: draft.encryptedFields,
      removedEncryptedFields: ["text"]
    )))
    let listID = UUID()
    XCTAssertThrowsError(try CloudKitRecordMapper.record(for: CloudRecordDraft(
      id: .list(listID, in: zone),
      recordType: "List",
      schemaVersion: 2,
      routingFields: ["listID": .string(listID.uuidString.lowercased())],
      encryptedFields: [:],
      removedEncryptedFields: ["sourceValue"]
    )))
  }

  private func snipFields(
    text: String,
    source: SnipSource?,
    isDone: Bool,
    listID: UUID,
    key: [UInt8],
    updatedAt: TimeInterval
  ) -> CloudSnipMergeFields {
    CloudSnipMergeFields(
      id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
      requestID: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
      createdAt: Date(timeIntervalSince1970: 0),
      originRaw: SnipOrigin.quickEntry.rawValue,
      text: text,
      source: source,
      isDone: isDone,
      placement: CloudSnipPlacement(listID: listID, orderKey: SnipOrderKey(rawDigits: key)),
      updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
  }
}
