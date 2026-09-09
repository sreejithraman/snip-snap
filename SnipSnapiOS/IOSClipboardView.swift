import SnipSnapCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct IOSClipboardView: View {
    let model: IOSClipboardModel
    let libraryModel: IOSAppModel
    let copyShare: IOSCopyShareCoordinator
    @Binding var sheet: AppSheet?
    var settings: () -> Void = {}
    @State private var onlyPinned = false
    @State private var newestFirst = true
    @State private var confirmsClear = false

    private var entries: [ClipboardEntry] {
        Self.orderedEntries(model.entries.filter {
            !onlyPinned || $0.isPinned
        }, newestFirst: newestFirst)
    }

    static func orderedEntries(_ entries: [ClipboardEntry], newestFirst: Bool) -> [ClipboardEntry] {
        let ordered = ClipboardHistoryState.ordered(entries)
        guard !newestFirst else { return ordered }
        return ordered.filter(\.isPinned) + ordered.filter { !$0.isPinned }.reversed()
    }

    private var emptyTitle: String {
        return onlyPinned ? String(localized: "No pinned entries") : String(localized: "Nothing captured yet")
    }

    private var emptyDetail: String {
        return onlyPinned ? String(localized: "Pin a clipboard entry to keep it here.")
            : String(localized: "Paste here or share content to Clipboard.")
    }

    @ViewBuilder
    private var clipboardToolbar: some View {
        Group {
            Menu("View Options", systemImage: "line.3.horizontal.decrease") {
                Section("Show") {
                    Picker("Show", selection: $onlyPinned) {
                        Text("All").tag(false)
                        Text("Pinned").tag(true)
                    }.pickerStyle(.inline)
                }
                Section("Sort") {
                    Picker("Sort", selection: $newestFirst) {
                        Text("Newest First").tag(true)
                        Text("Oldest First").tag(false)
                    }.pickerStyle(.inline)
                }
            }
            .accessibilityIdentifier("workflow-options")
            Menu("Library Actions", systemImage: "ellipsis") {
                Button("Clear History", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    .disabled(!model.entries.contains { !$0.isPinned })
                Divider()
                Button("Settings", systemImage: "gearshape", action: settings)
                    .accessibilityIdentifier("settings")
            }
            .accessibilityIdentifier("library-actions")
        }
    }

    var body: some View {
        Group {
            if libraryModel.isSearchPresented {
                LibrarySearchView(model: libraryModel, clipboard: model, copyShare: copyShare, sheet: $sheet)
            } else {
                clipboardContent
            }
        }
        .modifier(CollectionScreenPresentation(
            title: String(localized: "Clipboard"),
            showsControls: !libraryModel.isSearchPresented,
            trailingControls: clipboardToolbar
        ))
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
                    Button("Retry") { Task { await model.foreground() } }
                }
            }
            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.icloud")
                    Button("Retry") { Task { await model.synchronize() } }
                }
            }
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 12) {
                    SnipCopyControl { model.copy(entry) }
                    .accessibilityLabel("Copy Clipboard Entry")
                    VStack(alignment: .leading, spacing: 6) {
                        if let image = entry.imageRepresentations.first.flatMap({ UIImage(data: $0.data) }) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 120)
                        }
                        Text(entry.text.isEmpty ? (entry.imageRepresentations.isEmpty ? String(localized: "Clipboard Entry") : String(localized: "Image")) : entry.text)
                            .lineLimit(3)
                        SnipRowMetadata(date: entry.capturedAt, isPinned: entry.isPinned)
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
                                Button("Retry") { Task { await model.synchronize() } }
                                    .buttonStyle(.borderless)
                            } else {
                                Label(model.isSyncing ? "Uploading…" : "Waiting for sync", systemImage: "icloud.and.arrow.up")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
                .accessibilityValue(entry.isPinned ? String(localized: "Pinned") : "")
                .accessibilityAction(named: Text(entry.isPinned ? "Unpin" : "Pin")) {
                    Task { await model.togglePin(entry) }
                }
                .accessibilityAction(named: "Copy") { model.copy(entry) }
                .id("\(entry.id.uuidString)-\(entry.isPinned)")
                .accessibilityIdentifier("clipboard-entry-\(entry.id)")
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { model.copy(entry) }
                    Button(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.slash" : "pin") {
                        Task { await model.togglePin(entry) }
                    }
                    Button("Delete", role: .destructive) { Task { await model.delete(entry) } }
                }
                .swipeActions(edge: .leading) {
                    Button(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.slash" : "pin") {
                        Task { await model.togglePin(entry) }
                    }.tint(.orange)
                }
                .swipeActions {
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
                    systemImage: onlyPinned ? "pin" : "clipboard",
                    detail: emptyDetail
                )
                .accessibilityIdentifier("empty-clipboard")
            }
        }
        .confirmationDialog("Clear Clipboard History?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { Task { await model.clear() } }
        } message: {
            Text(model.syncIsActive ? "This clears unpinned history across synced devices. Pins stay." : "This clears unpinned history on this device. Pins stay.")
        }
        .overlay(alignment: .bottom) {
            if model.copied {
                Label("Copied", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        model.copied = false
                    }
            }
        }
        .task { await model.load() }
        .refreshable { await model.synchronize() }
    }
}
