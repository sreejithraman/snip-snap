import SnipSnapCore
import SwiftUI

struct SyncedContentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SyncedContentSettingsModel
    @State private var confirmsDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync") {
                    Label(model.statusTitle, systemImage: statusImage)
                        .accessibilityIdentifier("sync-status")
                    Text(model.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if case .enabling = model.state {
                    Section {
                        ProgressView("Setting up iCloud Sync…")
                    }
                } else if case .deleting = model.state {
                    Section {
                        ProgressView("Deleting synced content…")
                    }
                } else if case .resolvingEncryptedDataReset = model.state {
                    Section {
                        ProgressView("Starting a new synced collection…")
                    }
                } else if case .encryptedDataReset = model.state {
                    Section("Choose What to Do") {
                        Button("Restore from This Device") {
                            Task {
                                await model.resolveEncryptedDataReset(.restoreFromThisDevice)
                            }
                        }
                        .accessibilityIdentifier("encrypted-reset-restore")

                        Button("Start Empty") {
                            Task { await model.resolveEncryptedDataReset(.startEmpty) }
                        }
                        .accessibilityIdentifier("encrypted-reset-start-empty")

                        Button("Keep Sync Off") {
                            Task { await model.resolveEncryptedDataReset(.keepSyncOff) }
                        }
                        .accessibilityIdentifier("encrypted-reset-keep-off")
                    }
                } else if model.canEnable {
                    Section {
                        Button("Enable iCloud Sync…") {
                            Task { await model.enableICloudSync() }
                        }
                        .accessibilityIdentifier("enable-icloud-sync")
                    }
                } else if model.canDelete {
                    Section {
                        Button("Delete Synced Content…", role: .destructive) {
                            confirmsDelete = true
                        }
                        .accessibilityIdentifier("delete-synced-content")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Delete Synced Content?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Synced Content", role: .destructive) {
                Task { await model.deleteSyncedContent() }
            }
        } message: {
            Text("This starts a fresh empty synced collection and removes the old synced snips and attachments from iCloud. This device keeps a local recovery copy. A small control record remains in iCloud to stop old devices from restoring deleted content.")
        }
    }

    private var statusImage: String {
        switch model.mode {
        case .localOnly: "internaldrive"
        case .iCloudSync: "icloud"
        }
    }
}
