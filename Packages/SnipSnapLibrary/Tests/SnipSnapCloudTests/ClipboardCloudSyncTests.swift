import Foundation
import Testing
import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud

private actor ClipboardTestCloud: ClipboardCloudTransport {
    var snapshot = ClipboardCloudSnapshot()
    var serial = 0
    var unavailable = false
    var conflictOnce = false
    var pauseSave = false
    var paused: CheckedContinuation<Void, Never>?
    func pauseNextSave() { pauseSave = true }
    func hasPaused() -> Bool { paused != nil }
    func resumeSave() { paused?.resume(); paused = nil }
    func setUnavailable(_ value: Bool) { unavailable = value }
    func setConflict() { conflictOnce = true }
    func fetch() throws -> ClipboardCloudSnapshot {
        if unavailable { throw ClipboardCloudError.unavailable }
        return snapshot
    }
    func save(_ incoming: ClipboardCloudSnapshot, cancellation: ClipboardCloudCancellation) async throws {
        if pauseSave { pauseSave = false; await withCheckedContinuation { paused = $0 } }
        try cancellation.check()
        if unavailable { throw ClipboardCloudError.unavailable }
        if conflictOnce { conflictOnce = false; throw ClipboardCloudError.conflict }
        guard incoming.version == snapshot.version else { throw ClipboardCloudError.conflict }
        serial += 1; snapshot = incoming; snapshot.version = Data(String(serial).utf8)
    }
    func deleteAll() { snapshot = ClipboardCloudSnapshot() }
}

@MainActor private struct ClipboardClient {
    let root: URL
    let store: ClipboardHistoryStore
    let files: ClipboardFileStore
    let sync: ClipboardCloudSyncService
    init(_ cloud: ClipboardTestCloud) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ClipboardHistoryStore(url: root.appendingPathComponent("clipboard.json"))
        files = ClipboardFileStore(rootURL: root.appendingPathComponent("files"))
        sync = ClipboardCloudSyncService(store: store, files: files, syncRootURL: root, makeTransport: { _ in cloud })
    }
    @discardableResult func run(enabled: Bool = true, scope: String = "account-generation-A") async throws -> ClipboardHistoryState {
        try await sync.synchronize(mainSyncEnabled: true, clipboardSyncEnabled: enabled, generation: scope)
    }
}

