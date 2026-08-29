import CloudKit
import Foundation
@testable import SnipSnapCloud
import SnipSnapPersistence
import XCTest

final class CloudKitRecordTransportTests: XCTestCase {
    func testEncryptedDataResetFlagIsDistinctFromAnOrdinaryMissingZone() {
        let reset = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.zoneNotFound.rawValue,
            userInfo: [CKErrorUserDidResetEncryptedDataKey: true]
        ))
        let missing = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.zoneNotFound.rawValue
        ))

        XCTAssertTrue(CloudKitRecordTransport.isEncryptedDataReset(reset))
        XCTAssertFalse(CloudKitRecordTransport.isEncryptedDataReset(missing))
    }

    func testNamespaceKeyUsesCanonicalTypedEncoding() {
        let generation = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let zone = CloudZoneID(name: "zone,one", ownerName: "owner/two")
        let first = CloudSyncNamespace(
            cloudScope: "scope|account",
            accountLineage: "lineage",
            generation: generation,
            zones: [zone]
        )
        let second = CloudSyncNamespace(
            cloudScope: "scope",
            accountLineage: "account|lineage",
            generation: generation,
            zones: [zone]
        )

        XCTAssertNotEqual(first.canonicalKey, second.canonicalKey)
        XCTAssertEqual(first.canonicalKey, first.canonicalKey)
        let binding = ICloudSyncNamespaceBinding(
            scope: first.cloudScope,
            accountLineage: first.accountLineage,
            generation: first.generation,
            zones: Set(first.zones.map {
                ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
            })
        )
        XCTAssertEqual(
            SnipRecoveryScopeFactory.scope(forActiveCloudNamespace: binding)?.rawValue,
            first.canonicalKey
        )
    }

    func testRejectsEngineStateFromAnotherNamespaceBeforeNetworkWork() async {
        let zone = CloudZoneID(name: "metadata", ownerName: CKCurrentUserDefaultName)
        let expected = CloudSyncNamespace(
            cloudScope: "test-scope",
            accountLineage: "account-a",
            generation: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            zones: [zone]
        )
        let other = CloudSyncNamespace(
            cloudScope: "test-scope",
            accountLineage: "account-b",
            generation: expected.generation,
            zones: [zone]
        )
        let envelope = CloudEngineStateEnvelope(namespace: other, serialization: Data())

        do {
            _ = try CloudKitRecordTransport.validate(namespace: expected, state: envelope)
            XCTFail("Expected state from another account lineage to fail.")
        } catch {
            XCTAssertEqual(error as? CloudTransportError, .stateNamespaceMismatch)
        }
    }

    func testRejectsCorruptEngineStateBeforeNetworkWork() async {
        let zone = CloudZoneID(name: "metadata", ownerName: CKCurrentUserDefaultName)
        let namespace = CloudSyncNamespace(
            cloudScope: "test-scope",
            accountLineage: "account-a",
            generation: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            zones: [zone]
        )
        let envelope = CloudEngineStateEnvelope(
            namespace: namespace,
            serialization: Data("not engine state".utf8)
        )

        do {
            _ = try CloudKitRecordTransport.validate(namespace: namespace, state: envelope)
            XCTFail("Expected corrupt engine state to fail.")
        } catch {
            XCTAssertEqual(error as? CloudTransportError, .invalidEngineState)
        }
    }
}
