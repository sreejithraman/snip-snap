import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

final class CloudBackupImportTests: XCTestCase {
    func testBackupImportRejectsRetainedDownloadChangesAfterPreview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudBackupImportCAS-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeDownloadedLibrary(root: root)
        let active = try await fixture.persistence.activeLibrary()
        let before = try await active.checkedSnapshot(sortedBy: .manual)
        let attachment = try XCTUnwrap(before.snips.first?.attachments.first)
        let cachedURL = try XCTUnwrap(before.attachmentURLs[attachment.id])
        let backupURL = root.appendingPathComponent("Backup", isDirectory: true)
        try JSONSnipArchiveTransfer.write(
            SnipLibraryArchive(
                snips: [Snip(content: "from backup", origin: .quickEntry)],
                lists: [.inbox], seenRequestIDs: [], attachmentURLs: [:]
            ),
            to: backupURL
        )

        for initiallyCached in [true, false] {
            if !initiallyCached { try FileManager.default.removeItem(at: cachedURL) }
            let preview = try await SnipLibraryImport.preview(backupURL: backupURL, target: active)
            if initiallyCached { try FileManager.default.removeItem(at: cachedURL) }
            else { try fixture.bytes.write(to: cachedURL) }

            do {
                _ = try await active.applyImport(preview)
                XCTFail("Expected the changed target digest to reject the import")
            } catch SnipLibraryError.importChanged {
            }

            let after = try await active.checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(after.snips, before.snips)
            if initiallyCached { try fixture.bytes.write(to: cachedURL) }
        }
    }

    func testBackupImportKeepsAnUnrelatedEvictedRemoteAttachmentLazy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudBackupImport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeDownloadedLibrary(root: root)
        let active = try await fixture.persistence.activeLibrary()
        let before = try await active.checkedSnapshot(sortedBy: .manual)
        let retained = try XCTUnwrap(before.snips.first)
        let attachment = try XCTUnwrap(retained.attachments.first)
        XCTAssertTrue(attachment.relativePath.hasPrefix("CloudDownloads/"))
        let cachedURL = try XCTUnwrap(before.attachmentURLs[attachment.id])
        try FileManager.default.removeItem(at: cachedURL)

        let importedBytes = Data("attachment from backup".utf8)
        let importedURL = root.appendingPathComponent("imported.txt")
        try importedBytes.write(to: importedURL)
        let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
        _ = try await source.perform(
            .add(
                content: "from backup", origin: .quickEntry, source: nil,
                listID: SnipList.inboxID, attachmentURLs: [importedURL],
                requestID: UUID(), now: .distantPast
            ),
            sortedBy: .manual
        )
        let backupURL = root.appendingPathComponent("Backup", isDirectory: true)
        try JSONSnipArchiveTransfer.write(try await source.archive(), to: backupURL)
        let storeID = try await fixture.persistence.snapshot().activeStore.id
        let store = try await fixture.persistence.libraryForTransition(storeID: storeID)
        let cloudBefore = try await store.cloudFullStorageSnapshot(
            namespaceKey: fixture.namespace.namespaceKey
        )
        let preview = try await SnipLibraryImport.preview(backupURL: backupURL, target: active)

        let result = try await active.applyImport(preview)

        XCTAssertEqual(result.addedSnipCount, 1)
        XCTAssertEqual(result.snapshot.snips.first { $0.id == retained.id }, retained)
        XCTAssertNil(result.snapshot.attachmentURLs[attachment.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedURL.path))
        let imported = try XCTUnwrap(result.snapshot.snips.first { $0.content == "from backup" })
        let importedAttachment = try XCTUnwrap(imported.attachments.first)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(result.snapshot.attachmentURLs[importedAttachment.id])),
            importedBytes
        )
        let cloudAfter = try await store.cloudFullStorageSnapshot(
            namespaceKey: fixture.namespace.namespaceKey
        )
        XCTAssertEqual(cloudAfter.readyEntities, cloudBefore.readyEntities)
        XCTAssertEqual(cloudAfter.namespaceState, cloudBefore.namespaceState)

        let reopened = try SwiftDataSyncModePersistence(
            rootURL: root.appendingPathComponent("second"),
            attachmentCacheRootURL: root.appendingPathComponent("second-cache")
        )
        let reopenedState = try await reopened.snapshot()
        XCTAssertEqual(reopenedState.activeStore.kind, .iCloudSync)
        XCTAssertEqual(reopenedState.activeStore.id, storeID)
        let reopenedStore = try await reopened.libraryForTransition(storeID: storeID)
        let reopenedSnapshot = try await reopenedStore.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(reopenedSnapshot.snips.first { $0.id == retained.id }, retained)
        XCTAssertNil(reopenedSnapshot.attachmentURLs[attachment.id])
        let downloads = CloudAttachmentTransferCoordinator(
            library: reopenedStore, namespace: fixture.namespace,
            payloadZone: fixture.payloadZone,
            transport: FakeCloudRecordTransport(server: fixture.server, namespace: fixture.namespace),
            maximumCacheBytes: 1_048_576
        )
        let downloadedURL = try await downloads.prepare(attachmentID: attachment.id, for: .open)
        XCTAssertEqual(try Data(contentsOf: downloadedURL), fixture.bytes)
    }

    private func makeDownloadedLibrary(root: URL) async throws -> (
        persistence: SwiftDataSyncModePersistence, namespace: CloudSyncNamespace,
        payloadZone: CloudZoneID, server: FakeCloudServer, bytes: Data
    ) {
        let bytes = Data("unrelated remote attachment".utf8)
        let sourceURL = root.appendingPathComponent("remote.txt")
        try bytes.write(to: sourceURL)
        let metadataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private", accountLineage: "account", generation: UUID(),
            zones: [metadataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let first = try SwiftDataSyncModePersistence(rootURL: root.appendingPathComponent("first"))
        let local = try await first.activeLibrary()
        _ = try await local.perform(
            .add(
                content: "retained remote snip", origin: .quickEntry, source: nil,
                listID: SnipList.inboxID, attachmentURLs: [sourceURL],
                requestID: UUID(), now: .distantPast
            ),
            sortedBy: .manual
        )
        let second = try SwiftDataSyncModePersistence(
            rootURL: root.appendingPathComponent("second"),
            attachmentCacheRootURL: root.appendingPathComponent("second-cache")
        )
        for persistence in [first, second] {
            let coordinator = ICloudSyncModeCoordinator(
                persistence: persistence, namespace: namespace,
                textZone: metadataZone, payloadZone: payloadZone,
                makeTransport: {
                    FakeCloudRecordTransport(
                        server: server, namespace: namespace,
                        automaticallyFetchedZones: [metadataZone]
                    )
                }
            )
            let enabled = try await coordinator.enableOrRetry()
            XCTAssertEqual(enabled.state, .on)
        }
        // Enabling sync promotes the initial download. Exercise a later download
        // into the active library, whose purgeable bytes can then be evicted.
        let state = try await second.snapshot()
        let store = try await second.libraryForTransition(storeID: state.activeStore.id)
        let downloads = CloudAttachmentTransferCoordinator(
            library: store, namespace: namespace, payloadZone: payloadZone,
            transport: FakeCloudRecordTransport(server: server, namespace: namespace),
            maximumCacheBytes: 1_048_576
        )
        try await downloads.clearDownloads()
        let promoted = try await store.checkedSnapshot(sortedBy: .manual)
        let attachmentID = try XCTUnwrap(promoted.snips.first?.attachments.first?.id)
        let promotedURL = try XCTUnwrap(promoted.attachmentURLs[attachmentID])
        try FileManager.default.removeItem(at: promotedURL)
        _ = try await downloads.prepare(attachmentID: attachmentID, for: .open)
        return (second, namespace, payloadZone, server, bytes)
    }
}
