import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testSendOperationWithoutDomainReferenceRoundTrips() throws {
        let operation = SyncModeSendOperation(
            reference: nil,
            recordIdentity: CloudTextStorageIdentity(
                zoneName: "payload",
                ownerName: "owner",
                recordName: "payload-id"
            ),
            kind: .delete
        )

        let decoded = try JSONDecoder().decode(
            SyncModeSendOperation.self,
            from: JSONEncoder().encode(operation)
        )

        XCTAssertEqual(decoded, operation)
    }

    func testLegacyModeSendOperationDecodesAsSnipReference() throws {
        let id = UUID()
        let legacy = """
        {"snipID":"\(id.uuidString)","recordIdentity":{"zoneName":"z","ownerName":"o","recordName":"r"},"kind":"save"}
        """
        let decoded = try JSONDecoder().decode(
            SyncModeSendOperation.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.reference, CloudEntityReference(kind: .snip, domainID: id))
    }

    func testManifestWithoutProtocolResumesLegacyTransitionThroughOneDriver() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1
        )
        _ = try await persistence.beginTransition(to: .iCloudSync, namespace: testBinding())
        let manifestURL = root.appendingPathComponent("activation.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        let stripped = stripSyncProtocol(from: object)
        try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let recovered = try await reopened.snapshot()
        XCTAssertEqual(recovered.activeStore.syncProtocol, .legacyTextV1)
        XCTAssertEqual(recovered.transition?.syncProtocol, .legacyTextV1)
        let namespace = makeNamespace()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace) }
        )
        let result = try await coordinator.enableOrRetry()
        XCTAssertEqual(result.state, .on)
    }

    func testStatusEvidenceDoesNotNormalizePendingLegacyEnrollment() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1
        )
        let namespace = makeNamespace()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace) }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let managed = try await persistence.activeLibrary()
        try await add("pending seed", to: managed)
        let local = await managed.snapshot(sortedBy: .chronological)
        let snipID = try XCTUnwrap(local.snips.first?.id)
        let storage = try await persistence.snapshot()
        let rawLibrary = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
        let raw = SwiftDataCloudTextPersistence(
            library: rawLibrary,
            namespace: namespace,
            textZone: textZone(namespace)
        )
        try await raw.approveModeMerge(snipIDs: [snipID])
        _ = try await managed.perform(.delete(ids: [snipID]), sortedBy: .chronological)
        let modeBefore = try await persistence.snapshot()
        let before = try await rawLibrary.cloudTextSyncSnapshot(
            namespaceKey: namespace.canonicalKey
        )
        XCTAssertEqual(before.namespaceState.phase, .seeding)
        XCTAssertEqual(before.namespaceState.approvedSnipIDs, [snipID])

        let firstStatus = try await coordinator.status()
        let secondStatus = try await coordinator.status()
        let modeAfter = try await persistence.snapshot()
        let after = try await rawLibrary.cloudTextSyncSnapshot(
            namespaceKey: namespace.canonicalKey
        )
        XCTAssertEqual(firstStatus.state, .needsAttention)
        XCTAssertEqual(secondStatus, firstStatus)
        XCTAssertEqual(modeAfter, modeBefore)
        XCTAssertEqual(after, before)
    }

    func testOptOutManifestRejectsProtocolMismatch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1
        )
        let namespace = makeNamespace()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace) }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        _ = try await persistence.beginTransition(to: .localOnly, namespace: nil)
        try mutateManifest(at: root.appendingPathComponent("activation.json")) { manifest in
            let transition = try XCTUnwrap(manifest["transition"] as? [String: Any])
            let candidateID = try XCTUnwrap(transition["candidateStoreID"] as? String)
            var stores = try XCTUnwrap(manifest["stores"] as? [[String: Any]])
            let candidateIndex = try XCTUnwrap(
                stores.firstIndex { $0["id"] as? String == candidateID }
            )
            stores[candidateIndex]["syncProtocol"] = SyncModeSyncProtocol.fullRecordV1.rawValue
            manifest["stores"] = stores
        }

        XCTAssertThrowsError(try SwiftDataSyncModePersistence(rootURL: root)) { error in
            XCTAssertEqual(error as? SyncModePersistenceError, .invalidManifest)
        }
    }

    func testManifestRejectsCandidateNamespaceMismatch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1
        )
        _ = try await persistence.beginTransition(to: .iCloudSync, namespace: testBinding())
        try mutateManifest(at: root.appendingPathComponent("activation.json")) { manifest in
            var transition = try XCTUnwrap(manifest["transition"] as? [String: Any])
            var namespace = try XCTUnwrap(transition["namespace"] as? [String: Any])
            namespace["generation"] = UUID().uuidString
            transition["namespace"] = namespace
            manifest["transition"] = transition
        }

        XCTAssertThrowsError(try SwiftDataSyncModePersistence(rootURL: root)) { error in
            XCTAssertEqual(error as? SyncModePersistenceError, .invalidManifest)
        }
    }

    func testRecoveryRejectsTraversingStoreRootWithoutTouchingOutsideData() throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("app", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.data")
        let sentinelBytes = Data([0x00, 0x2e, 0xff, 0x7f, 0x41])
        try sentinelBytes.write(to: sentinel)
        _ = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1
        )
        try mutateManifest(at: root.appendingPathComponent("activation.json")) { manifest in
            var stores = try XCTUnwrap(manifest["stores"] as? [[String: Any]])
            stores.append([
                "id": UUID().uuidString,
                "kind": SyncModeStoreKind.localOnly.rawValue,
                "relativeRoot": "../outside",
                "syncProtocol": SyncModeSyncProtocol.legacyTextV1.rawValue,
                "revision": 0,
                "lifecycle": SyncModeStoreLifecycle.deleting.rawValue,
            ])
            manifest["stores"] = stores
        }

        XCTAssertThrowsError(try SwiftDataSyncModePersistence(rootURL: root)) { error in
            XCTAssertEqual(error as? SyncModePersistenceError, .invalidManifest)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
    }

}
