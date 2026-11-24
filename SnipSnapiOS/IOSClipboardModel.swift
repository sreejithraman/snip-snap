import Foundation
import Observation
import SnipSnapCloud
import SnipSnapCore
import SnipSnapPersistence
import UIKit
import UniformTypeIdentifiers

/// Only the current run can change history or report an error.
private enum ClipboardSyncPhase: Equatable {
    case disabled
    case idle
    case syncing(id: UUID)
}

@MainActor @Observable
final class IOSClipboardModel {
    private let store: ClipboardHistoryStore
    private let files: ClipboardFileStore
    private let settings: SyncedContentSettingsModel
    private let cloud: ClipboardCloudSyncService?
    var cloudChecksAccount: Bool { cloud?.checksAccount == true }
    private let generation: @MainActor () async throws -> String?
    private let preferences: UserDefaults
    private let diagnostics: AppDiagnosticRecorder
    private let readCopyFile: @Sendable (URL) throws -> Data
    @ObservationIgnored private var copyRequestID = UUID()
    private(set) var entries: [ClipboardEntry] = []
    private(set) var filePreviewRevision = 0
    private(set) var pendingUploadIDs: Set<UUID> = []
    private var syncPhase: ClipboardSyncPhase
    var isSyncing: Bool {
        if case .syncing = syncPhase { true } else { false }
    }
    var syncEnabled: Bool { syncPhase != .disabled }
    private var operationErrorMessage: String?
    private var loadErrorMessage: String?
    private(set) var syncErrorMessage: String?
    private(set) var operationFailure: AppFailure?
    var persistentErrorMessage: String? { syncErrorMessage ?? loadErrorMessage }
    var errorMessage: String? {
        get { operationErrorMessage ?? persistentErrorMessage }
        set {
            operationErrorMessage = newValue
            if newValue == nil { operationFailure = nil }
        }
    }
    private(set) var pasteErrorMessage: String?
    private(set) var isPasting = false
    private static let representationTypes: [UTType] = [.utf8PlainText, .plainText, .url, .rtf, .html, .png, .jpeg, .tiff]
    var syncIsActive: Bool {
        guard syncEnabled, settings.mode == .iCloudSync else { return false }
        return settings.state != .disabling
    }
    var localDeviceLabel: String {
        UIDevice.current.model == "iPad" ? String(localized: "Only on this iPad") : String(localized: "Only on this iPhone")
    }

    init(rootURL: URL, syncRootURL: URL? = nil, settings: SyncedContentSettingsModel,
         containerIdentifier: String? = nil,
         preferences: UserDefaults = .standard,
         generation: @escaping @MainActor () async throws -> String? = { nil },
         diagnostics: AppDiagnosticRecorder = AppDiagnosticRecorder.live,
         readCopyFile: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
         makeCloudService: @MainActor (_ store: ClipboardHistoryStore, _ containerIdentifier: String,
                                       _ syncRootURL: URL) -> ClipboardCloudSyncService
             = ClipboardCloudSyncService.init(store:containerIdentifier:syncRootURL:)) {
        let store = ClipboardHistoryStore(url: rootURL.appendingPathComponent("clipboard.json"))
        let files = ClipboardFileStore(rootURL: rootURL.appendingPathComponent("ClipboardFiles", isDirectory: true))
        self.store = store
        self.files = files
        self.settings = settings
        self.generation = generation
        self.preferences = preferences
        self.diagnostics = diagnostics
        self.readCopyFile = readCopyFile
        syncPhase = preferences.bool(forKey: "syncClipboardHistory") ? .idle : .disabled
        pendingUploadIDs = Set((preferences.stringArray(forKey: "clipboardPendingUploads") ?? []).compactMap(UUID.init(uuidString:)))
        cloud = containerIdentifier.flatMap {
            let identifier = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { return nil }
            return makeCloudService(store, identifier,
                syncRootURL ?? rootURL.appendingPathComponent("SyncMode", isDirectory: true))
        }
    }

