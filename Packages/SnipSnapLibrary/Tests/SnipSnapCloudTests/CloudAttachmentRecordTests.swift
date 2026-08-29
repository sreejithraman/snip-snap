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

    let metadataDraft = CloudAttachmentRecordCodec.metadataDraft(publication)
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
}
