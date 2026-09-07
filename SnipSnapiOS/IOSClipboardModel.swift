import Foundation
import Observation
import SnipSnapCloud
import SnipSnapCore
import SnipSnapPersistence
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable
final class IOSClipboardModel {
    private let store: ClipboardHistoryStore
    private let files: ClipboardFileStore
    private let imports: ShareClipboardImportStore
    private let settings: SyncedContentSettingsModel
    private let cloud: ClipboardCloudSyncService?
    private let generation: @MainActor () async throws -> String?
    private let preferences: UserDefaults
    private(set) var entries: [ClipboardEntry] = []
    private(set) var pendingUploadIDs: Set<UUID> = []
    private(set) var isSyncing = false
    private(set) var syncEnabled: Bool
    var errorMessage: String?
    var copied = false
    var localDeviceLabel: String {
        UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "Only on this iPad") : String(localized: "Only on this iPhone")
    }

    init(rootURL: URL, settings: SyncedContentSettingsModel, containerIdentifier: String? = nil,
         preferences: UserDefaults = .standard,
         generation: @escaping @MainActor () async throws -> String? = { nil }) {
        let store = ClipboardHistoryStore(url: rootURL.appendingPathComponent("clipboard.json"))
        let files = ClipboardFileStore(rootURL: rootURL.appendingPathComponent("ClipboardFiles", isDirectory: true))
        self.store = store
        self.files = files
        imports = ShareClipboardImportStore(sharedRootURL: rootURL)
        self.settings = settings
        self.generation = generation
        self.preferences = preferences
        syncEnabled = preferences.bool(forKey: "syncClipboardHistory")
        pendingUploadIDs = Set((preferences.stringArray(forKey: "clipboardPendingUploads") ?? []).compactMap(UUID.init(uuidString:)))
        cloud = containerIdentifier.map {
            ClipboardCloudSyncService(store: store, containerIdentifier: $0,
                syncRootURL: rootURL.appendingPathComponent("SyncMode", isDirectory: true))
        }
    }

    func setSyncEnabled(_ enabled: Bool) async {
        if !enabled { cloud?.stop() }
        syncEnabled = enabled
        preferences.set(enabled, forKey: "syncClipboardHistory")
        if enabled {
            await load()
            pendingUploadIDs.formUnion(entries.filter(\.isSyncEligible).map(\.id))
            savePendingUploads()
        }
        await synchronize()
    }

    func load() async {
        do { entries = try await store.load().entries }
        catch { errorMessage = error.localizedDescription }
    }

    func foreground() async {
        let previousIDs = Set(entries.map(\.id))
        let store = store
        let files = files
        let device = UIDevice.current.model
        let summary = await imports.importPendingWithRepresentations { request, urls, richText in
            var items: [ClipboardPayloadItem] = []
            if !request.content.isEmpty {
                items.append(ClipboardPayloadItem(representations: [ClipboardRepresentation(type: UTType.utf8PlainText.identifier, data: Data(request.content.utf8))] + richText))
            }
            for (index, url) in urls.enumerated() {
                let type = request.attachments.indices.contains(index)
                    ? request.attachments[index].contentType.flatMap { UTType($0) }
                    : UTType(filenameExtension: url.pathExtension)
                if let type, type.conforms(to: .image) {
                    let data = try Data(contentsOf: url)
                    guard let data else { continue }
                    guard data.count <= ClipboardHistoryState.representationByteLimit else { throw CocoaError(.fileReadTooLarge) }
                    items.append(ClipboardPayloadItem(representations: [ClipboardRepresentation(type: type.identifier, data: data)]))
                } else {
                    items.append(ClipboardPayloadItem(representations: [ClipboardRepresentation(type: UTType.fileURL.identifier, data: Data(url.absoluteString.utf8))]))
                }
            }
            var entry = ClipboardEntry(id: request.requestID, capturedAt: request.createdAt,
                sourceApplication: "Share", items: items, sourceDeviceName: device)
            guard entry.byteCount <= ClipboardHistoryState.entryByteLimit else { throw CocoaError(.fileReadTooLarge) }
            entry = try files.preserveFiles(of: entry)
            _ = try await store.insert(entry)
        }
        if summary.imported > 0 && syncEnabled {
            await load()
            pendingUploadIDs.formUnion(entries.filter { $0.isSyncEligible && !previousIDs.contains($0.id) }.map(\.id))
            savePendingUploads()
        }
        if summary.failed > 0 { errorMessage = String(localized: "Some shared content could not be added. Try again.") }
        await synchronize()
    }

    func synchronize() async {
        guard !isSyncing else { return }
        switch settings.state {
        case .disabling, .deleting: cloud?.stop(); return
        default: break
        }
        await load()
        guard let cloud, syncEnabled, settings.mode == .iCloudSync else { cloud?.stop(); return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            guard let generation = try await generation() else { return }
            entries = try await cloud.synchronize(mainSyncEnabled: true, clipboardSyncEnabled: true, generation: generation).entries
            errorMessage = nil
            pendingUploadIDs = []
            savePendingUploads()
        } catch {
            if error is CancellationError { return }
            pendingUploadIDs.formUnion(cloud.pendingEntryIDs)
            savePendingUploads()
            errorMessage = error.localizedDescription
        }
    }

    func stop() { cloud?.stop() }

    func deleteSyncedHistory() async throws {
        guard let cloud, let generation = try await generation() else { return }
        try await cloud.deleteSyncedHistory(generation: generation)
        await load()
    }

    func resetAccountBinding() async {
        do { try await cloud?.resetAccountBinding(); await load() }
        catch { errorMessage = error.localizedDescription }
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
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ entry: ClipboardEntry) async {
        do {
            entries = try await store.delete(id: entry.id).entries
            pendingUploadIDs.remove(entry.id)
            savePendingUploads()
            await synchronize()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func clear() async {
        do {
            entries = try await store.clearUnpinned().entries
            pendingUploadIDs.formIntersection(entries.map(\.id))
            savePendingUploads()
            await synchronize()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func copy(_ entry: ClipboardEntry) {
        var payload = entry.items.map { item in
            Dictionary(item.representations.filter { $0.type != UTType.fileURL.identifier }.map { ($0.type, $0.data as Any) }, uniquingKeysWith: { first, _ in first })
        }.filter { !$0.isEmpty }
        for url in files.resolvedFileURLs(for: entry) {
            guard let data = try? Data(contentsOf: url) else {
                errorMessage = String(localized: "That file is unavailable. Try syncing again.")
                return
            }
            let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
            payload.append([type: data])
        }
        guard !payload.isEmpty else { return }
        UIPasteboard.general.setItems(payload)
        copied = true
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

    func capture(_ providers: [NSItemProvider]) async {
        do {
            var items: [ClipboardPayloadItem] = []
            let types = [UTType.utf8PlainText, .plainText, .url, .rtf, .html, .png, .jpeg, .tiff]
            for provider in providers {
                var representations: [ClipboardRepresentation] = []
                let imageTypes = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
                    .filter { $0.conforms(to: .image) && !types.contains($0) }
                for type in types + imageTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                    let data: Data? = try? await withCheckedThrowingContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                            if let data { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                        }
                    }
                    guard let data else { continue }
                    guard data.count <= ClipboardHistoryState.representationByteLimit else { throw CocoaError(.fileReadTooLarge) }
                    representations.append(ClipboardRepresentation(type: type.identifier, data: data))
                }
                if !representations.isEmpty { items.append(ClipboardPayloadItem(representations: representations)) }
            }
            guard !items.isEmpty else { throw CocoaError(.fileReadUnknown) }
            let entry = ClipboardEntry(sourceApplication: "Paste", items: items,
                plainText: Self.previewText(from: items), sourceDeviceName: UIDevice.current.model)
            guard entry.byteCount <= ClipboardHistoryState.entryByteLimit else { throw CocoaError(.fileReadTooLarge) }
            entries = try await store.insert(entry).entries
            if syncEnabled {
                pendingUploadIDs.formUnion(entries.filter { $0.hasSamePayload(as: entry) }.map(\.id))
                savePendingUploads()
            }
            errorMessage = nil
            await synchronize()
        } catch { errorMessage = error.localizedDescription }
    }
}
