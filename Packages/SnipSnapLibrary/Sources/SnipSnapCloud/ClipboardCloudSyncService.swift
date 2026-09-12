import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

package struct ClipboardCloudPayload: Codable, Sendable {
    var entry: ClipboardEntry
    var files: [UUID: Data]
}

/// Shares the saved-snips account/generation scope, but requires its own opt-in.
@MainActor public final class ClipboardCloudSyncService {
    public private(set) var isSyncing = false
    public private(set) var pendingEntryIDs: Set<UUID> = []
    public private(set) var lastError: String?
    private let store: ClipboardHistoryStore
    private let worker: ClipboardPayloadWorker
    private let bindingURL: URL
    private let makeTransport: @Sendable (String) -> any ClipboardCloudTransport
    private let retry: CloudKitOperationRetry
    private var transport: (any ClipboardCloudTransport)?
    private var scope: String?
    private var transitioning = false
    private var epoch = 0
    private var cancellation = ClipboardCloudCancellation()
    private var cancelActiveRetry: (() -> Void)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public convenience init(store: ClipboardHistoryStore,
                            containerIdentifier: String, syncRootURL: URL) {
        self.init(store: store, syncRootURL: syncRootURL, makeTransport: { scope in
            CloudKitClipboardTransport(database: CKContainer(identifier: containerIdentifier).privateCloudDatabase,
                                       generation: scope)
        })
    }
    package init(store: ClipboardHistoryStore, syncRootURL: URL,
                 makeTransport: @escaping @Sendable (String) -> any ClipboardCloudTransport,
                 retry: CloudKitOperationRetry = CloudKitOperationRetry()) {
        self.store = store
        worker = ClipboardPayloadWorker(store: store, files: store.files)
        bindingURL = syncRootURL.appendingPathComponent("clipboard-account-binding.json")
        self.makeTransport = makeTransport
        self.retry = retry
    }

    /// Call before disabling sync or responding to an account change.
    public func stop() {
        epoch += 1
        cancellation.cancel()
        cancelActiveRetry?()
        pendingEntryIDs = []
    }

