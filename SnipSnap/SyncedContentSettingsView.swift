import SnipSnapCore
import SwiftUI

struct SyncedContentSettingsView: View {
    @Bindable var model: SyncedContentSettingsModel
    var retryAction: (@MainActor @Sendable () async -> Void)?
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
        .frame(width: 420, height: 230, alignment: .topLeading)
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
