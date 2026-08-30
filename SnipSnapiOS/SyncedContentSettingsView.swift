import SnipSnapCore
import SwiftUI

struct SyncedContentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SyncedContentSettingsModel
    @State private var confirmsDelete = false
    @State private var confirmsUsingDeviceCopy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync") {
                    HStack {
                        Text("Sync with iCloud")
                        Spacer()
                        Toggle("Sync with iCloud", isOn: syncEnabled)
                            .labelsHidden()
                            .disabled(!canChangeSync)
                            .accessibilityIdentifier("icloud-sync-toggle")
                            .accessibilityLabel("Sync with iCloud")
                    }
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
                } else if case .disabling = model.state {
                    Section {
                        ProgressView("Making a local copy…")
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
        .alert("Use This Device’s Copy?", isPresented: $confirmsUsingDeviceCopy) {
            Button("Cancel", role: .cancel) {}
            Button("Use Device Copy") {
                Task { await model.disableICloudSync(.useCurrentCache) }
            }
        } message: {
            Text("Snip Snap could not refresh iCloud. You can keep sync on and try again, or turn it off with the copy already on this device. That copy may not include recent changes from other devices. Your iCloud data will not be deleted.")
        }
    }

    private var syncEnabled: Binding<Bool> {
        Binding(
            get: { model.mode == .iCloudSync },
            set: { enabled in
                Task {
                    if enabled {
                        await model.enableICloudSync()
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

    private var canChangeSync: Bool {
        model.mode == .iCloudSync ? model.canDisable : model.canEnable
    }

    private var statusImage: String {
        switch model.mode {
        case .localOnly: "internaldrive"
        case .iCloudSync: "icloud"
        }
    }
}