    func setSyncEnabled(_ enabled: Bool) async {
        if !enabled {
            stop(entering: .disabled)
        } else if syncPhase == .disabled {
            syncPhase = .idle
        }
        preferences.set(enabled, forKey: "syncClipboardHistory")
        if enabled {
            await load()
            pendingUploadIDs.formUnion(entries.filter(\.isSyncEligible).map(\.id))
            savePendingUploads()
        }
        await synchronize()
    }

    func load() async {
        do {
            entries = try await store.load().entries
            filePreviewRevision &+= 1
            loadErrorMessage = nil
        } catch {
            if loadErrorMessage == nil {
                diagnostics.record(.failure(
                    operation: "clipboard.load",
                    error: error,
                    visibility: .user
                ))
            }
            loadErrorMessage = String(localized: "Couldn’t load clipboard history. Try again.")
        }
    }

    func synchronize() async {
        guard !isSyncing else { return }
        if settings.state == .disabling {
            cloud?.stop()
            return
        }
        guard let cloud, syncEnabled, settings.mode == .iCloudSync else {
            cloud?.stop()
            await load()
            return
        }
        let run = ClipboardSyncPhase.syncing(id: UUID())
        syncPhase = run
        defer { if syncPhase == run { enterSyncPhase(.idle) } }
        await load()
        guard syncPhase == run else { return }
        guard syncIsActive else { cloud.stop(); return }
        do {
            guard let generation = try await generation(), syncPhase == run else { return }
            func synchronizeHistory() async throws -> ClipboardHistoryState {
                // The service checks this before the run and stops the run when it stops holding.
                try await cloud.synchronize(generation: generation, isEnabled: { [self] in syncIsActive })
            }
            let synced: ClipboardHistoryState
            do {
                synced = try await synchronizeHistory()
            } catch ClipboardCloudError.syncGenerationChanged {
                // Set-aside history never uploads into the new sync generation.
                try await setAsideHistory()
                guard syncPhase == run, syncIsActive else { return }
                synced = try await synchronizeHistory()
            }
            guard syncPhase == run, syncIsActive else { return }
            entries = synced.entries
            syncErrorMessage = nil
            pendingUploadIDs = []
            savePendingUploads()
        } catch {
            guard syncPhase == run, syncIsActive, !(error is CancellationError) else { return }
            diagnostics.record(.failure(
                operation: "clipboard.sync",
                error: error,
                visibility: .user
            ))
            pendingUploadIDs.formUnion(cloud.pendingEntryIDs)
            savePendingUploads()
            syncErrorMessage = ClipboardSyncErrorMessage.sync(for: error)
        }
    }

    func stop() {
        stop(entering: syncEnabled ? .idle : .disabled)
    }

    private func stop(entering next: ClipboardSyncPhase) {
        cloud?.stop()
        enterSyncPhase(next)
    }

    private func enterSyncPhase(_ next: ClipboardSyncPhase) {
        guard syncPhase != next else { return }
        if case .syncing = syncPhase { filePreviewRevision &+= 1 }
        syncPhase = next
    }

    func resetAccountBinding() async {
        do {
            try await setAsideHistory(includingUnboundHistory: syncEnabled)
        } catch {
            diagnostics.record(.failure(
                operation: "clipboard.account_reset",
                error: error,
                visibility: .user
            ))
            syncErrorMessage = ClipboardSyncErrorMessage.accountReset(for: error)
        }
    }

    private func setAsideHistory(includingUnboundHistory: Bool = false) async throws {
        try await cloud?.resetAccountBinding(includingUnboundHistory: includingUnboundHistory)
        await load()
        syncErrorMessage = nil
    }

    func togglePin(_ entry: ClipboardEntry) async {
        do {
            entries = try await store.togglePinned(id: entry.id).entries
            if syncEnabled, let updated = entries.first(where: { $0.id == entry.id }), updated.isSyncEligible {
                pendingUploadIDs.insert(entry.id)
                savePendingUploads()
            }
            errorMessage = nil
            await synchronize()
        } catch {
            presentError(error, operation: "clipboard.pin", message: ClipboardFileStore.pinFailureMessage(for: error))
        }
    }