    @discardableResult public func synchronize(mainSyncEnabled: Bool, clipboardSyncEnabled: Bool,
                                               generation: String) async throws -> ClipboardHistoryState {
        guard mainSyncEnabled && clipboardSyncEnabled else { stop(); return try await store.load() }
        guard !isSyncing && !transitioning else { throw ClipboardCloudError.busy }
        guard !generation.isEmpty else { throw ClipboardCloudError.unavailable }
        try bind(to: generation)
        guard let transport else { throw ClipboardCloudError.unavailable }
        isSyncing = true; lastError = nil
        cancellation = ClipboardCloudCancellation()
        let started = epoch
        defer {
            isSyncing = false
            let waiters = idleWaiters; idleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        do {
            for _ in 0..<4 {
                let remote = try await performWithRetry(operationName: "clipboard fetch") { try await transport.fetch() }
                try checkEpoch(started)
                let (local, shared, outgoing, pending) = try await worker.prepare(remote, cancellation: cancellation)
                try checkEpoch(started)
                pendingEntryIDs = pending
                try checkEpoch(started)
                do {
                    if !pending.isEmpty || outgoing.keys.count != remote.entries.keys.count || shared.tombstones != remote.tombstones || shared.retentionTombstones != remote.retentionTombstones {
                        let snapshot = ClipboardCloudSnapshot(entries: outgoing, tombstones: shared.tombstones, retentionTombstones: shared.retentionTombstones, version: remote.version)
                        try await performWithRetry(operationName: "clipboard save") { try await transport.save(snapshot, cancellation: self.cancellation) }
                    }
                }
                catch ClipboardCloudError.conflict { continue }
                try checkEpoch(started)
                pendingEntryIDs = []
                let acknowledgments = local.entries.filter { outgoing[$0.id] != nil }.map { item in
                    var item = item; item.hasBeenShared = true; return item
                }
                _ = try await store.merge(ClipboardHistoryState(entries: acknowledgments))
                let latest = try await store.load()
                var acknowledgedLocal = local
                acknowledgedLocal.merge(ClipboardHistoryState(entries: acknowledgments))
                if latest != acknowledgedLocal { continue }
                return latest
            }
            throw ClipboardCloudError.conflict
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Invoke before the saved-snips generation is deleted, using its current scope.
    public func deleteSyncedHistory(generation: String) async throws {
        guard !transitioning else { throw ClipboardCloudError.busy }
        transitioning = true; defer { transitioning = false }
        stop()
        await waitUntilIdle()
        let hadBinding = FileManager.default.fileExists(atPath: bindingURL.path)
        try bind(to: generation)
        if let transport { try await performWithRetry(operationName: "clipboard delete") { try await transport.deleteAll() } }
        if hadBinding {
            try quarantineHistory()
            try await store.save(ClipboardHistoryState())
        }
        try removeBinding()
        await worker.reset()
    }

    /// Keep the previous account's history on disk but never upload it to another account.
    public func resetAccountBinding() async throws {
        guard FileManager.default.fileExists(atPath: bindingURL.path) else { return }
        guard !transitioning else { throw ClipboardCloudError.busy }
        transitioning = true; defer { transitioning = false }
        stop()
        await waitUntilIdle()
        try quarantineHistory()
        try await store.save(ClipboardHistoryState())
        try removeBinding()
        await worker.reset()
    }
    private func quarantineHistory() throws {
        let source = store.url
        if FileManager.default.fileExists(atPath: source.path) {
            let backup = source.deletingLastPathComponent().appendingPathComponent("clipboard-quarantine-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: source, to: backup)
        }
    }
    private func removeBinding() throws {
        if FileManager.default.fileExists(atPath: bindingURL.path) { try FileManager.default.removeItem(at: bindingURL) }
        scope = nil; transport = nil
    }
    private func waitUntilIdle() async {
        guard isSyncing else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
    private func bind(to generation: String) throws {
        if let data = try? Data(contentsOf: bindingURL) {
            guard try JSONDecoder().decode(String.self, from: data) == generation else { throw ClipboardCloudError.accountChanged }
        } else {
            try FileManager.default.createDirectory(at: bindingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(generation).write(to: bindingURL, options: .atomic)
        }
        if scope != generation { transport = makeTransport(generation); scope = generation }
    }
    private func checkEpoch(_ expected: Int) throws {
        guard epoch == expected else { throw CancellationError() }
    }

    /// Keeps retries scoped to the current cloud operation so `stop()` can cancel a pending delay.
    private func performWithRetry<Value: Sendable>(
        operationName: String,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = Task { [retry] in try await retry.run(operationName: operationName, operation) }
        cancelActiveRetry = { task.cancel() }
        defer { cancelActiveRetry = nil }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }
}

/// Keeps large payload and file work off the UI executor.
package actor ClipboardPayloadWorker {
    private let store: ClipboardHistoryStore
    private let files: ClipboardFileStore
    private var decodedCache: [UUID: (Data, ClipboardCloudPayload)] = [:]
    private var encodedCache: [UUID: (ClipboardEntry, Data)] = [:]
    package private(set) var decodeCount = 0
    package private(set) var encodeCount = 0
    package private(set) var importCount = 0

    package init(store: ClipboardHistoryStore, files: ClipboardFileStore) {
        self.store = store; self.files = files
    }

    package func reset() { decodedCache = [:]; encodedCache = [:] }

    package func prepare(_ remote: ClipboardCloudSnapshot, cancellation: ClipboardCloudCancellation) async throws
        -> (ClipboardHistoryState, ClipboardHistoryState, [UUID: Data], Set<UUID>) {
        try cancellation.check()
        decodedCache = decodedCache.filter { remote.entries[$0.key] != nil }
        var changed: Set<UUID> = []
                let decoded = try remote.entries.map { id, data -> ClipboardCloudPayload in
                    if let cached = decodedCache[id], cached.0 == data { return cached.1 }
                    decodeCount += 1
                    guard data.count <= 64 * 1_024 * 1_024 else { throw ClipboardCloudError.payloadTooLarge }
                    var payload = try JSONDecoder().decode(ClipboardCloudPayload.self, from: data)
                    guard payload.entry.byteCount <= ClipboardHistoryState.entryByteLimit else { throw ClipboardCloudError.payloadTooLarge }
                    var size = payload.entry.byteCount
                    for bytes in payload.files.values {
                        guard bytes.count <= ClipboardHistoryState.entryByteLimit - size else { throw ClipboardCloudError.payloadTooLarge }; size += bytes.count
                    }
                    payload.entry.ownedFiles = try payload.entry.ownedFiles.map { file in
                        guard let bytes = payload.files[file.id] else { throw ClipboardCloudError.invalidPayload }
                        var file = file; file.byteCount = bytes.count; return file
                    }
                    guard payload.entry.id == id, (payload.entry.isSyncEligible || !payload.entry.ownedFiles.isEmpty) else { throw ClipboardCloudError.invalidPayload }
                    decodedCache[id] = (data, payload)
                    changed.insert(id)
                    return payload
                }
                let remoteState = ClipboardHistoryState(entries: decoded.map(\.entry), tombstones: remote.tombstones, retentionTombstones: remote.retentionTombstones)
                try cancellation.check()
                let local = try await store.merge(remoteState)
                try cancellation.check()
                let liveFiles = Set(local.entries.flatMap(\.ownedFiles).map(\.id))
                for payload in decoded {
                    for file in payload.entry.ownedFiles where liveFiles.contains(file.id) {
                        guard let data = payload.files[file.id] else { throw ClipboardCloudError.invalidPayload }
                        try cancellation.check()
                        if try changed.contains(payload.entry.id) || !FileManager.default.fileExists(atPath: files.url(for: file).path) {
                            try files.importOwnedFile(file, data: data)
                            importCount += 1
                        }
                    }
                }
                // Local-only file references do not consume another device's synced history limit.
                var shared = remoteState
                shared.merge(ClipboardHistoryState(entries: local.entries.filter { $0.isSyncEligible || remote.entries[$0.id] != nil }, tombstones: local.tombstones, retentionTombstones: local.retentionTombstones))
                var outgoing: [UUID: Data] = [:]
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                for entry in shared.entries {
                    if let cached = encodedCache[entry.id], cached.0 == entry,
                       try entry.ownedFiles.allSatisfy({ FileManager.default.isReadableFile(atPath: try files.url(for: $0).path) }) {
                        outgoing[entry.id] = cached.1
                        continue
                    }
                    let original = entry
                    var entry = entry
                    entry.hasBeenShared = true
                    var contents: [UUID: Data] = [:]
                    var total = entry.byteCount
                    guard total <= ClipboardHistoryState.entryByteLimit else { throw ClipboardCloudError.payloadTooLarge }
                    for file in entry.ownedFiles {
                        let url = try files.url(for: file)
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                        guard size <= ClipboardHistoryState.entryByteLimit - total else { throw ClipboardCloudError.payloadTooLarge }
                        total += size
                        contents[file.id] = try Data(contentsOf: url)
                    }
                    if !entry.ownedFiles.isEmpty {
                        entry.payloadFingerprint = entry.fingerprint
                        entry.items = entry.items.map { item in
                            ClipboardPayloadItem(representations: item.representations.map { representation in
                                guard representation.type == "public.file-url", let source = String(data: representation.data, encoding: .utf8), let url = URL(string: source) else { return representation }
                                return ClipboardRepresentation(type: representation.type, data: Data(URL(fileURLWithPath: "/" + url.lastPathComponent).absoluteString.utf8))
                            })
                        }
                    }
                    try cancellation.check()
                    let data = try encoder.encode(ClipboardCloudPayload(entry: entry, files: contents))
                    encodeCount += 1
                    outgoing[entry.id] = data
                    encodedCache[entry.id] = (original, data)
                }

        encodedCache = encodedCache.filter { outgoing[$0.key] != nil }
        return (local, shared, outgoing, Set(outgoing.filter { remote.entries[$0.key] != $0.value }.map(\.key)))
    }
}
