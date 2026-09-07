import AppKit
import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import Foundation
import UniformTypeIdentifiers

extension ClipboardEntry {
    func write(to pasteboard: NSPasteboard = .general) -> Bool {
        let previous = PasteboardSnapshotStore.snapshot(pasteboard)
        var pasteboardItems: [NSPasteboardItem] = []
        for payload in items {
            let item = NSPasteboardItem()
            for representation in payload.representations {
                guard item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.type)
                ) else { return false }
            }
            pasteboardItems.append(item)
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(pasteboardItems) else {
            if let previous {
                _ = PasteboardSnapshotStore.restore(
                    previous,
                    to: pasteboard,
                    ifChangeCountIs: pasteboard.changeCount
                )
            }
            return false
        }
        return true
    }

    @MainActor
    fileprivate static func extractMacText(from items: [ClipboardPayloadItem]) -> String {
        items.compactMap { item in
            if let value = item.representations.first(where: {
                $0.type == NSPasteboard.PasteboardType.string.rawValue
            }), let string = String(data: value.data, encoding: .utf8) {
                return string
            }
            for (type, documentType) in [
                (NSPasteboard.PasteboardType.rtf.rawValue, NSAttributedString.DocumentType.rtf),
                (NSPasteboard.PasteboardType.html.rawValue, .html)
            ] {
                guard let value = item.representations.first(where: { $0.type == type }),
                      let attributed = try? NSAttributedString(
                        data: value.data,
                        options: [.documentType: documentType],
                        documentAttributes: nil
                      ) else { continue }
                return attributed.string
            }
            return nil
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

}

struct ClipboardSnipMaterialization: Sendable {
    let text: String
    let source: SnipSource?
    let fileURLs: [URL]
    let temporaryURLs: [URL]

    func removeTemporaryFiles() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension ClipboardEntry {
    func materializeForSnip(in directory: URL = FileManager.default.temporaryDirectory) throws
        -> ClipboardSnipMaterialization {
        var urls = fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        var temporaryURLs: [URL] = []
        do {
            for image in standaloneImageRepresentations {
                let fileExtension = UTType(image.type)?.preferredFilenameExtension ?? "png"
                let url = directory
                    .appendingPathComponent("Snip Snap-\(UUID().uuidString).\(fileExtension)")
                try image.data.write(to: url)
                urls.append(url)
                temporaryURLs.append(url)
            }
        } catch {
            for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return ClipboardSnipMaterialization(
            text: text,
            source: sourceApplication.map {
                SnipSource(applicationName: $0, windowTitle: nil, url: nil)
            },
            fileURLs: urls,
            temporaryURLs: temporaryURLs
        )
    }
}



private final class ClipboardPollingTimer: @unchecked Sendable {
    var timer: Timer?

    deinit {
        timer?.invalidate()
    }
}

private struct ClipboardCaptureSnapshot: Sendable {
    let items: [ClipboardPayloadItem]
    let plainText: String

    var byteCount: Int {
        items.flatMap(\.representations).reduce(0) { $0 + $1.data.count }
    }
}

@MainActor
private final class ClipboardCaptureReader {
    private let pasteboardName: NSPasteboard.Name

    init(pasteboardName: NSPasteboard.Name) {
        self.pasteboardName = pasteboardName
    }

    func capture(changeCount: Int) -> ClipboardCaptureSnapshot? {
        let pasteboard = NSPasteboard(name: pasteboardName)
        guard pasteboard.changeCount == changeCount,
              let pasteboardItems = pasteboard.pasteboardItems,
              !pasteboardItems.isEmpty,
              !pasteboardItems.contains(where: { Self.shouldIgnore($0.types) }) else { return nil }
        var remainingBytes = ClipboardHistory.entryByteLimit
        let items = pasteboardItems.compactMap { pasteboardItem -> ClipboardPayloadItem? in
            let representations = Self.supportedTypes(in: pasteboardItem).compactMap {
                type -> ClipboardRepresentation? in
                guard remainingBytes > 0,
                      let data = pasteboardItem.data(forType: type),
                      data.count <= ClipboardHistory.representationByteLimit,
                      data.count <= remainingBytes else { return nil }
                remainingBytes -= data.count
                return ClipboardRepresentation(type: type.rawValue, data: data)
            }
            return representations.isEmpty ? nil : ClipboardPayloadItem(representations: representations)
        }
        guard pasteboard.changeCount == changeCount, !items.isEmpty else { return nil }
        return ClipboardCaptureSnapshot(
            items: items,
            plainText: ClipboardEntry.extractMacText(from: items)
        )
    }

    private static func supportedTypes(in item: NSPasteboardItem) -> [NSPasteboard.PasteboardType] {
        let supported: [NSPasteboard.PasteboardType] = [
            .string, .rtf, .html, .fileURL, .png, .tiff
        ]
        return supported.filter(item.types.contains)
    }

    private static func shouldIgnore(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        let ignored = [
            "org.nspasteboard.TransientType",
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.AutoGeneratedType",
            "com.agilebits.onepassword",
            "com.1password"
        ]
        return types.contains { type in ignored.contains { type.rawValue.contains($0) } }
    }
}

@MainActor
final class ClipboardHistory: ObservableObject {
    nonisolated static let limit = ClipboardHistoryState.limit
    nonisolated static let representationByteLimit = ClipboardHistoryState.representationByteLimit
    nonisolated static let entryByteLimit = ClipboardHistoryState.entryByteLimit
    nonisolated static let historyByteLimit = ClipboardHistoryState.historyByteLimit
    nonisolated static let backgroundProcessingThreshold = 256 * 1_024

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var isPaused: Bool
    @Published private(set) var persistenceError: String?
    @Published private(set) var clipboardSyncEnabled: Bool = false
    @Published private(set) var isSyncing = false
    @Published private(set) var syncError: String?
    @Published private(set) var pendingUploadIDs: Set<UUID> = [] {
        didSet { defaults.set(pendingUploadIDs.map(\.uuidString), forKey: "clipboardPendingUploadIDs") }
    }
    private var cloudService: ClipboardCloudSyncService?
    private var mainSyncEnabled: (() -> Bool)?
    private var syncGeneration: (() async throws -> String?)?
    private var syncTask: Task<Void, Never>?
    private var lastSyncRequest = Date.distantPast

    private let pasteboard: NSPasteboard
    let sharedStore: ClipboardHistoryStore
    let ownedFileStore: ClipboardFileStore
    private var state = ClipboardHistoryState()
    var onChange: (() -> Void)?
    private let captureReader: ClipboardCaptureReader
    private var lastChangeCount: Int
    private let pollingTimer = ClipboardPollingTimer()
    private let defaults: UserDefaults
    private var suppressionTokens: Set<UUID> = []
    private var initialLoadTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var persistenceScheduleTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var inFlightChangeCount: Int?
    private static let pausedDefaultsKey = "clipboardHistoryPaused"

    init(
        pasteboard: NSPasteboard = .general,
        defaults: UserDefaults = .standard,
        storeURL: URL = ClipboardHistory.defaultStoreURL()
    ) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        pendingUploadIDs = Set((defaults.stringArray(forKey: "clipboardPendingUploadIDs") ?? []).compactMap(UUID.init(uuidString:)))
        sharedStore = ClipboardHistoryStore(url: storeURL)
        ownedFileStore = ClipboardFileStore(rootURL: storeURL.deletingLastPathComponent().appendingPathComponent("ClipboardFiles", isDirectory: true))
        captureReader = ClipboardCaptureReader(pasteboardName: pasteboard.name)
        clipboardSyncEnabled = defaults.bool(forKey: "clipboardSyncEnabled")
        isPaused = defaults.bool(forKey: Self.pausedDefaultsKey)
        lastChangeCount = pasteboard.changeCount
        entries = []
        initialLoadTask = Task { [weak self, sharedStore] in
            do {
                let loaded = try await sharedStore.load()
                guard !Task.isCancelled, let self else { return }
                self.state.merge(loaded)
                self.entries = self.state.entries
            } catch {
                self?.persistenceError = error.localizedDescription
            }
        }
        pollingTimer.timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private static func defaultStoreURL() -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["SNIP_SNAP_STORE_PATH"],
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: false)
                .deletingLastPathComponent()
                .appendingPathComponent("clipboard.json", isDirectory: false)
        }
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Snip Snap", isDirectory: true)
            .appendingPathComponent("clipboard.json", isDirectory: false)
    }

    deinit {
        initialLoadTask?.cancel()
        persistenceScheduleTask?.cancel()
        captureTask?.cancel()
    }

    func poll() {
        if cloudService != nil, clipboardSyncEnabled, Date().timeIntervalSince(lastSyncRequest) > 15 {
            requestSync()
        }
        guard !isPaused, suppressionTokens.isEmpty else {
            lastChangeCount = pasteboard.changeCount
            return
        }
        guard pasteboard.changeCount != lastChangeCount else { return }
        captureCurrent()
    }

    func clear() {
        captureTask?.cancel()
        let previousClear = clearTask
        clearTask = Task { [weak self] in
            await previousClear?.value
            guard let self else { return }
            await initialLoadTask?.value
            state.clearUnpinned()
            entries = state.entries
            persist()
        }
    }

    func configureSync(containerIdentifier: String, rootURL: URL,
                       mainEnabled: @escaping () -> Bool,
                       generation: @escaping () async throws -> String?) {
        cloudService = ClipboardCloudSyncService(store: sharedStore,
            containerIdentifier: containerIdentifier, syncRootURL: rootURL)
        mainSyncEnabled = mainEnabled
        syncGeneration = generation
        onChange = { [weak self] in self?.requestSync() }
    }

    func stopSync() {
        cloudService?.stop()
        syncTask?.cancel()
        syncTask = nil
    }

    func status(for entry: ClipboardEntry) -> String? {
        guard !entry.fileURLs.isEmpty else { return nil }
        if !entry.isSyncEligible { return String(localized: "Only on this Mac") }
        guard clipboardSyncEnabled, mainSyncEnabled?() == true, pendingUploadIDs.contains(entry.id) else { return nil }
        if syncError != nil { return String(localized: "Upload failed") }
        return isSyncing ? String(localized: "Uploading…") : String(localized: "Waiting to sync")
    }

    var syncIsActive: Bool { clipboardSyncEnabled && mainSyncEnabled?() == true }

    func setSyncEnabled(_ enabled: Bool) {
        clipboardSyncEnabled = enabled
        defaults.set(enabled, forKey: "clipboardSyncEnabled")
        if enabled {
            pendingUploadIDs.formUnion(entries.filter(\.isSyncEligible).map(\.id))
            requestSync()
        } else { stopSync(); syncError = nil }
    }

    func requestSync() {
        guard clipboardSyncEnabled, mainSyncEnabled?() == true, syncTask == nil else { return }
        lastSyncRequest = Date()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await syncNow()
            syncTask = nil
        }
    }

    func syncNow() async {
        guard let cloudService, !isSyncing else { return }
        guard clipboardSyncEnabled, mainSyncEnabled?() == true else { cloudService.stop(); return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            await flushPersistence()
            guard let generation = try await syncGeneration?() else { return }
            let updated = try await cloudService.synchronize(mainSyncEnabled: mainSyncEnabled?() == true,
                clipboardSyncEnabled: clipboardSyncEnabled, generation: generation)
            state.merge(updated)
            entries = state.entries
            pendingUploadIDs.subtract(updated.entries.map(\.id))
            syncError = nil
        } catch is CancellationError { }
        catch { syncError = error.localizedDescription }
    }

    func resetCloudAccount() async {
        cloudService?.stop()
        let token = beginSuppression()
        defer { endSuppression(token) }
        await flushPersistence()
        do {
            try await cloudService?.resetAccountBinding()
            state = try await sharedStore.load()
            entries = state.entries
        } catch { syncError = error.localizedDescription }
    }

    func deleteSyncedHistory() async throws {
        guard let cloudService, let generation = try await syncGeneration?() else { return }
        await flushPersistence()
        try await cloudService.deleteSyncedHistory(generation: generation)
        state = try await sharedStore.load()
        entries = state.entries
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        defaults.set(paused, forKey: Self.pausedDefaultsKey)
        lastChangeCount = pasteboard.changeCount
    }

    func beginSuppression() -> UUID {
        let token = UUID()
        suppressionTokens.insert(token)
        lastChangeCount = pasteboard.changeCount
        return token
    }

    func endSuppression(_ token: UUID) {
        suppressionTokens.remove(token)
        lastChangeCount = pasteboard.changeCount
    }

    func restore(_ entry: ClipboardEntry) -> Bool {
        let resolved = resolvedEntry(entry)
        if !entry.ownedFiles.isEmpty,
           !resolved.fileURLs.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) {
            persistenceError = String(localized: "That file is missing. Try syncing again.")
            return false
        }
        guard resolved.write(to: pasteboard) else { return false }
        lastChangeCount = pasteboard.changeCount
        var copied = entry
        copied.capturedAt = Date()
        copied.modifiedAt = copied.capturedAt
        insert(copied)
        return true
    }

    func captureNow(from pasteboard: NSPasteboard) {
        guard pasteboard.name == self.pasteboard.name else { return }
        captureImmediately()
    }

    func entry(id: UUID) -> ClipboardEntry? {
        entries.first { $0.id == id }
    }

    func flushPersistence() async {
        await clearTask?.value
        await initialLoadTask?.value
        await captureTask?.value
        await persistenceScheduleTask?.value

    }

    func dismissPersistenceError() {
        persistenceError = nil
    }

    func waitForPendingCapture() async {
        await captureTask?.value
    }

    private func captureCurrent() {
        let capturedChangeCount = pasteboard.changeCount
        guard !isPaused, suppressionTokens.isEmpty else {
            lastChangeCount = capturedChangeCount
            return
        }
        if pasteboard.name == .general {
            guard inFlightChangeCount != capturedChangeCount else { return }
            captureTask?.cancel()
            inFlightChangeCount = capturedChangeCount
            let sourceApplication = NSWorkspace.shared.frontmostApplication?.localizedName
            captureTask = Task { [weak self, captureReader] in
                let snapshot = captureReader.capture(changeCount: capturedChangeCount)
                guard let self,
                      self.inFlightChangeCount == capturedChangeCount else { return }
                self.inFlightChangeCount = nil
                guard !Task.isCancelled,
                      !self.isPaused,
                      self.suppressionTokens.isEmpty,
                      self.pasteboard.changeCount == capturedChangeCount else { return }
                self.lastChangeCount = capturedChangeCount
                guard let snapshot else { return }
                let entry = await Task.detached(priority: .utility) {
                    ClipboardEntry(
                        sourceApplication: sourceApplication,
                        items: snapshot.items,
                        plainText: snapshot.plainText
                    )
                }.value
                guard !Task.isCancelled,
                      self.pasteboard.changeCount == capturedChangeCount else { return }
                self.insert(entry)
            }
            return
        }
        captureImmediately()
    }

    private func captureImmediately() {
        let capturedChangeCount = pasteboard.changeCount
        guard !isPaused, suppressionTokens.isEmpty else {
            lastChangeCount = capturedChangeCount
            return
        }
        let sourceApplication = NSWorkspace.shared.frontmostApplication?.localizedName
        captureTask?.cancel()
        guard let snapshot = captureReader.capture(changeCount: capturedChangeCount) else {
            lastChangeCount = capturedChangeCount
            captureTask = nil
            return
        }
        lastChangeCount = capturedChangeCount
        if snapshot.byteCount < Self.backgroundProcessingThreshold {
            captureTask = nil
            insert(
                ClipboardEntry(
                    sourceApplication: sourceApplication,
                    items: snapshot.items,
                    plainText: snapshot.plainText
                )
            )
            return
        }
        captureTask = Task { [weak self] in
            let entry = await Task.detached(priority: .utility) {
                ClipboardEntry(
                    sourceApplication: sourceApplication,
                    items: snapshot.items,
                    plainText: snapshot.plainText
                )
            }.value
            guard !Task.isCancelled,
                  let self,
                  !self.isPaused,
                  self.suppressionTokens.isEmpty,
                  self.pasteboard.changeCount == capturedChangeCount else { return }
            self.insert(entry)
        }
    }

    private func insert(_ entry: ClipboardEntry) {
        state.insert(entry)
        entries = state.entries
        if let inserted = entries.first(where: { $0.hasSamePayload(as: entry) }), inserted.isSyncEligible {
            pendingUploadIDs.insert(inserted.id)
        }
        persist()
    }

    private func persist() {
        let loadTask = initialLoadTask
        let previousTask = persistenceScheduleTask
        persistenceScheduleTask = Task { [weak self, sharedStore] in
            await loadTask?.value
            await previousTask?.value
            guard let self else { return }
            do {
                let persisted = try await sharedStore.merge(state)
                state.merge(persisted)
                entries = state.entries
                onChange?()
            } catch {
                persistenceError = error.localizedDescription
            }
        }
    }



    func delete(id: UUID) {
        state.delete(id: id)
        entries = state.entries
        persist()
    }

    func togglePinned(id: UUID) async {
        await flushPersistence()
        do {
            let updated = try await sharedStore.togglePinned(id: id)
            state.merge(updated)
            entries = state.entries
            pendingUploadIDs.insert(id)
            onChange?()
        } catch { persistenceError = error.localizedDescription }
    }

    func resolvedEntry(_ entry: ClipboardEntry) -> ClipboardEntry {
        guard !entry.ownedFiles.isEmpty else { return entry }
        var result = entry
        var urls = ownedFileStore.resolvedFileURLs(for: entry).makeIterator()
        result.items = entry.items.map { item in
            ClipboardPayloadItem(representations: item.representations.map { representation in
                guard representation.type == NSPasteboard.PasteboardType.fileURL.rawValue,
                      let url = urls.next() else { return representation }
                return ClipboardRepresentation(type: representation.type, data: Data(url.absoluteString.utf8))
            })
        }
        return result
    }

    func waitForInitialLoad() async {
        await initialLoadTask?.value
    }

    nonisolated static func trimmed(
        _ entries: [ClipboardEntry],
        maximumEntryBytes: Int = entryByteLimit,
        maximumHistoryBytes: Int = historyByteLimit,
        maximumCount: Int = limit
    ) -> [ClipboardEntry] {
        ClipboardHistoryState.trimmed(entries, maximumEntryBytes: maximumEntryBytes,
                                      maximumHistoryBytes: maximumHistoryBytes, maximumCount: maximumCount)
    }
}
