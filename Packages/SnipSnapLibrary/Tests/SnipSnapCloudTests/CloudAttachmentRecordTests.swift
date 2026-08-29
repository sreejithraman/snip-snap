import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

final class CloudAttachmentRecordTests: XCTestCase {
  func testPayloadIsOpaqueAndMetadataKeepsUserFieldsEncrypted() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudAttachmentRecordTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("private note.txt")
    try Data("private".utf8).write(to: source)
    let attachmentID = UUID()
    let payload = CloudTextStorageIdentity(
      zoneName: "payload-zone",
      ownerName: "owner",
      recordName: UUID().uuidString.lowercased()
    )
    let metadata = CloudTextStorageIdentity(
      zoneName: "data-zone",
      ownerName: "owner",
      recordName: "a-\(attachmentID.uuidString.lowercased())"
    )
    let publication = CloudAttachmentPublication(
      metadata: CloudAttachmentMetadataValue(
        attachmentID: attachmentID,
        snipID: UUID(),
        position: 0,
        fileName: source.lastPathComponent,
        contentType: "text/plain",
        byteCount: 7,
        sha256: Data(repeating: 1, count: 32),
        payloadIdentity: payload
      ),
      metadataIdentity: metadata,
      sourceURL: source,
      payloadAccepted: false,
      payloadShadowData: nil,
      metadataAccepted: false,
      metadataShadowData: nil,
      revision: 1
    )

    let payloadDraft = try CloudAttachmentRecordCodec.payloadDraft(publication)
    XCTAssertEqual(payloadDraft.id.name, payload.recordName)
    XCTAssertNotEqual(payloadDraft.id.name, attachmentID.uuidString.lowercased())
    XCTAssertEqual(payloadDraft.routingFields, ["schemaVersion": CloudFieldValue.int64(1)])
    XCTAssertTrue(payloadDraft.encryptedFields.isEmpty)
    XCTAssertEqual(Set(payloadDraft.assetFields.keys), ["payload"])

    let metadataDraft = try CloudAttachmentRecordCodec.metadataDraft(publication)
    XCTAssertEqual(metadataDraft.id.zone.name, "data-zone")
    XCTAssertEqual(metadataDraft.routingFields, ["schemaVersion": CloudFieldValue.int64(1)])
    XCTAssertTrue(metadataDraft.assetFields.isEmpty)
    XCTAssertEqual(
      metadataDraft.encryptedFields["fileName"],
      CloudFieldValue.string("private note.txt")
    )
    XCTAssertEqual(
      metadataDraft.encryptedFields["payloadRecordName"],
      CloudFieldValue.string(payload.recordName)
    )
  }

  func testMetadataDraftRejectsCorruptServerShadow() throws {
    let attachmentID = UUID()
    let publication = CloudAttachmentPublication(
      metadata: CloudAttachmentMetadataValue(
        attachmentID: attachmentID,
        snipID: UUID(),
        position: 0,
        fileName: "file.txt",
        contentType: "text/plain",
        byteCount: 1,
        sha256: Data(repeating: 1, count: 32),
        payloadIdentity: CloudTextStorageIdentity(
          zoneName: "payload-zone",
          ownerName: "owner",
          recordName: UUID().uuidString.lowercased()
        )
      ),
      metadataIdentity: CloudTextStorageIdentity(
        zoneName: "data-zone",
        ownerName: "owner",
        recordName: "a-\(attachmentID.uuidString.lowercased())"
      ),
      sourceURL: nil,
      payloadAccepted: true,
      payloadShadowData: nil,
      metadataAccepted: false,
      metadataShadowData: Data("not a shadow".utf8),
      revision: 1
    )

    XCTAssertThrowsError(try CloudAttachmentRecordCodec.metadataDraft(publication))
  }

  func testMetadataDecoderDistinguishesMissingFieldsFromInvalidValues() throws {
    let publication = CloudAttachmentPublication(
      metadata: CloudAttachmentMetadataValue(
        attachmentID: UUID(),
        snipID: UUID(),
        position: 0,
        fileName: "file.txt",
        contentType: "text/plain",
        byteCount: 1,
        sha256: Data(repeating: 1, count: 32),
        payloadIdentity: CloudTextStorageIdentity(
          zoneName: "payload-zone",
          ownerName: "owner",
          recordName: UUID().uuidString.lowercased()
        )
      ),
      metadataIdentity: CloudTextStorageIdentity(
        zoneName: "data-zone",
        ownerName: "owner",
        recordName: "a-\(UUID().uuidString.lowercased())"
      ),
      sourceURL: nil,
      payloadAccepted: true,
      payloadShadowData: nil,
      metadataAccepted: false,
      metadataShadowData: nil,
      revision: 1
    )
    let valid = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudAttachmentRecordCodec.metadataDraft(publication))
    )

    var missingFields = valid.encryptedFields
    missingFields["fileName"] = nil
    XCTAssertThrowsError(
      try CloudAttachmentRecordCodec.metadata(from: snapshot(valid, fields: missingFields))
    ) { error in
      XCTAssertEqual(error as? CloudRecordError, .missingField("fileName"))
    }

    let invalidValues: [(String, CloudFieldValue)] = [
      ("fileName", .int64(1)),
      ("byteCount", .string("1")),
      ("byteCount", .int64(-1)),
      ("sha256", .string("not-data")),
      ("sha256", .data(Data(repeating: 1, count: 31))),
    ]
    for (key, value) in invalidValues {
      var fields = valid.encryptedFields
      fields[key] = value
      XCTAssertThrowsError(
        try CloudAttachmentRecordCodec.metadata(from: snapshot(valid, fields: fields))
      ) { error in
        XCTAssertEqual(error as? CloudRecordError, .invalidField(key))
      }
    }
  }

  private func snapshot(
    _ snapshot: CloudRecordSnapshot,
    fields: [String: CloudFieldValue]
  ) -> CloudRecordSnapshot {
    CloudRecordSnapshot(
      id: snapshot.id,
      recordType: snapshot.recordType,
      schemaVersion: snapshot.schemaVersion,
      routingFields: snapshot.routingFields,
      encryptedFields: fields,
      assetFields: snapshot.assetFields,
      shadow: snapshot.shadow,
      completeness: snapshot.completeness
    )
  }
}
