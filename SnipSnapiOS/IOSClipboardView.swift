import SnipSnapCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct IOSClipboardView: View {
    let model: IOSClipboardModel
    @State private var searchText = ""
    @State private var confirmsClear = false
    @State private var previewEntry: ClipboardEntry?

    private var entries: [ClipboardEntry] {
        model.entries.filter { searchText.isEmpty || $0.searchText.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
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
                            if model.syncEnabled {
                                Text("Pin to sync this file").font(.caption).foregroundStyle(.secondary)
                            }
                        } else if model.syncEnabled && model.pendingUploadIDs.contains(entry.id) {
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
        .environment(\.defaultMinListRowHeight, 24)
        .overlay {
            if entries.isEmpty && model.errorMessage == nil {
                ContentUnavailableView("No Clipboard Entries", systemImage: "clipboard", description: Text("Paste here or share content to Clipboard. Turn on clipboard sync in Settings to see your Mac history."))
            }
        }
        .navigationTitle("Clipboard")
        .searchable(text: $searchText, prompt: "Search Clipboard")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                PasteButton(supportedContentTypes: [.text, .url, .image]) { providers in
                    Task { await model.capture(providers) }
                }
                .accessibilityIdentifier("paste-to-clipboard")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear History", systemImage: "trash") { confirmsClear = true }
                    .disabled(!model.entries.contains { !$0.isPinned })
            }
        }
        .confirmationDialog("Clear Clipboard History?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { Task { await model.clear() } }
        } message: {
            Text(model.syncEnabled ? "This clears unpinned history across synced devices. Pins stay." : "This clears unpinned history on this device. Pins stay.")
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
