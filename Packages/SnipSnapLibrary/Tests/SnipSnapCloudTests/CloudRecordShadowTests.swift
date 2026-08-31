import CloudKit
@testable import SnipSnapCloud
import XCTest

final class CloudRecordShadowTests: XCTestCase {
    func testReopenedShadowKeepsFutureFieldsAndConditionalSystemData() throws {
        let zoneID = CKRecordZone.ID(zoneName: "metadata", ownerName: "owner")
        let recordID = CKRecord.ID(recordName: "opaque-record", zoneID: zoneID)
        let source = CKRecord(recordType: "Snip", recordID: recordID)
        source["schemaVersion"] = Int64(7)
        source["snipID"] = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        source["futureRouting"] = "keep ordinary"
        source.encryptedValues["text"] = "before"
        source.encryptedValues["futurePrivate"] = "keep encrypted"
        let firstShadow = try CloudRecordShadow.archive(source)

        let reopened = try CloudRecordShadow(data: firstShadow.data)
        let edited = try CloudKitRecordMapper.record(
            for: CloudRecordDraft.text(
                id: CloudRecordID(
                    zone: CloudZoneID(name: "metadata", ownerName: "owner"),
                    name: "opaque-record"
                ),
                snipID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                text: "after",
                base: reopened
            )
        )

        XCTAssertEqual(edited["schemaVersion"] as? Int64, 7)
        XCTAssertEqual(edited["futureRouting"] as? String, "keep ordinary")
        XCTAssertEqual(edited.encryptedValues["text"] as? String, "after")
        XCTAssertEqual(edited.encryptedValues["futurePrivate"] as? String, "keep encrypted")
        XCTAssertEqual(edited.recordID, source.recordID)
        XCTAssertFalse(firstShadow.systemFields.isEmpty)
        XCTAssertEqual(try CloudRecordShadow.archive(edited).systemFields, firstShadow.systemFields)
    }
}
