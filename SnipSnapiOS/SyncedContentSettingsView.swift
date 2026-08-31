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
                Section(.sync) {
                    HStack {
                        Text(.syncWithICloud)
                        Spacer()
                        Toggle(.syncWithICloud, isOn: syncEnabled)
                            .labelsHidden()
                            .disabled(!canChangeSync)
                            .accessibilityIdentifier("icloud-sync-toggle")
                            .accessibilityLabel(.syncWithICloud)
                    }
                    Label(model.statusTitle, systemImage: statusImage)
                        .accessibilityIdentifier("sync-status")
                    Text(model.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if case .enabling = model.state {
                    Section {
                        ProgressView(.progressSettingUpICloud)
                    }
                } else if case .disabling = model.state {
                    Section {
                        ProgressView(.makingALocalCopy)
                    }
                } else if case .deleting = model.state {
                    Section {
                        ProgressView(.progressDeletingSyncedContent)
                    }
                } else if case .resolvingEncryptedDataReset = model.state {
                    Section {
                        ProgressView(.progressStartingNewCollection)
                    }
                } else if case .encryptedDataReset = model.state {
                    Section(.chooseWhatToDo) {
                        Button(.restoreFromThisDevice) {
                            Task {
                                await model.resolveEncryptedDataReset(.restoreFromThisDevice)
                            }
                        }
                        .accessibilityIdentifier("encrypted-reset-restore")

                        Button(.startEmpty) {
                            Task { await model.resolveEncryptedDataReset(.startEmpty) }
                        }
                        .accessibilityIdentifier("encrypted-reset-start-empty")

                        Button(.keepSyncOff) {
                            Task { await model.resolveEncryptedDataReset(.keepSyncOff) }
                        }
                        .accessibilityIdentifier("encrypted-reset-keep-off")
                    }
                } else if model.canDelete {
                    Section {
                        Button(.actionOpenDeleteSyncedContent, role: .destructive) {
                            confirmsDelete = true
                        }
                        .accessibilityIdentifier("delete-synced-content")
                    }
                }
            }
            .navigationTitle(.settings)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.done) { dismiss() }
                }
            }
        }
        .alert(.dialogDeleteSyncedContentTitle, isPresented: $confirmsDelete) {
            Button(.cancel, role: .cancel) {}
            Button(.actionDeleteSyncedContent, role: .destructive) {
                Task { await model.deleteSyncedContent() }
            }
        } message: {
            Text(.thisStartsAFreshEmptySyncedCollectionAndRemovesTheOldSyncedSnipsAndAttachmentsFromICloudThisDeviceKeepsALocalRecoveryCopyASmallControlRecordRemainsInICloudToStopOldDevicesFromRestoringDeletedContent)
        }
        .alert(.useThisDevicesCopy, isPresented: $confirmsUsingDeviceCopy) {
            Button(.cancel, role: .cancel) {}
            Button(.useDeviceCopy) {
                Task { await model.disableICloudSync(.useCurrentCache) }
            }
        } message: {
            Text(.snipSnapCouldNotRefreshICloudYouCanKeepSyncOnAndTryAgainOrTurnItOffWithTheCopyAlreadyOnThisDeviceThatCopyMayNotIncludeRecentChangesFromOtherDevicesYourICloudDataWillNotBeDeleted)
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
