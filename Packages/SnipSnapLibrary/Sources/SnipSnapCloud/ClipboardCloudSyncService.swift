import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

package struct ClipboardCloudPayload: Codable, Sendable {
    var entry: ClipboardEntry
    var files: [UUID: Data]
}

/// Owns the clipboard cloud binding and history store: one run or unbinding at a time.
private enum ClipboardCloudLifecycle {
    case idle
    case syncing(ClipboardCloudOperation)
    /// `stop()` ended this run. It keeps the store until it unwinds, then admits the first sync
    /// call waiting for it; later waiters are busy.
    case stopping(runID: UUID, syncWaiters: [CheckedContinuation<UUID, any Error>])
    /// The admitted sync starts only if it claims this admission before `stop()` revokes it.
    case admitting(UUID)
    case unbinding(ClipboardCloudOperation, unwindingRun: ClipboardCloudUnwindingRun?)
}

private struct ClipboardCloudOperation {
    let id = UUID()
    let cancellation = ClipboardCloudCancellation()
    var cancelRetry: (@Sendable () -> Void)?

    func cancel() {
        cancellation.cancel()
        cancelRetry?()
    }
}

private struct ClipboardCloudUnwindingRun {
    let id: UUID
    let waiter: CheckedContinuation<Void, Never>
}

/// Shares the saved-snips account/generation scope, but requires its own opt-in.
@MainActor public final class ClipboardCloudSyncService {
    public var isSyncing: Bool {
        if case .syncing = lifecycle { true } else { false }
    }
    public private(set) var pendingEntryIDs: Set<UUID> = []
    public private(set) var lastError: String?
    private let store: ClipboardHistoryStore
    private let worker: ClipboardPayloadWorker
    private let bindingURL: URL
    private let makeTransport: @Sendable (String) -> any ClipboardCloudTransport
    private let retry: CloudKitOperationRetry
    private var transport: (any ClipboardCloudTransport)?
    private var scope: String?
    private var lifecycle = ClipboardCloudLifecycle.idle

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

    /// Call before disabling sync or responding to an account change. A sync call waiting for a
    /// stopped run ends with `CancellationError`.
    public func stop() {
        pendingEntryIDs = []
        switch lifecycle {
        case .idle:
            break
        case .syncing(let run):
            run.cancel()
            lifecycle = .stopping(runID: run.id, syncWaiters: [])
        case .stopping(let runID, let waiters):
            lifecycle = .stopping(runID: runID, syncWaiters: [])
            for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        case .admitting:
            lifecycle = .idle
        case .unbinding(let unbinding, _):
            unbinding.cancel()
        }
    }

