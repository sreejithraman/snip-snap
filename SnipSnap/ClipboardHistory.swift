import AppKit
import CoreTransferable
import CryptoKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let snipSnapClipboardEntry = UTType(exportedAs: "world.sree.snipsnap.clipboard-entry", conformingTo: .json)
}

struct ClipboardDragPayload: Codable, Equatable, Sendable, Transferable {
    let entryID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .snipSnapClipboardEntry)
            .visibility(.ownProcess)
    }
}

struct ClipboardRepresentation: Codable, Equatable, Sendable {
    let type: String
    let data: Data
}

struct ClipboardPayloadItem: Codable, Equatable, Sendable {
    var representations: [ClipboardRepresentation]
}

struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var capturedAt: Date
    var sourceApplication: String?
    var items: [ClipboardPayloadItem]
    private let plainText: String
    private let fingerprint: String

    @MainActor
    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        sourceApplication: String?,
        items: [ClipboardPayloadItem]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.sourceApplication = sourceApplication
        self.items = items
        plainText = Self.extractText(from: items)
        fingerprint = Self.makeFingerprint(items)
    }

    fileprivate init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        sourceApplication: String?,
        items: [ClipboardPayloadItem],
        plainText: String
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.sourceApplication = sourceApplication
        self.items = items
        self.plainText = plainText
        fingerprint = Self.makeFingerprint(items)
    }

    var text: String {
        plainText.isEmpty
            ? fileURLs.map(\.lastPathComponent).joined(separator: ", ")
            : plainText
    }

    var fileURLs: [URL] {
        items
            .flatMap(\.representations)
            .filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
            .compactMap { String(data: $0.data, encoding: .utf8) }
            .compactMap(URL.init(string:))
    }

    var imageRepresentations: [ClipboardRepresentation] {
        items.compactMap { item in
            item.representations.first { $0.type == NSPasteboard.PasteboardType.png.rawValue }
                ?? item.representations.first { $0.type == NSPasteboard.PasteboardType.tiff.rawValue }
        }
    }

    var standaloneImageRepresentations: [ClipboardRepresentation] {
        items.compactMap { item in
            guard !item.representations.contains(where: {
                $0.type == NSPasteboard.PasteboardType.fileURL.rawValue
            }) else { return nil }
            return item.representations.first { $0.type == NSPasteboard.PasteboardType.png.rawValue }
                ?? item.representations.first { $0.type == NSPasteboard.PasteboardType.tiff.rawValue }
        }
    }

    var searchText: String {
        [text, sourceApplication ?? "", fileURLs.map(\.lastPathComponent).joined(separator: " ")]
            .joined(separator: " ")
    }

    var byteCount: Int {
        items.flatMap(\.representations).reduce(0) { $0 + $1.data.count }
    }

    func hasSamePayload(as other: ClipboardEntry) -> Bool {
        fingerprint == other.fingerprint
    }

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

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, sourceApplication, items, plainText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        sourceApplication = try container.decodeIfPresent(String.self, forKey: .sourceApplication)
        items = try container.decode([ClipboardPayloadItem].self, forKey: .items)
        plainText = try container.decode(String.self, forKey: .plainText)
        fingerprint = Self.makeFingerprint(items)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encodeIfPresent(sourceApplication, forKey: .sourceApplication)
        try container.encode(items, forKey: .items)
        try container.encode(plainText, forKey: .plainText)
    }

    @MainActor
    fileprivate static func extractText(from items: [ClipboardPayloadItem]) -> String {
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

    private static func makeFingerprint(_ items: [ClipboardPayloadItem]) -> String {
        var hasher = SHA256()
        for item in items {
            for representation in item.representations {
                hasher.update(data: Data(representation.type.utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: representation.data)
                hasher.update(data: Data([0xff]))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ClipboardClipMaterialization: Sendable {
    let text: String
    let source: CaptureSource?
    let fileURLs: [URL]
    let temporaryURLs: [URL]

    func removeTemporaryFiles() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension ClipboardEntry {
    func materializeForClip(in directory: URL = FileManager.default.temporaryDirectory) throws
        -> ClipboardClipMaterialization {
        var urls = fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        var temporaryURLs: [URL] = []
        do {
            for image in standaloneImageRepresentations {
                let fileExtension = image.type == NSPasteboard.PasteboardType.tiff.rawValue
                    ? "tiff"
                    : "png"
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
        return ClipboardClipMaterialization(
            text: text,
            source: sourceApplication.map {
                CaptureSource(applicationName: $0, windowTitle: nil, url: nil)
            },
            fileURLs: urls,
            temporaryURLs: temporaryURLs
        )
    }
}

actor ClipboardHistoryFileStore {
    private let url: URL
    private var pendingEntries: [ClipboardEntry]?
    private var writer: Task<Void, Never>?
    private var writeError: String?

    init(url: URL) {
        self.url = url
    }

    func load() -> [ClipboardEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([ClipboardEntry].self, from: data)) ?? []
        return ClipboardHistory.trimmed(decoded)
    }

    func scheduleReplacement(_ entries: [ClipboardEntry]) {
        pendingEntries = entries
        guard writer == nil else { return }
        writer = Task { await drainPendingWrites() }
    }

    func flush() async {
        while let writer {
            await writer.value
        }
    }

    func currentWriteError() -> String? {
        return writeError
    }

    private func drainPendingWrites() async {
        while let entries = pendingEntries {
            pendingEntries = nil
            if let error = await Task.detached(priority: .utility, operation: {
                Self.write(entries, to: self.url)
            }).value {
                writeError = error
            } else {
                writeError = nil
            }
        }
        writer = nil
    }

    nonisolated private static func write(_ entries: [ClipboardEntry], to url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: url, options: .atomic)
            return nil
        } catch {
            return "Snip Snap could not save clipboard history. Snip Snap may lose new clipboard items when it quits."
        }
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
              !pasteboardItems.contains(where: { $0.types.contains(ClipboardHistory.internalType) }),
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
            plainText: ClipboardEntry.extractText(from: items)
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
    nonisolated static let limit = 100
    nonisolated static let representationByteLimit = 16 * 1_024 * 1_024
    nonisolated static let entryByteLimit = 32 * 1_024 * 1_024
    nonisolated static let historyByteLimit = 96 * 1_024 * 1_024
    nonisolated static let backgroundProcessingThreshold = 256 * 1_024
    nonisolated static let internalType = NSPasteboard.PasteboardType("world.sree.snipsnap.internal-copy")

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var isPaused: Bool
    @Published private(set) var persistenceError: String?

    private let pasteboard: NSPasteboard
    private let storeURL: URL
    private let fileStore: ClipboardHistoryFileStore
    private let captureReader: ClipboardCaptureReader
    private var lastChangeCount: Int
    private let pollingTimer = ClipboardPollingTimer()
    private let defaults: UserDefaults
    private var suppressionTokens: Set<UUID> = []
    private var initialLoadTask: Task<Void, Never>?
    private var persistenceScheduleTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var inFlightChangeCount: Int?
    private static let pausedDefaultsKey = "clipboardHistoryPaused"

    init(
        pasteboard: NSPasteboard = .general,
        defaults: UserDefaults = .standard,
        storeURL: URL = ItemRepository.defaultStoreURL()
            .deletingLastPathComponent()
            .appendingPathComponent("clipboard.json")
    ) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.storeURL = storeURL
        fileStore = ClipboardHistoryFileStore(url: storeURL)
        captureReader = ClipboardCaptureReader(pasteboardName: pasteboard.name)
        isPaused = defaults.bool(forKey: Self.pausedDefaultsKey)
        lastChangeCount = pasteboard.changeCount
        entries = []
        initialLoadTask = Task { [weak self, fileStore] in
            let loaded = await fileStore.load()
            guard !Task.isCancelled else { return }
            self?.mergeLoadedEntries(loaded)
        }
        pollingTimer.timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    deinit {
        initialLoadTask?.cancel()
        persistenceScheduleTask?.cancel()
        captureTask?.cancel()
    }

    func poll() {
        guard !isPaused, suppressionTokens.isEmpty else {
            lastChangeCount = pasteboard.changeCount
            return
        }
        guard pasteboard.changeCount != lastChangeCount else { return }
        captureCurrent()
    }

    func clear() {
        initialLoadTask?.cancel()
        captureTask?.cancel()
        entries = []
        persist()
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
        let written = entry.write(to: pasteboard)
        lastChangeCount = pasteboard.changeCount
        return written
    }

    func entry(id: UUID) -> ClipboardEntry? {
        entries.first { $0.id == id }
    }

    func flushPersistence() async {
        await initialLoadTask?.value
        await captureTask?.value
        await persistenceScheduleTask?.value
        await fileStore.flush()
        if let error = await fileStore.currentWriteError() {
            persistenceError = error
        }
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
        let sourceApplication = NSWorkspace.shared.frontmostApplication?.localizedName
        if pasteboard.name == .general {
            guard inFlightChangeCount != capturedChangeCount else { return }
            captureTask?.cancel()
            inFlightChangeCount = capturedChangeCount
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
        if let index = entries.firstIndex(where: { $0.hasSamePayload(as: entry) }) {
            entries.remove(at: index)
        }
        entries.insert(entry, at: 0)
        entries = Self.trimmed(entries)
        persist()
    }

    private func persist() {
        let loadTask = initialLoadTask
        let previousTask = persistenceScheduleTask
        persistenceScheduleTask = Task { [weak self, fileStore] in
            await loadTask?.value
            await previousTask?.value
            guard let self else { return }
            let snapshot = entries
            await fileStore.scheduleReplacement(snapshot)
            Task { [weak self, fileStore] in
                await fileStore.flush()
                if let error = await fileStore.currentWriteError() {
                    self?.persistenceError = error
                }
            }
        }
    }

    private func mergeLoadedEntries(_ loaded: [ClipboardEntry]) {
        var merged = entries
        for entry in loaded where !merged.contains(where: { $0.hasSamePayload(as: entry) }) {
            merged.append(entry)
        }
        entries = Self.trimmed(merged)
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
        var result: [ClipboardEntry] = []
        result.reserveCapacity(min(entries.count, maximumCount))
        var totalBytes = 0
        for entry in entries.prefix(maximumCount) {
            guard entry.byteCount <= maximumEntryBytes else { continue }
            guard totalBytes + entry.byteCount <= maximumHistoryBytes else { break }
            result.append(entry)
            totalBytes += entry.byteCount
        }
        return result
    }
}
