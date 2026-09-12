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
                        Text("Turning this off doesn’t delete your history.")
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
                        Button("Retry sync") { Task { await retryAction() } }
                            .accessibilityIdentifier("retry-icloud-sync")
                    }
                }

                if case .enabling = model.state {
                    Section {
                        ProgressView("Setting up sync…")
                    }
                } else if case .syncing = model.state {
                    Section {
                        ProgressView("Syncing with iCloud…")
                    }
                } else if case .disabling = model.state {
                    Section {
                        ProgressView("Saving a copy…")
                    }
                } else if case .deleting = model.state {
                    Section {
                        ProgressView("Deleting synced content…")
                    }
                } else if model.canDelete {
                    Section {
                        Button("Delete synced content…", role: .destructive) {
                            confirmsDelete = true
                        }
                        .accessibilityIdentifier("delete-synced-content")
                    }
                }

                Section("About") {
                    Link(
                        "Privacy policy",
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
        .alert("Sync clipboard history?", isPresented: $confirmsClipboardSync) {
            Button("Cancel", role: .cancel) {}
            Button("Sync clipboard history") { Task { await clipboard?.setSyncEnabled(true) } }
        } message: {
            Text("Sync text, images, and pinned files across your devices. Files that have synced keep syncing after you unpin them.")
        }
        .onAppear(perform: showUITestIssueIfNeeded)
        .alert("Delete synced content?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete synced content", role: .destructive) {
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
            Text("Deletes synced snips, attachments, and clipboard history, including pins, from iCloud and your synced devices. This device keeps a recovery copy.")
        }
        .alert("Turn off sync?", isPresented: $confirmsUsingDeviceCopy) {
            Button("Cancel", role: .cancel) {}
            Button("Turn off sync") {
                Task { await model.disableICloudSync(.useCurrentCache) }
            }
        } message: {
            Text("Couldn’t get the latest iCloud changes. Turning off sync uses this device’s copy, which may be out of date. Your iCloud data stays.")
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
