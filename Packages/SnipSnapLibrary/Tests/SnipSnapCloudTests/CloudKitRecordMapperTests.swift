import CloudKit
@testable import SnipSnapCloud
import XCTest

final class CloudKitRecordMapperTests: XCTestCase {
    func testTextUsesEncryptedFieldAndOpaqueRandomRecordName() throws {
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        let snipID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let firstID = CloudRecordID.random(in: zone)
        let secondID = CloudRecordID.random(in: zone)
        let record = try CloudKitRecordMapper.record(
            for: .text(id: firstID, snipID: snipID, text: "private text")
        )

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertNotEqual(firstID.name, snipID.uuidString.lowercased())
        XCTAssertNotNil(UUID(uuidString: firstID.name))
        XCTAssertNil(record["text"])
        XCTAssertEqual(record.encryptedValues["text"] as? String, "private text")
        XCTAssertEqual(record["schemaVersion"] as? Int64, 1)
    }

    func testSnapshotRoundTripsThroughCredentialFreeCloudKitMapping() throws {
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        let draft = CloudRecordDraft.text(
            id: .random(in: zone),
            snipID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            text: "round trip"
        )

        let snapshot = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: draft)
        )
        let text = try CloudTextRecord(snapshot: snapshot)

        XCTAssertEqual(text.snipID, UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        XCTAssertEqual(text.text, "round trip")
    }
}
