import AppKit
import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import Foundation
import UniformTypeIdentifiers

extension ClipboardEntry {
    @MainActor
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
        let hasRTFD = items.contains { payload in
            payload.representations.contains {
                $0.type == NSPasteboard.PasteboardType.rtfd.rawValue
            }
        }
        if !hasRTFD,
           let primaryIndex = items.firstIndex(where: {
               Self.extractMacAttributedText(from: $0) != nil
           }),
           let primaryText = Self.extractMacAttributedText(from: items[primaryIndex]) {
            let primary = pasteboardItems[primaryIndex]
            let readableFiles = fileURLs.filter { url in
                guard FileManager.default.isReadableFile(atPath: url.path),
                      let values = try? url.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                      ]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
            SnipPasteboardExport.addDeferredRichText(
                to: primary,
                attributedText: primaryText,
                attachmentURLs: readableFiles
            )
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
        items.compactMap(extractMacText(from:))
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    @MainActor
    private static func extractMacText(from item: ClipboardPayloadItem) -> String? {
        if let value = item.representations.first(where: {
            $0.type == NSPasteboard.PasteboardType.string.rawValue
        }), let string = String(data: value.data, encoding: .utf8) {
            return string
        }
        return extractMacAttributedText(from: item)?.string
    }

    @MainActor
    private static func extractMacAttributedText(
        from item: ClipboardPayloadItem
    ) -> NSAttributedString? {
        for (type, documentType) in [
            (NSPasteboard.PasteboardType.rtf.rawValue, NSAttributedString.DocumentType.rtf),
            (NSPasteboard.PasteboardType.rtfd.rawValue, .rtfd),
            (NSPasteboard.PasteboardType.html.rawValue, .html)
        ] {
            guard let value = item.representations.first(where: { $0.type == type }),
                  let attributed = try? NSAttributedString(
                    data: value.data,
                    options: [.documentType: documentType],
                    documentAttributes: nil
                  ) else { continue }
            return documentType == .rtfd
                ? attributed.removingAttachments
                : attributed
        }
        if let value = item.representations.first(where: {
            $0.type == NSPasteboard.PasteboardType.string.rawValue
        }), let string = String(data: value.data, encoding: .utf8) {
            return NSAttributedString(string: string)
        }
        return nil
    }

}

private extension NSAttributedString {
    var removingAttachments: NSAttributedString {
        let text = NSMutableAttributedString(attributedString: self)
        var ranges: [NSRange] = []
        text.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: text.length)
        ) { value, range, _ in
            guard value != nil else { return }
            ranges.append(range)
        }
        for range in ranges.reversed() {
            text.deleteCharacters(in: range)
        }
        return text
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
        var remainingBytes = ClipboardHistoryState.entryByteLimit
        let items = pasteboardItems.compactMap { pasteboardItem -> ClipboardPayloadItem? in
            let representations = Self.supportedTypes(in: pasteboardItem).compactMap {
                type -> ClipboardRepresentation? in
                guard remainingBytes > 0,
                      let data = pasteboardItem.data(forType: type),
                      data.count <= ClipboardHistoryState.representationByteLimit,
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
        guard !item.types.contains(SnipPasteboardMarkdownFile.privateType) else { return [] }
        let supported: [NSPasteboard.PasteboardType] = [
            .string, .rtf, .rtfd, .html, .fileURL, .png, .tiff
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

/// A pause or suppression hold ends any attempt, and only the current attempt can insert an entry.
private enum ClipboardCapture {
    /// Leaving the hold accepts the pasteboard as it is then, so changes made while held stay out.
    case held(ClipboardCaptureHolds)
    case watching(handledChangeCount: Int)
    case capturing(ClipboardCaptureAttempt)

    var isPaused: Bool {
        guard case .held(let holds) = self else { return false }
        return holds.isPaused
    }

    var attemptID: UUID? {
        guard case .capturing(let attempt) = self else { return nil }
        return attempt.id
    }
}

private struct ClipboardCaptureHolds {
    var isPaused: Bool
    var suppressions: Set<UUID> = []

    var isReleased: Bool { !isPaused && suppressions.isEmpty }
}

private struct ClipboardCaptureAttempt {
    enum Stage {
        case awaitingRead(handledChangeCount: Int)
        case converting
    }

    let id: UUID
    let changeCount: Int
    var stage: Stage
    let task: Task<Void, Never>

    var handledChangeCount: Int {
        switch stage {
        case .awaitingRead(let handledChangeCount): handledChangeCount
        case .converting: changeCount
        }
    }
}

/// Only the current run can change history or report an error.
private enum ClipboardSyncPhase: Equatable {
    case disabled
    case idle
    case syncing(id: UUID)
}

/// A set-aside is queued or running. Captures wait for the history that follows it, and
/// retired history takes no edit.
private enum ClipboardHistoryHandoff: Equatable {
    case none
    case settingAside(id: UUID, isRetired: Bool, captures: [ClipboardEntry])
}

/// Stays scheduled through the run it starts, so requests made meanwhile are absorbed.
private enum ClipboardSyncRequest {
    case idle(lastRequestedAt: Date)
    case scheduled(id: UUID, requestedAt: Date, task: Task<Void, Never>)

    var lastRequestedAt: Date {
        switch self {
        case .idle(let lastRequestedAt): lastRequestedAt
        case .scheduled(_, let requestedAt, _): requestedAt
        }
    }
}

/// Builds a clipboard entry off the main actor.
typealias ClipboardEntryConversion = @Sendable (
    _ build: @escaping @Sendable () -> ClipboardEntry
) async -> ClipboardEntry

@MainActor
final class ClipboardHistory: ObservableObject {
    nonisolated static let backgroundProcessingThreshold = 256 * 1_024

    @Published private(set) var entries: [ClipboardEntry] = []
    var isPaused: Bool { capture.isPaused }
    @Published private(set) var persistenceError: String?
    var clipboardSyncEnabled: Bool { syncPhase != .disabled }
    var isSyncing: Bool {
        if case .syncing = syncPhase { true } else { false }
    }
    @Published private(set) var filePreviewRevision = 0
    @Published private(set) var syncError: String?
    @Published private(set) var pendingUploadIDs: Set<UUID> = [] {
        didSet { defaults.set(pendingUploadIDs.map(\.uuidString), forKey: "clipboardPendingUploadIDs") }
    }
    private var cloudService: ClipboardCloudSyncService?
    private var mainSyncEnabled: (() -> Bool)?
    private var syncGeneration: (() async throws -> String?)?
    @Published private var syncPhase: ClipboardSyncPhase
    private var syncRequest = ClipboardSyncRequest.idle(lastRequestedAt: .distantPast)

    private let pasteboard: NSPasteboard
    private let generalPasteboardName: NSPasteboard.Name
    private let convertEntry: ClipboardEntryConversion
    let sharedStore: ClipboardHistoryStore
    let ownedFileStore: ClipboardFileStore
    private var state = ClipboardHistoryState()
    private var handoff = ClipboardHistoryHandoff.none
    private var isHistoryRetired: Bool {
        if case .settingAside(_, let isRetired, _) = handoff { isRetired } else { false }
    }
    var onChange: (() -> Void)?
    private let captureReader: ClipboardCaptureReader
    private var capture: ClipboardCapture {
        willSet {
            if case .capturing(let attempt) = capture, newValue.attemptID != attempt.id {
                attempt.task.cancel()
            }
            if newValue.isPaused != capture.isPaused { objectWillChange.send() }
        }
    }
    private let pollingTimer = ClipboardPollingTimer()
    private let defaults: UserDefaults
    private let diagnostics: AppDiagnosticRecorder
    private var initialLoadTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var persistenceScheduleTask: Task<Void, Never>?
    private static let pausedDefaultsKey = "clipboardHistoryPaused"

    init(
        pasteboard: NSPasteboard = .general,
        defaults: UserDefaults = .standard,
        storeURL: URL = ClipboardHistory.defaultStoreURL(),
        diagnostics: AppDiagnosticRecorder = AppDiagnosticRecorder.live,
        generalPasteboardName: NSPasteboard.Name = .general,
        convertEntry: @escaping ClipboardEntryConversion = { build in
            await Task.detached(priority: .utility, operation: build).value
        }
    ) {
        self.pasteboard = pasteboard
        self.generalPasteboardName = generalPasteboardName
        self.convertEntry = convertEntry
        self.defaults = defaults
        self.diagnostics = diagnostics
        pendingUploadIDs = Set((defaults.stringArray(forKey: "clipboardPendingUploadIDs") ?? []).compactMap(UUID.init(uuidString:)))
        sharedStore = ClipboardHistoryStore(url: storeURL)
        ownedFileStore = ClipboardFileStore(rootURL: storeURL.deletingLastPathComponent().appendingPathComponent("ClipboardFiles", isDirectory: true))
        captureReader = ClipboardCaptureReader(pasteboardName: pasteboard.name)
        syncPhase = defaults.bool(forKey: "clipboardSyncEnabled") ? .idle : .disabled
        capture = defaults.bool(forKey: Self.pausedDefaultsKey)
            ? .held(ClipboardCaptureHolds(isPaused: true))
            : .watching(handledChangeCount: pasteboard.changeCount)
        entries = []
        initialLoadTask = Task { [weak self, sharedStore] in
            do {
                let loaded = try await sharedStore.load()
                guard !Task.isCancelled, let self else { return }
                self.state.merge(loaded)
                self.entries = self.state.entries
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.diagnostics.record(.failure(
                    operation: "clipboard.load",
                    error: error,
                    visibility: .user
                ))
                self.persistenceError = String(
                    localized: "Couldn’t load clipboard history. Try again."
                )
            }
        }
        pollingTimer.timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private static func defaultStoreURL() -> URL {
        if let overridePath = LocalSnipStorePaths.storePathOverride() {
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
        if case .capturing(let attempt) = capture { attempt.task.cancel() }
    }

    func poll() {
        if cloudService != nil, clipboardSyncEnabled,
           Date().timeIntervalSince(syncRequest.lastRequestedAt) > 15 {
            requestSync()
        }
        let changeCount = pasteboard.changeCount
        let handledChangeCount: Int
        switch capture {
        case .held:
            return
        case .watching(let handled):
            handledChangeCount = handled
        case .capturing(let attempt):
            guard attempt.changeCount != changeCount else { return }
            handledChangeCount = attempt.handledChangeCount
        }
        guard changeCount != handledChangeCount else { return }
        if pasteboard.name == generalPasteboardName {
            beginDeferredCapture(of: changeCount, handledChangeCount: handledChangeCount)
        } else {
            captureImmediately()
        }
    }

    func clear() {
        if case .capturing(let attempt) = capture {
            capture = .watching(handledChangeCount: attempt.handledChangeCount)
        }
        let previousClear = clearTask
        clearTask = Task { [weak self] in
            await previousClear?.value
            guard let self else { return }
            await initialLoadTask?.value
            guard !isHistoryRetired else { return }
            state.clearUnpinned()
            entries = state.entries
            persist(
                errorMessage: String(localized: "Couldn’t clear clipboard history. Try again."),
                operation: "clipboard.clear"
            )
        }
    }

    func configureSync(containerIdentifier: String, rootURL: URL,
                       mainEnabled: @escaping () -> Bool,
                       generation: @escaping () async throws -> String?,
                       makeCloudService: @MainActor (_ store: ClipboardHistoryStore, _ containerIdentifier: String,
                                                     _ syncRootURL: URL) -> ClipboardCloudSyncService
                           = ClipboardCloudSyncService.init(store:containerIdentifier:syncRootURL:)) {
        cloudService = makeCloudService(sharedStore, containerIdentifier, rootURL)
        mainSyncEnabled = mainEnabled
        syncGeneration = generation
        onChange = { [weak self] in self?.requestSync() }
    }

    func stopSync() {
        stopSync(entering: clipboardSyncEnabled ? .idle : .disabled)
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
        defaults.set(enabled, forKey: "clipboardSyncEnabled")
        if enabled {
            if syncPhase == .disabled { syncPhase = .idle }
            pendingUploadIDs.formUnion(entries.filter(\.isSyncEligible).map(\.id))
            requestSync()
        } else {
            stopSync(entering: .disabled)
            syncError = nil
        }
    }

    func requestSync() {
        guard clipboardSyncEnabled, mainSyncEnabled?() == true,
              case .idle = syncRequest else { return }
        let id = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, case .scheduled(let scheduledID, _, _) = self.syncRequest,
                  scheduledID == id else { return }
            await syncNow()
            if case .scheduled(let scheduledID, let requestedAt, _) = syncRequest, scheduledID == id {
                syncRequest = .idle(lastRequestedAt: requestedAt)
            }
        }
        syncRequest = .scheduled(id: id, requestedAt: Date(), task: task)
    }

    func syncNow() async {
        guard let cloudService, !isSyncing else { return }
        guard clipboardSyncEnabled, mainSyncEnabled?() == true else { cloudService.stop(); return }
        let run = ClipboardSyncPhase.syncing(id: UUID())
        syncPhase = run
        defer { if syncPhase == run { enterSyncPhase(.idle) } }
        do {
            await flushPersistence()
            guard syncPhase == run, let generation = try await syncGeneration?(),
                  syncPhase == run else { return }
            func synchronizeHistory() async throws -> ClipboardHistoryState {
                try await cloudService.synchronize(
                    generation: generation,
                    isEnabled: { [self] in syncIsActive }
                )
            }
            let updated: ClipboardHistoryState
            do {
                updated = try await synchronizeHistory()
            } catch ClipboardCloudError.syncGenerationChanged {
                // Set-aside history never uploads into the new sync generation.
                try await setAsideCloudHistory()
                guard syncPhase == run else { return }
                updated = try await synchronizeHistory()
            }
            guard syncPhase == run else { return }
            state.merge(updated)
            entries = state.entries
            pendingUploadIDs.subtract(updated.entries.map(\.id))
            syncError = nil
        } catch is CancellationError { }
        catch {
            guard syncPhase == run else { return }
            diagnostics.record(.failure(
                operation: "clipboard.sync",
                error: error,
                visibility: .user
            ))
            syncError = ClipboardSyncErrorMessage.sync(for: error)
        }
    }

    private func stopSync(entering next: ClipboardSyncPhase) {
        cloudService?.stop()
        if case .scheduled(_, let requestedAt, let task) = syncRequest {
            task.cancel()
            syncRequest = .idle(lastRequestedAt: requestedAt)
        }
        enterSyncPhase(next)
    }

    private func enterSyncPhase(_ next: ClipboardSyncPhase) {
        guard syncPhase != next else { return }
        if case .syncing = syncPhase {
            // Downloads may restore bytes without changing entry metadata or URLs.
            filePreviewRevision &+= 1
        }
        syncPhase = next
    }

    func resetCloudAccount() async {
        let token = beginSuppression()
        defer { endSuppression(token) }
        stopSync()
        do {
            try await setAsideCloudHistory()
        } catch {
            diagnostics.record(.failure(
                operation: "clipboard.account_reset",
                error: error,
                visibility: .user
            ))
            syncError = ClipboardSyncErrorMessage.accountReset(for: error)
        }
    }

    private func setAsideCloudHistory() async throws {
        cloudService?.stop()
        let id = UUID()
        if case .settingAside(_, let isRetired, let captures) = handoff {
            handoff = .settingAside(id: id, isRetired: isRetired, captures: captures)
        } else {
            handoff = .settingAside(id: id, isRetired: false, captures: [])
        }
        try await queueHistoryWrite { [self] in
            let outcome: Result<Void, any Error>
            do {
                try await resetBindingAndReloadHistory()
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await endSetAside(id)
            try outcome.get()
        }.value
    }

    private func resetBindingAndReloadHistory() async throws {
        do {
            try await cloudService?.resetAccountBinding(settingAside: {
                if case .settingAside(let current, _, let captures) = handoff {
                    handoff = .settingAside(id: current, isRetired: true, captures: captures)
                }
                state = ClipboardHistoryState()
                entries = []
            })
        } catch {
            // A reset that failed before removing the binding still blocks the new generation.
            if isHistoryRetired, let kept = try? await sharedStore.load() {
                state = kept
                entries = state.entries
            }
            throw error
        }
        if isHistoryRetired {
            state = try await sharedStore.load()
            entries = state.entries
        }
        syncError = nil
    }

    /// Saves the waiting captures inside the link, so a set-aside queued behind it sets them aside with this history.
    private func endSetAside(_ id: UUID) async {
        guard case .settingAside(let current, _, let captures) = handoff else { return }
        handoff = current == id ? .none : .settingAside(id: current, isRetired: false, captures: [])
        guard !captures.isEmpty else { return }
        for waiting in captures { addToMemory(waiting) }
        await save()
    }

    func deleteSyncedHistory() async throws {
        guard let cloudService, let generation = try await syncGeneration?() else { return }
        try await queueHistoryWrite { [self] in
            try await cloudService.deleteSyncedHistory(generation: generation)
            state = try await sharedStore.load()
            entries = state.entries
        }.value
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        defaults.set(paused, forKey: Self.pausedDefaultsKey)
        var holds = captureHolds
        holds.isPaused = paused
        setCaptureHolds(holds)
    }

    func beginSuppression() -> UUID {
        let token = UUID()
        var holds = captureHolds
        holds.suppressions.insert(token)
        setCaptureHolds(holds)
        return token
    }

    func endSuppression(_ token: UUID) {
        guard case .held(var holds) = capture else { return }
        holds.suppressions.remove(token)
        setCaptureHolds(holds)
    }

    private var captureHolds: ClipboardCaptureHolds {
        guard case .held(let holds) = capture else { return ClipboardCaptureHolds(isPaused: false) }
        return holds
    }

    private func setCaptureHolds(_ holds: ClipboardCaptureHolds) {
        capture = holds.isReleased
            ? .watching(handledChangeCount: pasteboard.changeCount)
            : .held(holds)
    }

    func restore(_ entry: ClipboardEntry) -> Bool {
        let resolved = resolvedEntry(entry)
        if !entry.ownedFiles.isEmpty,
           !resolved.fileURLs.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) {
            diagnostics.record(.failure(
                operation: "clipboard.copy_file",
                errorCode: "clipboard.unreadable",
                visibility: .user
            ))
            persistenceError = String(localized: "This file isn’t on this Mac. Find the original file and copy it again.")
            return false
        }
        guard resolved.write(to: pasteboard) else { return false }
        if !isCaptureHeld {
            capture = .watching(handledChangeCount: pasteboard.changeCount)
        }
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
        await captureAttemptTask?.value
        await persistenceScheduleTask?.value

    }

    func dismissPersistenceError() {
        persistenceError = nil
    }

    func waitForPendingCapture() async {
        await captureAttemptTask?.value
    }

    private var captureAttemptTask: Task<Void, Never>? {
        guard case .capturing(let attempt) = capture else { return nil }
        return attempt.task
    }

    private var isCaptureHeld: Bool {
        if case .held = capture { true } else { false }
    }

    private func beginDeferredCapture(of changeCount: Int, handledChangeCount: Int) {
        let id = UUID()
        let sourceApplication = NSWorkspace.shared.frontmostApplication?.localizedName
        let task = Task { [weak self] in
            guard let self else { return }
            await readDeferredCapture(id, sourceApplication: sourceApplication)
        }
        capture = .capturing(ClipboardCaptureAttempt(
            id: id,
            changeCount: changeCount,
            stage: .awaitingRead(handledChangeCount: handledChangeCount),
            task: task
        ))
    }

    private func readDeferredCapture(_ id: UUID, sourceApplication: String?) async {
        guard case .capturing(var attempt) = capture, attempt.id == id else { return }
        let snapshot = captureReader.capture(changeCount: attempt.changeCount)
        guard let snapshot, pasteboard.changeCount == attempt.changeCount else {
            capture = .watching(handledChangeCount: attempt.changeCount)
            return
        }
        attempt.stage = .converting
        capture = .capturing(attempt)
        await finishCapture(id, snapshot: snapshot, sourceApplication: sourceApplication)
    }

    private func captureImmediately() {
        guard !isCaptureHeld else { return }
        let changeCount = pasteboard.changeCount
        let sourceApplication = NSWorkspace.shared.frontmostApplication?.localizedName
        guard let snapshot = captureReader.capture(changeCount: changeCount) else {
            capture = .watching(handledChangeCount: changeCount)
            return
        }
        guard snapshot.byteCount >= Self.backgroundProcessingThreshold else {
            capture = .watching(handledChangeCount: changeCount)
            admitCapture(ClipboardEntry(
                sourceApplication: sourceApplication,
                items: snapshot.items,
                plainText: snapshot.plainText
            ))
            return
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await finishCapture(id, snapshot: snapshot, sourceApplication: sourceApplication)
        }
        capture = .capturing(ClipboardCaptureAttempt(
            id: id,
            changeCount: changeCount,
            stage: .converting,
            task: task
        ))
    }

    private func finishCapture(
        _ id: UUID,
        snapshot: ClipboardCaptureSnapshot,
        sourceApplication: String?
    ) async {
        let entry = await convertEntry {
            ClipboardEntry(
                sourceApplication: sourceApplication,
                items: snapshot.items,
                plainText: snapshot.plainText
            )
        }
        guard case .capturing(let attempt) = capture, attempt.id == id else { return }
        capture = .watching(handledChangeCount: attempt.changeCount)
        guard pasteboard.changeCount == attempt.changeCount else { return }
        admitCapture(entry)
    }

    private func admitCapture(_ entry: ClipboardEntry) {
        guard case .settingAside(let id, let isRetired, var captures) = handoff else {
            insert(entry)
            return
        }
        captures.append(entry)
        handoff = .settingAside(id: id, isRetired: isRetired, captures: captures)
    }

    private func insert(_ entry: ClipboardEntry) {
        guard addToMemory(entry) else { return }
        persist()
    }

    /// Adds `entry` to the history in memory unless that history is retired, and returns whether it did.
    @discardableResult
    private func addToMemory(_ entry: ClipboardEntry) -> Bool {
        guard !isHistoryRetired else { return false }
        state.insert(entry)
        entries = state.entries
        if let inserted = entries.first(where: { $0.hasSamePayload(as: entry) }), inserted.isSyncEligible {
            pendingUploadIDs.insert(inserted.id)
        }
        return true
    }

    private nonisolated static var saveFailureMessage: String {
        String(localized: "Couldn’t save clipboard history. Try again.")
    }

    private func persist(
        errorMessage: String = ClipboardHistory.saveFailureMessage,
        operation: StaticString = "clipboard.persist"
    ) {
        queueHistoryWrite { [self] in await save(errorMessage: errorMessage, operation: operation) }
    }

    private func save(
        errorMessage: String = ClipboardHistory.saveFailureMessage,
        operation: StaticString = "clipboard.persist"
    ) async {
        do {
            let persisted = try await sharedStore.merge(state)
            state.merge(persisted)
            entries = state.entries
            onChange?()
        } catch {
            diagnostics.record(.failure(
                operation: operation,
                error: error,
                visibility: .user
            ))
            persistenceError = errorMessage
        }
    }

    /// Runs `write` after every earlier history write, so no two overlap. A write must not await
    /// another queued write.
    @discardableResult
    private func queueHistoryWrite<Value: Sendable>(
        _ write: @escaping @MainActor () async throws -> Value
    ) -> Task<Value, any Error> {
        let earlierWrites = [clearTask, initialLoadTask, captureAttemptTask, persistenceScheduleTask]
        let link = Task {
            for earlier in earlierWrites { await earlier?.value }
            return try await write()
        }
        persistenceScheduleTask = Task { _ = await link.result }
        return link
    }



    func delete(id: UUID) {
        guard !isHistoryRetired else { return }
        state.delete(id: id)
        entries = state.entries
        persist(
            errorMessage: String(localized: "Couldn’t delete this clipboard entry. Try again."),
            operation: "clipboard.delete"
        )
    }

    func togglePinned(id: UUID) async {
        do {
            try await queueHistoryWrite { [self] in
                let updated = try await sharedStore.togglePinned(id: id)
                state.merge(updated)
                entries = state.entries
                pendingUploadIDs.insert(id)
                onChange?()
            }.value
        } catch {
            diagnostics.record(.failure(
                operation: "clipboard.pin",
                error: error,
                visibility: .user
            ))
            persistenceError = String(localized: "Couldn’t update the pin. Try again.")
        }
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

    /// CLI reads include the initial load and every pending capture/write. Retry
    /// any failed queued persistence before returning a durable snapshot.
    func checkedCLISnapshot() async throws -> [ClipboardEntry] {
        try await queueHistoryWrite { [self] in
            let loaded = try await sharedStore.merge(state)
            state.merge(loaded)
            entries = state.entries
            persistenceError = nil
            return entries
        }.value
    }

    func checkedCLIEntry(id: UUID, revision: String) async throws -> ClipboardEntry {
        _ = try await checkedCLISnapshot()
        return try await sharedStore.checkedCLIEntry(id: id, revision: revision)
    }

    func performCLI(_ action: SnipCLIClipboardAction) async throws -> [ClipboardEntry] {
        _ = try await checkedCLISnapshot()
        switch action {
        case .setPaused(let paused, let revision):
            guard SnipCLIClipboardRevision.token(entries: entries, isPaused: isPaused) == revision else {
                throw SnipCLIClipboardError.historyChanged
            }
            setPaused(paused)
        case .restore(let id, let revision):
            let restored = try await queueHistoryWrite { [self] in
                let entry = try await sharedStore.checkedCLIEntry(id: id, revision: revision)
                state.merge(ClipboardHistoryState(entries: [entry]))
                return restore(entry)
            }.value
            guard restored else { throw SnipCLIClipboardError.copyFailed }
            do { _ = try await checkedCLISnapshot() }
            catch { throw SnipCLIOutcomeUncertain() }
        case .setPinned, .delete, .clear:
            try await queueHistoryWrite { [self] in
                let updated = try await sharedStore.performCLI(action, isPaused: isPaused)
                state.merge(updated)
                entries = state.entries
                persistenceError = nil
                if case .setPinned(let id, _, _) = action { pendingUploadIDs.insert(id) }
                onChange?()
            }.value
        default:
            throw SnipLibraryError.invalidCommand
        }
        return entries
    }

}
