import SnipSnapCore
import SwiftUI

struct SyncedContentSettingsView: View {
    @Bindable var model: SyncedContentSettingsModel
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            } else if case .deleting = model.state {
                ProgressView("Deleting synced content…")
                    .controlSize(.small)
            } else if case .resolvingEncryptedDataReset = model.state {
                ProgressView("Starting a new synced collection…")
                    .controlSize(.small)
            } else if case .encryptedDataReset = model.state {
                encryptedDataResetChoices
            } else if model.canEnable {
                Button("Enable iCloud Sync…") {
                    Task { await model.enableICloudSync() }
                }
                .accessibilityIdentifier("enable-icloud-sync")
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
