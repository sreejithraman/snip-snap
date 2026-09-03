import SnipSnapCore
import SwiftUI

struct SyncedContentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SyncedContentSettingsModel
    var retryAction: (@MainActor @Sendable () async -> Void)?
    @State private var confirmsDelete = false
    @State private var confirmsUsingDeviceCopy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync") {
                    Toggle("Sync with iCloud", isOn: syncEnabled)
                        .disabled(!canChangeSync)
                        .accessibilityIdentifier("icloud-sync-toggle")
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
        .onAppear(perform: showUITestIssueIfNeeded)
        .alert("Delete Synced Content?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Synced Content", role: .destructive) {
                Task { await model.deleteSyncedContent() }
            }
        } message: {
            Text("This starts a fresh empty synced collection and removes the old synced snips and attachments from iCloud. This device keeps a local recovery copy. A small control record remains in iCloud to stop old devices from restoring deleted content.")
        }
        .alert("Use This Device’s Copy?", isPresented: $confirmsUsingDeviceCopy) {
            Button("Cancel", role: .cancel) {}
            Button("Use Device Copy") {
                Task { await model.disableICloudSync(.useCurrentCache) }
            }
        } message: {
            Text("Snip Snap could not refresh iCloud. You can keep sync on and try again, or turn it off with the copy already on this device. That copy may not include recent changes from other devices. Your iCloud data will not be deleted.")
        }
    }

    init(
        model: SyncedContentSettingsModel,
        retryAction: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        self.model = model
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
