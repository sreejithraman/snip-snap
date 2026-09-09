import SnipSnapCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct IOSClipboardView: View {
    let model: IOSClipboardModel
    var settings: () -> Void = {}
    var dismissComposerKeyboard: () -> Void = {}
    @State private var isSearchPresented = false
    @State private var onlyPinned = false
    @State private var newestFirst = true
    @State private var searchText = ""
    @State private var confirmsClear = false
    @State private var previewEntry: ClipboardEntry?

    private var entries: [ClipboardEntry] {
        model.entries.filter {
            (!onlyPinned || $0.isPinned)
                && (searchText.isEmpty || $0.searchText.localizedCaseInsensitiveContains(searchText))
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return newestFirst ? $0.capturedAt > $1.capturedAt : $0.capturedAt < $1.capturedAt
        }
    }

    var body: some View {
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
                    .onTapGesture { previewEntry = entry }
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
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onChanged { value in
                guard value.translation.height > 8,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                dismissComposerKeyboard()
            }
        )
        .overlay {
            if entries.isEmpty && model.errorMessage == nil && model.importErrorMessage == nil && model.pasteErrorMessage == nil {
                CollectionEmptyState(
                    title: searchText.isEmpty ? String(localized: "Nothing captured yet") : String(localized: "No Results"),
                    systemImage: searchText.isEmpty ? "clipboard" : "magnifyingglass",
                    detail: searchText.isEmpty ? String(localized: "Paste here or share content to Clipboard.") : String(localized: "Try a different search.")
                )
                .accessibilityIdentifier("empty-clipboard")
            }
        }
        .modifier(CollectionScreenPresentation(
            title: String(localized: "Clipboard"),
            searchText: $searchText,
            isSearchPresented: $isSearchPresented
        ))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
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
        .sheet(item: $previewEntry) { entry in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(entry.imageRepresentations.enumerated()), id: \.offset) { _, representation in
                            if let image = UIImage(data: representation.data) {
                                Image(uiImage: image).resizable().scaledToFit()
                            }
                        }
                        Text(entry.text).textSelection(.enabled)
                    }.padding()
                }
                .navigationTitle("Clipboard Entry")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Copy") { model.copy(entry) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { previewEntry = nil }
                    }
                }
            }
        }
        .task { await model.load() }
        .refreshable { await model.synchronize() }
    }
}
