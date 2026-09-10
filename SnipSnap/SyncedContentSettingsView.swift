import SnipSnapCloud
import SnipSnapCore
import SwiftUI

struct SyncedContentSettingsView: View {
    @Bindable var model: SyncedContentSettingsModel
    @ObservedObject var clipboard: ClipboardHistory
    @State private var confirmsClipboardSync = false
    @State private var clipboardDeleteError: String?
    var retryAction: (@MainActor @Sendable () async -> Void)?
    @State private var confirmsDelete = false
    @State private var confirmsUsingDeviceCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Sync with iCloud", isOn: syncEnabled)
                .disabled(!canChangeSync)
                .accessibilityIdentifier("icloud-sync-toggle")

            Toggle("Sync clipboard history", isOn: Binding(
                get: { clipboard.clipboardSyncEnabled },
                set: { enabled in
                    if enabled { confirmsClipboardSync = true }
                    else { clipboard.setSyncEnabled(false) }
                }
            ))
            .disabled(model.mode != .iCloudSync)
            .accessibilityIdentifier("clipboard-sync-toggle")
            if let error = clipboard.syncError {
                Text(error).foregroundStyle(.secondary)
                Button("Retry Clipboard Sync") { Task { await clipboard.syncNow() } }
            }

            Label(model.statusTitle, systemImage: statusImage)
                .font(.headline)
                .accessibilityIdentifier("sync-status")

            Text(model.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.canRetryFailedSync, let retryAction {
                Button("Try Again") { Task { await retryAction() } }
                    .accessibilityIdentifier("retry-icloud-sync")
            }

            Spacer(minLength: 0)

            if case .enabling = model.state {
                ProgressView("Setting up iCloud Sync…")
                    .controlSize(.small)
            } else if case .syncing = model.state {
                ProgressView("Syncing with iCloud…")
                    .controlSize(.small)
            } else if case .disabling = model.state {
                ProgressView("Making a local copy…")
                    .controlSize(.small)
            } else if case .deleting = model.state {
                ProgressView("Deleting synced content…")
                    .controlSize(.small)
            } else if model.canDelete {
                Button("Delete Synced Content…", role: .destructive) {
                    confirmsDelete = true
                }
                .accessibilityIdentifier("delete-synced-content")
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .topLeading)
        .alert("Delete Synced Content?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Synced Content", role: .destructive) {
                Task {
                    do {
                        try await clipboard.deleteSyncedHistory()
                        await model.deleteSyncedContent()
                    } catch {
                        clipboardDeleteError = ClipboardSyncErrorMessage.deleteSyncedHistory(for: error)
                    }
                }
            }
        } message: {
            Text("This starts a new, empty synced library. It deletes synced snips, attachments, and clipboard history—including pins—from iCloud. This Mac keeps a local recovery copy. A small iCloud record remains so older devices cannot restore deleted content.")
        }
        .alert("Sync Clipboard History?", isPresented: $confirmsClipboardSync) {
            Button("Cancel", role: .cancel) {}
            Button("Enable Sync") { clipboard.setSyncEnabled(true) }
        } message: {
            Text("Text and image entries, pinned files, and files that synced before will upload to your private iCloud and merge with your other devices. Other files stay on this Mac until pinned.")
        }
        .alert("Couldn’t Delete Synced Content", isPresented: Binding(get: { clipboardDeleteError != nil }, set: { if !$0 { clipboardDeleteError = nil } })) {
            Button("OK") { clipboardDeleteError = nil }
        } message: { Text(clipboardDeleteError ?? "") }
        .alert("Use This Mac’s Copy?", isPresented: $confirmsUsingDeviceCopy) {
            Button("Cancel", role: .cancel) {}
            Button("Use Mac Copy") {
                Task { await model.disableICloudSync(.useCurrentCache) }
            }
        } message: {
            Text("Snip Snap couldn’t get the latest changes from iCloud. Keep sync on and try again, or turn it off and use the copy on this Mac. That copy may not include recent changes from other devices. This does not delete iCloud data.")
        }
    }

    init(
        model: SyncedContentSettingsModel,
        clipboard: ClipboardHistory,
        retryAction: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        self.model = model
        self.clipboard = clipboard
        self.retryAction = retryAction
    }

    private var syncEnabled: Binding<Bool> {
        Binding(
            get: {
                if case .enabling = model.state { return true }
                return model.mode == .iCloudSync
            },
            set: { enabled in
                Task {
                    if enabled {
                        await model.enableICloudSync()
                    } else if model.canCancelEnable {
                        await model.cancelICloudSyncSetup()
                    } else {
                        clipboard.stopSync()
                        await model.disableICloudSync(.refreshThenCopy)
                        if model.mode == .iCloudSync, case .failed = model.state {
                            confirmsUsingDeviceCopy = true
                        }
                    }
                }
            }
        )
    }

    private var canChangeSync: Bool {
        if model.canCancelEnable { return true }
        return model.mode == .iCloudSync ? model.canDisable : model.canEnable
    }

    private var statusImage: String {
        switch model.mode {
        case .localOnly: "internaldrive"
        case .iCloudSync: "icloud"
        }
    }
}
