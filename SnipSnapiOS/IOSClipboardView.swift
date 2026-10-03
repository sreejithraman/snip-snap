import Observation
import SnipSnapCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class ClipboardViewState {
    var onlyPinned = false
    var newestFirst = true
}

struct IOSClipboardView: View {
    let model: IOSClipboardModel
    let libraryModel: IOSAppModel
    let copyShare: IOSCopyShareCoordinator
    let syncedContentSettings: SyncedContentSettingsModel
    let syncNow: @MainActor () async -> Void
    @Binding var sheet: AppSheet?
    var settings: () -> Void = {}
    var isActivePage = true
    @State var viewState = ClipboardViewState()
    @State private var confirmsClear = false

    private var isSearching: Bool { isActivePage && libraryModel.isSearchPresented }

    private var entries: [ClipboardEntry] {
        ClipboardViewOptions(
            onlyPinned: viewState.onlyPinned,
            newestFirst: viewState.newestFirst
        ).apply(to: model.entries)
    }

    private var emptyTitle: String {
        return viewState.onlyPinned ? String(localized: "No pinned entries") : String(localized: "Nothing captured yet")
    }

    private var emptyDetail: String {
        return viewState.onlyPinned ? String(localized: "Pin a clipboard entry to keep it here.")
            : String(localized: "Paste here to add content.")
    }

    @ViewBuilder
    private var clipboardToolbar: some View {
        Group {
            Menu("View options", systemImage: "line.3.horizontal.decrease") {
                Section("Show") {
                    Picker("Show", selection: $viewState.onlyPinned) {
                        Text("All").tag(false)
                        Text("Pinned").tag(true)
                    }.pickerStyle(.inline)
                }
                Section("Sort") {
                    Picker("Sort", selection: $viewState.newestFirst) {
                        Text("Newest first").tag(true)
                        Text("Oldest first").tag(false)
                    }.pickerStyle(.inline)
                }
            }
            .accessibilityIdentifier("workflow-options")
            Menu("Library actions", systemImage: "ellipsis") {
                Button("Clear unpinned history", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    .disabled(!model.entries.contains { !$0.isPinned })
                Divider()
                LibrarySyncAction(syncedContentSettings: syncedContentSettings, syncNow: syncNow)
                Button("Settings", systemImage: "gearshape", action: settings)
                    .accessibilityIdentifier("settings")
            }
            .accessibilityIdentifier("library-actions")
        }
    }

    var body: some View {
        ZStack {
            clipboardContent
                .environment(\.attachmentPreparationIsActive, isActivePage && !isSearching)
                .opacity(isSearching ? 0 : 1)
                .allowsHitTesting(!isSearching)
                .accessibilityHidden(isSearching)
            if isSearching {
                LibrarySearchView(model: libraryModel, clipboard: model, copyShare: copyShare)
            }
        }
        .modifier(CollectionScreenPresentation(
            title: String(localized: "Clipboard"),
            showsControls: !libraryModel.isSearchPresented,
            trailingControls: clipboardToolbar
        ))
        .onChange(of: isActivePage) { _, active in
            if !active { confirmsClear = false }
        }
    }

    private var clipboardContent: some View {
        List {
            if let error = model.pasteErrorMessage {
                Section {
                    Label(error, systemImage: "clipboard")
                    Button("Dismiss") { model.dismissPasteError() }
                }
                .accessibilityIdentifier("clipboard-paste-error")
            }
            if let error = model.importErrorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Button("Retry import") { Task { await model.foreground() } }
                }
            }
            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.icloud")
                    Button("Retry clipboard sync") { Task { await model.synchronize() } }
                }
            }
            ForEach(entries) { entry in
                ClipboardItemRow(entry: entry, model: model, showsSyncStatus: true) {
                    copyShare.copyClipboardEntry(entry, clipboard: model)
                }
                .listRowSeparator(.hidden)
                .accessibilityValue(entry.isPinned ? String(localized: "Pinned") : "")
                .accessibilityAction(named: Text(entry.isPinned ? "Unpin" : "Pin")) {
                    Task { await model.togglePin(entry) }
                }
                .accessibilityAction(named: "Delete") {
                    Task { await model.delete(entry) }
                }
                .accessibilityAction(named: "Copy") {
                    copyShare.copyClipboardEntry(entry, clipboard: model)
                }
                .id("\(entry.id.uuidString)-\(entry.isPinned)")
                .accessibilityIdentifier("clipboard-entry-\(entry.id)")
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") {
                        copyShare.copyClipboardEntry(entry, clipboard: model)
                    }
                    Button(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.slash" : "pin") {
                        Task { await model.togglePin(entry) }
                    }
                    Button("Delete", role: .destructive) { Task { await model.delete(entry) } }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if entries.isEmpty && model.errorMessage == nil && model.importErrorMessage == nil && model.pasteErrorMessage == nil {
                CollectionEmptyState(
                    title: emptyTitle,
                    systemImage: viewState.onlyPinned ? "pin" : "clipboard",
                    detail: emptyDetail
                )
                .accessibilityIdentifier("empty-clipboard")
            }
        }
        .confirmationDialog("Clear unpinned history?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear unpinned history", role: .destructive) { Task { await model.clear() } }
        } message: {
            Text(model.syncIsActive ? "This clears unpinned history across synced devices. Pinned items stay." : "This clears unpinned history on this device. Pinned items stay.")
        }
        .overlay(alignment: .bottom) {
            if isActivePage && !isSearching && model.copied {
                Label("Copied", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
            }
        }
        .task { await model.load() }
        .refreshable { await model.synchronize() }
    }
}