    @discardableResult public func synchronize(mainSyncEnabled: Bool, clipboardSyncEnabled: Bool,
                                               generation: String) async throws -> ClipboardHistoryState {
        guard mainSyncEnabled && clipboardSyncEnabled else { stop(); return try await store.load() }
        try await waitForStoppedRun()
        guard case .idle = lifecycle else { throw ClipboardCloudError.busy }
        guard !generation.isEmpty else { throw ClipboardCloudError.unavailable }
        try bind(to: generation)
        guard let transport else { throw ClipboardCloudError.unavailable }
        let run = ClipboardCloudOperation()
        lifecycle = .syncing(run); lastError = nil
        defer { finishRun(run.id) }
        do {
            for _ in 0..<4 {
                try checkCurrentRun(run.id)
                let remote = try await performWithRetry(operationName: "clipboard fetch", owner: run.id) { try await transport.fetch() }
                try checkCurrentRun(run.id)
                let (local, shared, outgoing, pending) = try await worker.prepare(remote, cancellation: run.cancellation)
                try checkCurrentRun(run.id)
                pendingEntryIDs = pending
                do {
                    if !pending.isEmpty || outgoing.keys.count != remote.entries.keys.count || shared.tombstones != remote.tombstones || shared.retentionTombstones != remote.retentionTombstones {
                        let snapshot = ClipboardCloudSnapshot(entries: outgoing, tombstones: shared.tombstones, retentionTombstones: shared.retentionTombstones, version: remote.version)
                        try await performWithRetry(operationName: "clipboard save", owner: run.id) { [cancellation = run.cancellation] in
                            try await transport.save(snapshot, cancellation: cancellation)
                        }
                    }
                }
                catch ClipboardCloudError.conflict { continue }
                try checkCurrentRun(run.id)
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
            if isCurrentRun(run.id) { lastError = error.localizedDescription }
            throw error
        }
    }

    /// Invoke before the saved-snips generation is deleted, using its current scope.
    public func deleteSyncedHistory(generation: String) async throws {
        let unbinding = try await beginUnbinding()
        defer { endUnbinding(unbinding) }
        let hadBinding = FileManager.default.fileExists(atPath: bindingURL.path)
        try bind(to: generation)
        if let transport { try await performWithRetry(operationName: "clipboard delete", owner: unbinding) { try await transport.deleteAll() } }
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
        let unbinding = try await beginUnbinding()
        defer { endUnbinding(unbinding) }
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

    private func waitForStoppedRun() async throws {
        guard case .stopping(let runID, let waiters) = lifecycle else { return }
        let admission: UUID = try await withCheckedThrowingContinuation { waiter in
            lifecycle = .stopping(runID: runID, syncWaiters: waiters + [waiter])
        }
        guard case .admitting(let current) = lifecycle, current == admission else { throw CancellationError() }
        lifecycle = .idle
    }

    private func finishRun(_ id: UUID) {
        switch lifecycle {
        case .syncing(let run) where run.id == id:
            lifecycle = .idle
        case .stopping(let runID, let waiters) where runID == id:
            guard let admitted = waiters.first else {
                lifecycle = .idle
                return
            }
            let admission = UUID()
            lifecycle = .admitting(admission)
            admitted.resume(returning: admission)
            for waiter in waiters.dropFirst() { waiter.resume(throwing: ClipboardCloudError.busy) }
        case .unbinding(let unbinding, let unwinding?) where unwinding.id == id:
            lifecycle = .unbinding(unbinding, unwindingRun: nil)
            unwinding.waiter.resume()
        default:
            break
        }
    }

    private func isCurrentRun(_ id: UUID) -> Bool {
        if case .syncing(let run) = lifecycle { run.id == id } else { false }
    }

    private func checkCurrentRun(_ id: UUID) throws {
        guard isCurrentRun(id) else { throw CancellationError() }
    }

    private func beginUnbinding() async throws -> UUID {
        if case .unbinding = lifecycle { throw ClipboardCloudError.busy }
        stop()
        let unbinding = ClipboardCloudOperation()
        if case .stopping(let runID, _) = lifecycle {
            await withCheckedContinuation { waiter in
                lifecycle = .unbinding(
                    unbinding,
                    unwindingRun: ClipboardCloudUnwindingRun(id: runID, waiter: waiter)
                )
            }
        } else {
            lifecycle = .unbinding(unbinding, unwindingRun: nil)
        }
        return unbinding.id
    }

    private func endUnbinding(_ id: UUID) {
        guard case .unbinding(let unbinding, _) = lifecycle, unbinding.id == id else { return }
        lifecycle = .idle
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
    /// Keeps retries scoped to the owning cloud operation so `stop()` can cancel a pending delay.
    private func performWithRetry<Value: Sendable>(
        operationName: String,
        owner: UUID,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = Task { [retry] in try await retry.run(operationName: operationName, operation) }
        setRetryCancellation(for: owner) { task.cancel() }
        defer { setRetryCancellation(for: owner, nil) }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private func setRetryCancellation(for owner: UUID, _ cancel: (@Sendable () -> Void)?) {
        switch lifecycle {
        case .syncing(var run) where run.id == owner:
            run.cancelRetry = cancel
            lifecycle = .syncing(run)
        case .unbinding(var unbinding, let unwinding) where unbinding.id == owner:
            unbinding.cancelRetry = cancel
            lifecycle = .unbinding(unbinding, unwindingRun: unwinding)
        default:
            cancel?()
        }
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
