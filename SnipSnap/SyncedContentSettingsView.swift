import SnipSnapCore
import SwiftUI

struct SyncedContentSettingsView: View {
    @Bindable var model: SyncedContentSettingsModel
    @State private var confirmsDelete = false
    @State private var confirmsUsingDeviceCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Sync with iCloud", isOn: syncEnabled)
                .disabled(!canChangeSync)
                .accessibilityIdentifier("icloud-sync-toggle")

            Label(model.statusTitle, systemImage: statusImage)
                .font(.headline)
                .accessibilityIdentifier("sync-status")

            Text(model.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if case .enabling = model.state {
                ProgressView("Setting up iCloud Sync…")
                    .controlSize(.small)
            } else if case .disabling = model.state {
                ProgressView("Making a local copy…")
                    .controlSize(.small)
            } else if case .deleting = model.state {
                ProgressView("Deleting synced content…")
                    .controlSize(.small)
            } else if case .resolvingEncryptedDataReset = model.state {
                ProgressView("Starting a new synced collection…")
                    .controlSize(.small)
            } else if case .encryptedDataReset = model.state {
                encryptedDataResetChoices
            } else if model.canDelete {
                Button("Delete Synced Content…", role: .destructive) {
                    confirmsDelete = true
                }
                .accessibilityIdentifier("delete-synced-content")
            }
        }
        .padding(20)
        .frame(width: 420, height: model.state == .encryptedDataReset ? 330 : 230,
               alignment: .topLeading)
        .alert("Delete Synced Content?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Synced Content", role: .destructive) {
                Task { await model.deleteSyncedContent() }
            }
        } message: {
            Text("This starts a fresh empty synced collection and removes the old synced snips and attachments from iCloud. This device keeps a local recovery copy. A small control record remains in iCloud to stop old devices from restoring deleted content.")
        }
        .alert("Use This Mac’s Copy?", isPresented: $confirmsUsingDeviceCopy) {
            Button("Cancel", role: .cancel) {}
            Button("Use Mac Copy") {
                Task { await model.disableICloudSync(.useCurrentCache) }
            }
        } message: {
            Text("Snip Snap could not refresh iCloud. You can keep sync on and try again, or turn it off with the copy already on this Mac. That copy may not include recent changes from other devices. Your iCloud data will not be deleted.")
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

    private var encryptedDataResetChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Restore from This Device") {
                Task { await model.resolveEncryptedDataReset(.restoreFromThisDevice) }
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
    }

    private var statusImage: String {
        switch model.mode {
        case .localOnly: "internaldrive"
        case .iCloudSync: "icloud"
        }
    }
}