/// Clipboard screen and search share the same row; hosts own menus and actions.
struct ClipboardItemRow: View {
    let entry: ClipboardEntry
    let model: IOSClipboardModel
    var showsSyncStatus = false
    let onCopy: () -> Void

    private var title: String {
        if !entry.text.isEmpty { return entry.text }
        if !entry.ownedFiles.isEmpty { return entry.ownedFiles.map(\.name).joined(separator: ", ") }
        return entry.imageRepresentations.isEmpty ? String(localized: "Clipboard Entry") : String(localized: "Image")
    }

    var body: some View {
        IOSItemRow {
            SnipCopyControl(action: onCopy)
                .accessibilityLabel("Copy Clipboard Entry")
        } content: {
            ItemRowContent {
                ItemRowText(text: title, accessibilityIdentifier: "clipboard-text-\(entry.id)")
            } previews: {
                ClipboardItemPreviews(entry: entry, fileURLs: model.previewFileURLs(for: entry))
                    // Sync can restore bytes at the same URL; retry only the preview subtree.
                    .id(model.filePreviewRevision)
            } metadata: {
                SnipRowMetadata(date: entry.capturedAt, isPinned: entry.isPinned, sourceApplication: entry.sourceApplication)
                if showsSyncStatus {
                    if !entry.isSyncEligible {
                        Label(model.localDeviceLabel, systemImage: "iphone")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.syncIsActive {
                            Text("Pin to sync this file").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if model.syncIsActive && model.pendingUploadIDs.contains(entry.id) {
                        if model.errorMessage != nil {
                            Label("Upload failed", systemImage: "exclamationmark.icloud")
                                .font(.caption).foregroundStyle(.red)
                            Button("Retry clipboard sync") { Task { await model.synchronize() } }
                                .buttonStyle(.borderless)
                        } else {
                            Label(model.isSyncing ? "Uploading…" : "Waiting for sync", systemImage: "icloud.and.arrow.up")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
    }
}

private struct ClipboardItemPreviews: View {
    let entry: ClipboardEntry
    let fileURLs: [URL]

    var body: some View {
        CompactItemPreviews(items: previews) { preview in
            if let data = preview.imageData {
                ClipboardImageThumbnail(
                    data: data,
                    id: "\(entry.id)|\(entry.fingerprint)|\(preview.id)"
                )
            } else if let url = preview.fileURL {
                AttachmentThumbnail(url: url)
            }
        }
    }

    private var previews: [ClipboardItemPreview] {
        entry.standaloneImageRepresentations.enumerated().map { index, representation in
            ClipboardItemPreview(id: "image-\(index)", imageData: representation.data)
        } + fileURLs.enumerated().map { index, url in
            ClipboardItemPreview(id: "file-\(index)", fileURL: url)
        }
    }
}

private struct ClipboardItemPreview: Identifiable {
    let id: String
    var imageData: Data? = nil
    var fileURL: URL? = nil
}
