import CloudKit
import Foundation
import Synchronization
import Testing
import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud

private actor ClipboardTestCloud: ClipboardCloudTransport {
    var snapshot = ClipboardCloudSnapshot()
    var serial = 0
    var unavailable = false
    var conflictOnce = false
    var rateLimitedFetches = 0
    var fetchObserver: (@Sendable () -> Void)?
    var fetchRequests = 0
    var pauseSave = false
    var paused: CheckedContinuation<Void, Never>?
    func pauseNextSave() { pauseSave = true }
    func hasPaused() -> Bool { paused != nil }
    func resumeSave() { paused?.resume(); paused = nil }
    func setUnavailable(_ value: Bool) { unavailable = value }
    func setConflict() { conflictOnce = true }
    func rateLimitFetches(_ count: Int) { rateLimitedFetches = count }
    func observeFetches(_ observer: @escaping @Sendable () -> Void) { fetchObserver = observer }
    func fetchCount() -> Int { fetchRequests }
    func fetch() throws -> ClipboardCloudSnapshot {
        fetchRequests += 1
        fetchObserver?()
        if rateLimitedFetches > 0 {
            rateLimitedFetches -= 1
            throw CKError(_nsError: NSError(
                domain: CKErrorDomain,
                code: CKError.Code.requestRateLimited.rawValue,
                userInfo: [CKErrorRetryAfterKey: 10]
            ))
        }
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
    init(_ cloud: ClipboardTestCloud, retry: CloudKitOperationRetry = CloudKitOperationRetry()) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = ClipboardFileStore(rootURL: root.appendingPathComponent("ClipboardFiles"))
        store = ClipboardHistoryStore(url: root.appendingPathComponent("clipboard.json"), fileStore: files)
        sync = ClipboardCloudSyncService(store: store, syncRootURL: root,
                                         makeTransport: { _ in cloud }, retry: retry)
    }
    @discardableResult func run(enabled: Bool = true, scope: String = "account-generation-A") async throws -> ClipboardHistoryState {
        try await sync.synchronize(mainSyncEnabled: true, clipboardSyncEnabled: enabled, generation: scope)
    }
}

@Suite @MainActor struct ClipboardCloudSyncTests {
    @Test func payloadReferencesUseRandomNamesAndDetectManifestConflicts() throws {
        let data = Data("private clipboard content".utf8)
        let first = ClipboardCloudPayloadReference(data: data)
        let second = ClipboardCloudPayloadReference(data: data)
        #expect(UUID(uuidString: first.recordName) != nil)
        #expect(first.recordName != second.recordName)
        #expect(first.digest == second.digest)
        let id = CKRecord.ID(recordName: "manifest")
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.serverRecordChanged)]])
        #expect(CloudKitClipboardTransport.isConflict(partial, recordID: id))
        #expect(!CloudKitClipboardTransport.isConflict(CKError(.networkFailure), recordID: id))
    }

    @Test func deleteSyncedHistoryKeepsRecoveryFileBytes() async throws {
        let client = ClipboardClient(ClipboardTestCloud())
        defer { try? FileManager.default.removeItem(at: client.root) }
        try FileManager.default.createDirectory(at: client.root, withIntermediateDirectories: true)
        let source = client.root.appendingPathComponent("important.txt")
        let data = Data("Keep recovery bytes".utf8)
        try data.write(to: source)
        let clip = ClipboardEntry(items: [.init(representations: [.init(type: "public.file-url", data: Data(source.absoluteString.utf8))])])
        try await client.store.insert(clip)
        try await client.store.setPinned(true, id: clip.id)
        let shared = try await client.run()
        let owned = try #require(shared.entries.first?.ownedFiles.first)
        try await client.sync.deleteSyncedHistory(generation: "account-generation-A")
        #expect(try await client.store.load().entries.isEmpty)
        #expect(try Data(contentsOf: client.files.url(for: owned)) == data)
        let backups = try FileManager.default.contentsOfDirectory(at: client.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("clipboard-quarantine-") }
        #expect(backups.count == 1)
    }

    @Test func sharedFileSizesSurviveSyncAndUnpinForRetention() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        try FileManager.default.createDirectory(at: a.root, withIntermediateDirectories: true)
        let source = a.root.appendingPathComponent("file.txt")
        let data = Data(repeating: 1, count: 4096)
        try data.write(to: source)
        let clip = ClipboardEntry(items: [.init(representations: [.init(type: "public.file-url", data: Data(source.absoluteString.utf8))])])
        try await a.store.insert(clip); try await a.store.setPinned(true, id: clip.id); try await a.run()
        try await b.run(); try await b.store.setPinned(false, id: clip.id)
        let state = try await b.run()
        let unpinned = try #require(state.entries.first)
        #expect(unpinned.ownedFiles.first?.byteCount == data.count)
        #expect(unpinned.retentionByteCount == unpinned.byteCount + data.count)
        #expect(ClipboardHistoryState.trimmed([unpinned], maximumHistoryBytes: 4096).isEmpty)
    }

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
    @Test func tryAgainHonorsTheServerDeadlineAfterClipboardSyncFails() async throws {
        let clock = ClipboardRetryClock()
        let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
        let cloud = ClipboardTestCloud()
        let requestTimes = Mutex<[Duration]>([])
        await cloud.observeFetches { requestTimes.withLock { $0.append(clock.elapsed) } }
        await cloud.rateLimitFetches(3)
        let client = ClipboardClient(cloud, retry: retry)
        defer { try? FileManager.default.removeItem(at: client.root) }

        await #expect(throws: CKError.self) { try await client.run() }
        try await client.run()

        #expect(requestTimes.withLock { $0 } == [.zero, .seconds(10), .seconds(20), .seconds(30)])
    }
    @Test func stopCancelsAClipboardRetryWaitBeforeAnotherRequest() async throws {
        let sleep = ClipboardRetrySleepGate()
        let retry = CloudKitOperationRetry(sleep: { _ in try await sleep.wait() })
        let cloud = ClipboardTestCloud()
        await cloud.rateLimitFetches(1)
        let client = ClipboardClient(cloud, retry: retry)
        defer { try? FileManager.default.removeItem(at: client.root) }

        let running = Task { try await client.run() }
        for _ in 0..<10_000 {
            if sleep.isWaiting { break }
            await Task.yield()
        }
        #expect(sleep.isWaiting)
        client.sync.stop()

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await cloud.fetchCount() == 1)
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
        try await a.store.setPinned(true, id: clip.id)
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
            try await a.store.insert(clip); try await a.store.setPinned(true, id: clip.id)
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

    @Test func localFileReferencesDoNotEvictSharedHistory() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        let shared = entry("shared text")
        try await a.store.insert(shared); try await a.run()
        for index in 0..<100 {
            try await b.store.insert(ClipboardEntry(items: [.init(representations: [
                .init(type: "public.file-url", data: Data("file:///local-\(index).txt".utf8))
            ])]))
        }
        try await b.run()
        #expect(try await a.run().entries.map(\.id) == [shared.id])
        #expect(try await b.store.load().entries.count == 101)
    }

}

private final class ClipboardRetryClock: Sendable {
    private let origin = ContinuousClock.now
    private let value = Mutex<Duration>(.zero)
    var now: ContinuousClock.Instant { origin.advanced(by: elapsed) }
    var elapsed: Duration { value.withLock { $0 } }
    func advance(_ duration: Duration) { value.withLock { $0 += duration } }
}

private final class ClipboardRetrySleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    var isWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return continuation != nil
    }

    func wait() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); self.continuation = continuation; lock.unlock()
            }
        }, onCancel: {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        })
    }
}
