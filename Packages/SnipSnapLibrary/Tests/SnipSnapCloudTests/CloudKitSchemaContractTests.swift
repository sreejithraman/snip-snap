import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

final class CloudKitSchemaContractTests: XCTestCase {
  func testCheckedSchemaMatchesEveryRuntimeRecordFieldAndStorageClass() throws {
    let schemaURL = repositoryRoot
      .appendingPathComponent("CloudKit", isDirectory: true)
      .appendingPathComponent("SnipSnap.ckdb", isDirectory: false)
    let text = try String(contentsOf: schemaURL, encoding: .utf8)
    let declared = try parseSchema(text)
    let runtime = try runtimeFields()

    XCTAssertEqual(declared, runtime)
    XCTAssertEqual(Set(declared.keys), [
      "Snip", "List", "AttachmentMetadata", "AttachmentPayload",
      "SnipSnapCollectionControl",
    ])
    XCTAssertFalse(text.contains("QUERYABLE"))
    XCTAssertFalse(text.contains("SORTABLE"))
    XCTAssertFalse(text.contains("SEARCHABLE"))
    XCTAssertFalse(text.contains("snips-"))
    XCTAssertFalse(text.contains("payloads-"))
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func runtimeFields() throws -> [String: [String: FieldContract]] {
    let metadataZone = CloudZoneID(name: "metadata", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let snip = Snip(
      content: "private text",
      origin: .share,
      source: SnipSource(applicationName: "Source", windowTitle: "Window", url: "source://1")
    )
    let list = SnipList(
      id: UUID(),
      name: "Private list",
      systemImage: "folder",
      position: 1
    )
    let payloadURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("SchemaPayload-\(UUID().uuidString)")
    try Data("payload".utf8).write(to: payloadURL)
    defer { try? FileManager.default.removeItem(at: payloadURL) }
    let payloadIdentity = CloudTextStorageIdentity(
      zoneName: payloadZone.name,
      ownerName: payloadZone.ownerName,
      recordName: "payload-record"
    )
    let metadataIdentity = CloudTextStorageIdentity(
      zoneName: metadataZone.name,
      ownerName: metadataZone.ownerName,
      recordName: "metadata-record"
    )
    let publication = CloudAttachmentPublication(
      metadata: CloudAttachmentMetadataValue(
        attachmentID: UUID(),
        snipID: snip.id,
        position: 0,
        fileName: "private.txt",
        contentType: "text/plain",
        byteCount: 7,
        sha256: Data(repeating: 1, count: 32),
        payloadIdentity: payloadIdentity
      ),
      metadataIdentity: metadataIdentity,
      sourceURL: payloadURL,
      payloadAccepted: false,
      payloadShadowData: nil,
      metadataAccepted: false,
      metadataShadowData: nil,
      revision: 1
    )
    let controlID = CloudRecordID(
      zone: CloudZoneID(name: "SnipSnapControl", ownerName: "owner"),
      name: "active-collection"
    )
    let control = try CloudCollectionControlCodec.record(
      CloudCollectionDescriptor(
        generation: UUID(),
        metadataZone: metadataZone,
        payloadZone: payloadZone
      ),
      id: controlID,
      replacing: nil
    )
    let records = [
      try CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: metadataZone)),
      try CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(list, updatedAt: Date(), in: metadataZone)
      ),
      try CloudKitRecordMapper.record(for: CloudAttachmentRecordCodec.metadataDraft(publication)),
      try CloudKitRecordMapper.record(for: CloudAttachmentRecordCodec.payloadDraft(publication)),
      control,
    ]
    return try Dictionary(uniqueKeysWithValues: records.map { record in
      (record.recordType, try fieldContracts(record))
    })
  }

  private func fieldContracts(_ record: CKRecord) throws -> [String: FieldContract] {
    var result: [String: FieldContract] = [:]
    for key in record.allKeys() {
      guard let value = record[key] else { continue }
      if value is CKAsset {
        result[key] = .asset
      } else {
        result[key] = .ordinary(try valueType(value, key: key))
      }
    }
    for key in record.encryptedValues.allKeys() {
      guard let value = record.encryptedValues[key] else { continue }
      result[key] = .encrypted(try valueType(value, key: key))
    }
    return result
  }

  private func valueType(
    _ value: Any,
    key: String
  ) throws -> String {
    switch value {
    case is String, is NSString: return "STRING"
    case is Int64, is NSNumber: return "INT64"
    case is Data, is NSData: return "BYTES"
    default: throw SchemaError.unknownRuntimeType(key, String(reflecting: type(of: value)))
    }
  }

  private func parseSchema(_ text: String) throws -> [String: [String: FieldContract]] {
    var records: [String: [String: FieldContract]] = [:]
    var currentType: String?
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("//") || line == "DEFINE SCHEMA" { continue }
      if line.hasPrefix("RECORD TYPE "), line.hasSuffix("(") {
        let name = line.dropFirst("RECORD TYPE ".count).dropLast()
          .trimmingCharacters(in: .whitespaces)
        currentType = name
        records[name] = [:]
        continue
      }
      if line == ");" {
        currentType = nil
        continue
      }
      guard let currentType else { throw SchemaError.invalidLine(line) }
      let cleaned = line.hasSuffix(",") ? String(line.dropLast()) : line
      let parts = cleaned.split(separator: " ").map(String.init)
      let field: FieldContract
      let name: String
      if parts.count == 3, parts[1] == "ENCRYPTED" {
        name = parts[0]
        field = .encrypted(parts[2])
      } else if parts.count == 2, parts[1] == "ASSET" {
        name = parts[0]
        field = .asset
      } else if parts.count == 2 {
        name = parts[0]
        field = .ordinary(parts[1])
      } else {
        throw SchemaError.invalidLine(line)
      }
      records[currentType]?[name] = field
    }
    guard currentType == nil else { throw SchemaError.unclosedRecord }
    return records
  }
}

private enum FieldContract: Equatable {
  case ordinary(String)
  case encrypted(String)
  case asset
}

private enum SchemaError: Error {
  case invalidLine(String)
  case unknownRuntimeType(String, String)
  case unclosedRecord
}
