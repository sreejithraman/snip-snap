import CoreData
import Foundation
import SwiftData
import XCTest

@testable import SnipSnapPersistence

/// Pins the persisted schema of the legacy text record. Computed properties added outside the
/// class body, such as protocol extension members, are not persisted.
final class StoredCloudTextRecordSchemaTests: XCTestCase {
  private static let entityName = "StoredCloudTextRecord"

  func testStoredCloudTextRecordPersistsOnlyItsStoredFields() throws {
    let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
    let entity = try XCTUnwrap(schema.entitiesByName[Self.entityName])
    let expected: Set<String> = [
      "id", "namespaceKey", "zoneName", "ownerName", "recordName", "snipID", "schemaVersion",
      "acceptedText", "shadowData", "systemFields", "recoveryData",
    ]
    XCTAssertEqual(Set(entity.storedProperties.map { $0.name }), expected)
    XCTAssertFalse(entity.properties.map { $0.name }.contains("hasServerState"))
  }

  func testStoredCloudTextRecordVersionHashIsUnchanged() throws {
    let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
    let model = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: schema))
    let hash = try XCTUnwrap(model.entitiesByName[Self.entityName]?.versionHash)
    print("SM27-F3 StoredCloudTextRecord versionHash=\(hash.base64EncodedString())")
    XCTAssertFalse(hash.isEmpty)
  }
}
