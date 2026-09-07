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
    private let files: ClipboardFileStore
    private let bindingURL: URL
    private let makeTransport: @Sendable (String) -> any ClipboardCloudTransport
    private var transport: (any ClipboardCloudTransport)?
    private var scope: String?
    private var transitioning = false
    private var epoch = 0
    private var cancellation = ClipboardCloudCancellation()
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public convenience init(store: ClipboardHistoryStore, files: ClipboardFileStore,
                            containerIdentifier: String, syncRootURL: URL) {
        self.init(store: store, files: files, syncRootURL: syncRootURL, makeTransport: { scope in
            CloudKitClipboardTransport(database: CKContainer(identifier: containerIdentifier).privateCloudDatabase,
                                       generation: scope)
        })
    }
    package init(store: ClipboardHistoryStore, files: ClipboardFileStore, syncRootURL: URL,
                 makeTransport: @escaping @Sendable (String) -> any ClipboardCloudTransport) {
        self.store = store; self.files = files
        bindingURL = syncRootURL.appendingPathComponent("clipboard-account-binding.json")
        self.makeTransport = makeTransport
    }

    /// Call before disabling sync or responding to an account change.
    public func stop() { epoch += 1; cancellation.cancel(); pendingEntryIDs = [] }

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
                let remote = try await transport.fetch()
                try checkEpoch(started)
                let decoded = try remote.entries.map { id, data -> ClipboardCloudPayload in
                    guard data.count <= 64 * 1_024 * 1_024 else { throw ClipboardCloudError.payloadTooLarge }
                    let payload = try JSONDecoder().decode(ClipboardCloudPayload.self, from: data)
                    guard payload.entry.byteCount <= ClipboardHistoryState.entryByteLimit else { throw ClipboardCloudError.payloadTooLarge }
                    var size = payload.entry.byteCount
                    for bytes in payload.files.values {
                        guard bytes.count <= ClipboardHistoryState.entryByteLimit - size else { throw ClipboardCloudError.payloadTooLarge }; size += bytes.count
                    }
                    guard payload.entry.id == id, (payload.entry.isSyncEligible || !payload.entry.ownedFiles.isEmpty) else { throw ClipboardCloudError.invalidPayload }
                    return payload
                }
                for payload in decoded {
                    for file in payload.entry.ownedFiles {
                        guard let data = payload.files[file.id] else { throw ClipboardCloudError.invalidPayload }
                        try files.importOwnedFile(file, data: data)
                    }
                }
                let remoteState = ClipboardHistoryState(entries: decoded.map(\.entry), tombstones: remote.tombstones)
                let local = try await store.merge(remoteState)
                try checkEpoch(started)
                // Local-only file references do not consume another device's synced history limit.
                var shared = remoteState
                shared.merge(ClipboardHistoryState(entries: local.entries.filter { $0.isSyncEligible || remote.entries[$0.id] != nil }, tombstones: local.tombstones))
                var outgoing: [UUID: Data] = [:]
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                for entry in shared.entries {
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
                    outgoing[entry.id] = try encoder.encode(ClipboardCloudPayload(entry: entry, files: contents))
                }
                pendingEntryIDs = Set(outgoing.filter { remote.entries[$0.key] != $0.value }.map(\.key))
                try checkEpoch(started)
                do { try await transport.save(ClipboardCloudSnapshot(entries: outgoing, tombstones: shared.tombstones, version: remote.version), cancellation: cancellation) }
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
        try bind(to: generation)
        try await transport?.deleteAll()
        try await store.save(ClipboardHistoryState())
        try removeBinding()
    }

    /// Keep the previous account's history on disk but never upload it to another account.
    public func resetAccountBinding() async throws {
        guard !transitioning else { throw ClipboardCloudError.busy }
        transitioning = true; defer { transitioning = false }
        stop()
        await waitUntilIdle()
        let source = await store.url
        if FileManager.default.fileExists(atPath: source.path) {
            let backup = source.deletingLastPathComponent().appendingPathComponent("clipboard-quarantine-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: source, to: backup)
        }
        try await store.save(ClipboardHistoryState())
        try removeBinding()
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
}
