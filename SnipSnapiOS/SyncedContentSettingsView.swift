import SnipSnapCloud
import SnipSnapCore
import SwiftUI

struct SyncedContentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SyncedContentSettingsModel
    var clipboard: IOSClipboardModel?
    @Bindable var haptics: IOSHapticFeedback
    var retryAction: (@MainActor @Sendable () async -> Void)?
    @State private var confirmsClipboardSync = false
    @State private var confirmsDelete = false
    @State private var confirmsUsingDeviceCopy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Haptics", isOn: $haptics.isEnabled)
                        .accessibilityIdentifier("haptics-toggle")
                }

                Section("Sync") {
                    Toggle("Sync with iCloud", isOn: syncEnabled)
                        .disabled(!canChangeSync)
                        .accessibilityIdentifier("icloud-sync-toggle")
                    if let clipboard {
                        Toggle("Sync clipboard history", isOn: Binding(
                            get: { clipboard.syncEnabled },
                            set: { enabled in
                                if enabled { confirmsClipboardSync = true }
                                else { Task { await clipboard.setSyncEnabled(false) } }
                            }
                        ))
                        .disabled(model.mode != .iCloudSync)
                        .accessibilityIdentifier("clipboard-sync-toggle")
                        Text("Includes text, images, pinned files, and files synced before. Turning this off keeps local history and leaves iCloud data intact.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = clipboard?.errorMessage {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    Label(model.statusTitle, systemImage: statusImage)
                        .accessibilityIdentifier("sync-status")
                    Text(model.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if model.canRetryFailedSync, let retryAction {
                        Button("Try Again") { Task { await retryAction() } }
                            .accessibilityIdentifier("retry-icloud-sync")
                    }
                }

                if case .enabling = model.state {
                    Section {
                        ProgressView("Setting up iCloud Sync…")
                    }
                } else if case .syncing = model.state {
                    Section {
                        ProgressView("Syncing with iCloud…")
                    }
                } else if case .disabling = model.state {
                    Section {
                        ProgressView("Making a local copy…")
                    }
                } else if case .deleting = model.state {
                    Section {
                        ProgressView("Deleting synced content…")
                    }
                } else if model.canDelete {
                    Section {
                        Button("Delete Synced Content…", role: .destructive) {
                            confirmsDelete = true
                        }
                        .accessibilityIdentifier("delete-synced-content")
                    }
                }

                Section("About") {
                    Link(
                        "Privacy Policy",
                        destination: URL(string: "https://sree.world/snip-snap/privacy")!
                    )
                    .accessibilityIdentifier("privacy-policy")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Sync Clipboard History?", isPresented: $confirmsClipboardSync) {
            Button("Cancel", role: .cancel) {}
            Button("Enable Sync") { Task { await clipboard?.setSyncEnabled(true) } }
        } message: {
            Text("Text and image entries, pinned files, and files that synced before will upload to your private iCloud and merge with your other devices. Other files stay on this device until pinned.")
        }
        .onAppear(perform: showUITestIssueIfNeeded)
        .alert("Delete Synced Content?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Synced Content", role: .destructive) {
                Task {
                    do {
                        try await clipboard?.deleteSyncedHistory()
                        await model.deleteSyncedContent()
                    } catch {
                        clipboard?.errorMessage = ClipboardSyncErrorMessage.deleteSyncedHistory(for: error)
                    }
                }
            }
        } message: {
            Text("This starts a new, empty synced library. It deletes synced snips, attachments, and clipboard history—including pins—from iCloud. This device keeps a local recovery copy. A small iCloud record remains so older devices cannot restore deleted content.")
        }
        .alert("Use This Device’s Copy?", isPresented: $confirmsUsingDeviceCopy) {
            Button("Cancel", role: .cancel) {}
            Button("Use Device Copy") {
                Task { await model.disableICloudSync(.useCurrentCache) }
            }
        } message: {
            Text("Snip Snap couldn’t get the latest changes from iCloud. Keep sync on and try again, or turn it off and use the copy on this device. That copy may not include recent changes from other devices. This does not delete iCloud data.")
        }
    }

    init(
        model: SyncedContentSettingsModel,
        clipboard: IOSClipboardModel? = nil,
        haptics: IOSHapticFeedback,
        retryAction: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        self.model = model
        self.haptics = haptics
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
                if !enabled { clipboard?.stop() }
                Task {
                    if enabled {
                        await model.enableICloudSync()
                        await clipboard?.synchronize()
                    } else if model.canCancelEnable {
                        await model.cancelICloudSyncSetup()
                    } else {
                        await model.disableICloudSync(.refreshThenCopy)
                        if model.mode == .iCloudSync, case .failed = model.state {
                            confirmsUsingDeviceCopy = true
                        }
                    }
                }
            }
        )
    }

    private func showUITestIssueIfNeeded() {
#if DEBUG
        if ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_SYNC_ISSUE"] == "app-data" {
            model.recordSyncFailure(.appDataIssue)
        }
#endif
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