@Suite @MainActor struct ClipboardCloudSyncTests {
    private func entry(_ text: String, pinned: Bool = false) -> ClipboardEntry {
        ClipboardEntry(items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])],
                       pinnedAt: pinned ? Date() : nil)
    }
    @Test func optInMergeDeduplicateAndClearAcrossClients() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        let pin = entry("keep", pinned: true)
        try await a.store.insert(pin); try await a.store.insert(entry("same"))
        try await b.store.insert(entry("same")); try await b.store.insert(entry("second"))
        try await a.run(enabled: false)
        #expect(try await cloud.fetch().entries.isEmpty)
        try await a.run(); try await b.run()
        #expect(try await a.run().entries.count == 3)
        try await b.store.clearUnpinned(); try await b.run()
        #expect(try await a.run().entries.map(\.id) == [pin.id])
        try await a.store.delete(id: pin.id); try await a.run()
        #expect(try await b.run().entries.isEmpty)
    }
    @Test func offlineDeleteWinsAndConflictRetries() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        let clip = entry("offline")
        try await a.store.insert(clip); try await a.run(); try await b.run()
        await cloud.setUnavailable(true)
        try await a.store.delete(id: clip.id)
        await #expect(throws: ClipboardCloudError.unavailable) { try await a.run() }
        #expect(try await a.store.load().entries.isEmpty)
        try await b.store.setPinned(true, id: clip.id)
        await cloud.setUnavailable(false); await cloud.setConflict()
        try await a.run(); #expect(try await b.run().entries.isEmpty)
    }
    @Test func accountChangeRequiresQuarantineAndDoesNotUploadOldData() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("account A")); try await client.run()
        await #expect(throws: ClipboardCloudError.accountChanged) { try await client.run(scope: "account B") }
        try await client.sync.resetAccountBinding()
        #expect(try await client.store.load().entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: client.root.path).contains { $0.hasPrefix("clipboard-quarantine-") })
    }
    @Test func pinnedFilesTransferBytesAndUnpinnedReferencesStayLocal() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        try FileManager.default.createDirectory(at: a.root, withIntermediateDirectories: true)
        let source = a.root.appendingPathComponent("example.txt"); try Data("actual file".utf8).write(to: source)
        let clip = ClipboardEntry(items: [.init(representations: [.init(type: "public.file-url", data: Data(source.absoluteString.utf8))])])
        try await a.store.insert(clip); try await a.run()
        #expect(try await b.run().entries.isEmpty)
        try await a.store.setPinned(true, id: clip.id, fileStore: a.files)
        try FileManager.default.removeItem(at: source)
        try await a.run()
        let wire = try #require(try await cloud.fetch().entries[clip.id])
        let payload = try JSONDecoder().decode(ClipboardCloudPayload.self, from: wire)
        #expect(!payload.entry.fileURLs.contains { $0.path.contains(a.root.path) })
        #expect(try await a.store.load().entries.first?.hasBeenShared == true)
        let downloaded = try #require(try await b.run().entries.first)
        let file = try #require(b.files.resolvedFileURLs(for: downloaded).first)
        #expect(try Data(contentsOf: file) == Data("actual file".utf8))
        try await a.store.setPinned(false, id: clip.id); try await a.run()
        #expect(try await b.run().entries.first?.isPinned == false)
    }
    @Test func stopCancelsPendingWriteAndDeletePermitsNewGeneration() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("cancel"))
        await cloud.pauseNextSave()
        let running = Task { try await client.run() }
        for _ in 0..<10_000 {
            if await cloud.hasPaused() { break }
            await Task.yield()
        }
        #expect(await cloud.hasPaused())
        client.sync.stop(); await cloud.resumeSave()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(try await cloud.fetch().entries.isEmpty)
        try await client.run()
        try await client.sync.deleteSyncedHistory(generation: "account-generation-A")
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(try await client.run(scope: "new-generation").entries.isEmpty)
    }
    @Test func rejectsOversizedPinnedPayloadBeforeUpload() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let huge = ClipboardEntry(items: [.init(representations: [.init(type: "public.png", data: Data(count: ClipboardHistoryState.entryByteLimit + 1))])], pinnedAt: Date())
        try await client.store.insert(huge)
        await #expect(throws: ClipboardCloudError.payloadTooLarge) { try await client.run() }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(try await client.store.load().entries.count == 1)
    }

    @Test func sameNamedFilesStayDistinctAndRepeatCaptureDeduplicates() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        var originals: [ClipboardEntry] = []
        for folder in ["one", "two"] {
            let directory = a.root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("report.txt")
            try Data(folder.utf8).write(to: source)
            let clip = ClipboardEntry(items: [.init(representations: [.init(type: "public.file-url", data: Data(source.absoluteString.utf8))])])
            originals.append(clip)
            try await a.store.insert(clip); try await a.store.setPinned(true, id: clip.id, fileStore: a.files)
        }
        try await a.run()
        let downloaded = try await b.run()
        #expect(downloaded.entries.count == 2)
        #expect(Set(downloaded.entries.map(\.fingerprint)) == Set(originals.map(\.fingerprint)))
        try await a.run()
        let original = try #require(originals.first)
        try await a.store.insert(ClipboardEntry(items: original.items))
        #expect(try await a.store.load().entries.count == 2)
    }

    @Test func neverSyncedHistorySurvivesAccountResetAndCloudDeletion() async throws {
        let client = ClipboardClient(ClipboardTestCloud())
        defer { try? FileManager.default.removeItem(at: client.root) }
        let local = entry("local pin", pinned: true)
        try await client.store.insert(local)
        try await client.sync.resetAccountBinding()
        #expect(try await client.store.load().entries.map(\.id) == [local.id])
        try await client.sync.deleteSyncedHistory(generation: "account-generation-A")
        try await client.sync.deleteSyncedHistory(generation: "account-generation-A")
        #expect(try await client.store.load().entries.map(\.id) == [local.id])
    }

    @Test func unchangedSyncDoesNotWriteAnotherManifest() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("unchanged"))
        try await client.run()
        let first = try await cloud.fetch().version
        try await client.run(); try await client.run()
        #expect(try await cloud.fetch().version == first)
    }

    @Test func payloadWorkerReusesUnchangedFilesAndEncoding() async throws {
        let client = ClipboardClient(ClipboardTestCloud())
        defer { try? FileManager.default.removeItem(at: client.root) }
        let file = ClipboardOwnedFile(id: UUID(), name: "sample.txt", relativePath: "sample.txt")
        var clip = entry("file", pinned: true)
        clip.ownedFiles = [file]; clip.hasBeenShared = true
        let bytes = try JSONEncoder().encode(ClipboardCloudPayload(entry: clip, files: [file.id: Data("sample".utf8)]))
        let remote = ClipboardCloudSnapshot(entries: [clip.id: bytes])
        let worker = ClipboardPayloadWorker(store: client.store, files: client.files)
        _ = try await worker.prepare(remote, cancellation: ClipboardCloudCancellation())
        let decodes = await worker.decodeCount, encodes = await worker.encodeCount, imports = await worker.importCount
        _ = try await worker.prepare(remote, cancellation: ClipboardCloudCancellation())
        #expect(await worker.decodeCount == decodes)
        #expect(await worker.encodeCount == encodes)
        #expect(await worker.importCount == imports)
        #expect(try Data(contentsOf: client.files.url(for: file)) == Data("sample".utf8))
    }

}