    func delete(_ entry: ClipboardEntry) async {
        do {
            entries = try await store.delete(id: entry.id).entries
            pendingUploadIDs.remove(entry.id)
            savePendingUploads()
            if operationFailure?.operation == "clipboard.delete" { errorMessage = nil }
            await synchronize()
        }
        catch {
            presentError(error, operation: "clipboard.delete", message: String(localized: "Couldn’t delete this clipboard entry. Try again."))
        }
    }

    func clear() async {
        do {
            entries = try await store.clearUnpinned().entries
            pendingUploadIDs.formIntersection(entries.map(\.id))
            savePendingUploads()
            if operationFailure?.operation == "clipboard.clear" { errorMessage = nil }
            await synchronize()
        }
        catch {
            presentError(error, operation: "clipboard.clear", message: String(localized: "Couldn’t clear clipboard history. Try again."))
        }
    }

    func previewFileURLs(for entry: ClipboardEntry) -> [URL] {
        files.resolvedFileURLs(for: entry)
    }

    @discardableResult
    func copy(_ entry: ClipboardEntry) async -> Bool {
        guard !Task.isCancelled else { return false }
        let requestID = UUID()
        copyRequestID = requestID
        errorMessage = nil
        var payload = entry.items.map { item in
            Dictionary(item.representations.filter { $0.type != UTType.fileURL.identifier }.map { ($0.type, $0.data as Any) }, uniquingKeysWith: { first, _ in first })
        }.filter { !$0.isEmpty }
        let urls = files.resolvedFileURLs(for: entry)
        if !urls.isEmpty {
            do {
                let filePayload = try await Self.prepareCopyFiles(urls, readFile: readCopyFile)
                payload.append(contentsOf: filePayload.map { $0.mapValues { $0 as Any } })
            } catch is CancellationError {
                return false
            } catch {
                let isCurrent = !Task.isCancelled && copyRequestID == requestID
                diagnostics.record(.failure(
                    operation: "clipboard.copy_file",
                    error: error,
                    visibility: isCurrent ? .user : .background
                ))
                guard isCurrent else { return false }
                let message = String(localized: "This file isn’t on this device. If it synced before, sync your clipboard and try again.")
                operationErrorMessage = message
                operationFailure = AppFailure(message: message, operation: "clipboard.copy_file", diagnosticCode: diagnosticErrorCode(error))
                return false
            }
        }
        guard !Task.isCancelled, copyRequestID == requestID, !payload.isEmpty else { return false }
        UIPasteboard.general.setItems(payload)
        return true
    }

    @concurrent private nonisolated static func prepareCopyFiles(
        _ urls: [URL],
        readFile: @Sendable (URL) throws -> Data
    ) async throws -> [[String: Data]] {
        try urls.map { url in
            try Task.checkCancellation()
            let data = try readFile(url)
            try Task.checkCancellation()
            let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
            return [type: data]
        }
    }

    static func previewText(from items: [ClipboardPayloadItem]) -> String {
        items.compactMap { item -> String? in
            let plainText = ClipboardEntry.extractText(from: [item])
            if !plainText.isEmpty { return plainText }
            if let url = item.representations.first(where: { $0.type == UTType.url.identifier }),
               let text = String(data: url.data, encoding: .utf8) { return text }
            for representation in item.representations {
                let documentType: NSAttributedString.DocumentType
                switch representation.type {
                case UTType.rtf.identifier: documentType = .rtf
                case UTType.html.identifier: documentType = .html
                default: continue
                }
                if let attributed = try? NSAttributedString(
                    data: representation.data,
                    options: [.documentType: documentType],
                    documentAttributes: nil
                ) {
                    let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { return text }
                }
            }
            return nil
        }.joined(separator: "\n")
    }

