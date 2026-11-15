import Foundation
import XCTest

@testable import SnipSnapPersistence

final class CloudTextRecordServerFieldsTests: XCTestCase {
  func testARowReachedICloudWhenAnyServerFieldIsSet() {
    let bytes = Data([1])
    XCTAssertFalse(record().hasServerState, "reserved placeholder")
    XCTAssertTrue(record(acceptedText: "text").hasServerState, "acceptedText only")
    XCTAssertTrue(record(shadowData: bytes).hasServerState, "shadowData only")
    XCTAssertTrue(record(systemFields: bytes).hasServerState, "systemFields only")
    XCTAssertFalse(record(recoveryData: bytes).hasServerState, "recoveryData only")
  }

  private func record(
    acceptedText: String? = nil,
    shadowData: Data? = nil,
    systemFields: Data? = nil,
    recoveryData: Data? = nil
  ) -> CloudTextStorageRecord {
    CloudTextStorageRecord(
      identity: CloudTextStorageIdentity(
        zoneName: "SnipSnap",
        ownerName: "owner",
        recordName: "text-record"
      ),
      snipID: UUID(),
      schemaVersion: 1,
      acceptedText: acceptedText,
      shadowData: shadowData,
      systemFields: systemFields,
      recoveryData: recoveryData
    )
  }
}