    private func savePendingUploads() {
        preferences.set(pendingUploadIDs.map(\.uuidString), forKey: "clipboardPendingUploads")
    }

    func dismissPasteError() { pasteErrorMessage = nil }

    private enum PasteError: Error, AppDiagnosticErrorCodeProviding {
        case empty, unsupported, unreadable, tooLarge

        var appDiagnosticCode: String {
            switch self {
            case .empty: "clipboard.empty"
            case .unsupported: "clipboard.unsupported"
            case .unreadable: "clipboard.unreadable"
            case .tooLarge: "clipboard.tooLarge"
            }
        }
    }

    func capture(_ providers: [NSItemProvider]) async {
        guard !isPasting else { return }
        isPasting = true
        defer { isPasting = false }
        pasteErrorMessage = nil
        do {
            guard !providers.isEmpty else { throw PasteError.empty }
            var attemptedRead = false
            var items: [ClipboardPayloadItem] = []
            let types = Self.representationTypes
            for provider in providers {
                var representations: [ClipboardRepresentation] = []
                let imageTypes = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
                    .filter { $0.conforms(to: .image) && !types.contains($0) }
                for type in types + imageTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                    attemptedRead = true
                    let data: Data
                    do {
                        data = try await withCheckedThrowingContinuation { continuation in
                            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                                if let data { continuation.resume(returning: data) }
                                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                            }
                        }
                    } catch {
                        diagnostics.record(.failure(
                            operation: "clipboard.paste_read",
                            error: error,
                            visibility: .background
                        ))
                        continue
                    }
                    guard data.count <= ClipboardHistoryState.representationByteLimit else { throw PasteError.tooLarge }
                    representations.append(ClipboardRepresentation(type: type.identifier, data: data))
                }
                if !representations.isEmpty { items.append(ClipboardPayloadItem(representations: representations)) }
            }
            guard !items.isEmpty else { throw attemptedRead ? PasteError.unreadable : PasteError.unsupported }
            let entry = ClipboardEntry(sourceApplication: "Paste", items: items,
                plainText: Self.previewText(from: items), sourceDeviceName: UIDevice.current.model)
            guard entry.byteCount <= ClipboardHistoryState.entryByteLimit else { throw PasteError.tooLarge }
            entries = try await store.insert(entry).entries
            if syncEnabled {
                pendingUploadIDs.formUnion(entries.filter { $0.hasSamePayload(as: entry) }.map(\.id))
                savePendingUploads()
            }
            errorMessage = nil
            await synchronize()
        } catch PasteError.empty {
            recordPasteFailure(.empty)
            pasteErrorMessage = String(localized: "There’s nothing to paste. Copy text or an image, then try again.")
        } catch PasteError.unsupported {
            recordPasteFailure(.unsupported)
            pasteErrorMessage = String(localized: "This clipboard content isn’t supported. Try copying text or an image.")
        } catch PasteError.unreadable {
            recordPasteFailure(.unreadable)
            pasteErrorMessage = String(localized: "Couldn’t read the clipboard. Copy the content again, then tap Paste.")
        } catch PasteError.tooLarge {
            recordPasteFailure(.tooLarge)
            pasteErrorMessage = String(localized: "This clipboard content is too large to paste.")
        } catch {
            diagnostics.record(.failure(
                operation: "clipboard.paste",
                error: error,
                visibility: .user
            ))
            pasteErrorMessage = String(localized: "Couldn’t save the pasted content. Try again.")
        }
    }

    func presentError(
        _ error: any Error,
        operation: StaticString,
        message: String
    ) {
        diagnostics.record(.failure(operation: operation, error: error, visibility: .user))
        operationErrorMessage = message
        operationFailure = AppFailure(message: message, operation: operation, diagnosticCode: diagnosticErrorCode(error))
    }

    private func recordPasteFailure(_ error: PasteError) {
        diagnostics.record(.failure(
            operation: "clipboard.paste",
            error: error,
            visibility: .user
        ))
    }
}
