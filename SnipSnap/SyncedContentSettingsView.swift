import SnipSnapCore
import SwiftUI

struct SyncedContentSettingsView: View {
    @Bindable var model: SyncedContentSettingsModel
    @State private var confirmsDelete = false
    @State private var confirmsUsingDeviceCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(.syncWithICloud, isOn: syncEnabled)
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
                ProgressView(.progressSettingUpICloud)
                    .controlSize(.small)
            } else if case .disabling = model.state {
                ProgressView(.makingALocalCopy)
                    .controlSize(.small)
            } else if case .deleting = model.state {
                ProgressView(.progressDeletingSyncedContent)
                    .controlSize(.small)
            } else if case .resolvingEncryptedDataReset = model.state {
                ProgressView(.progressStartingNewCollection)
                    .controlSize(.small)
            } else if case .encryptedDataReset = model.state {
                encryptedDataResetChoices
            } else if model.canDelete {
                Button(.actionOpenDeleteSyncedContent, role: .destructive) {
                    confirmsDelete = true
                }
                .accessibilityIdentifier("delete-synced-content")
            }
        }
        .padding(20)
        .frame(width: 420, height: model.state == .encryptedDataReset ? 330 : 230,
               alignment: .topLeading)
        .alert(.dialogDeleteSyncedContentTitle, isPresented: $confirmsDelete) {
            Button(.cancel, role: .cancel) {}
            Button(.actionDeleteSyncedContent, role: .destructive) {
                Task { await model.deleteSyncedContent() }
            }
        } message: {
            Text(.thisStartsAFreshEmptySyncedCollectionAndRemovesTheOldSyncedSnipsAndAttachmentsFromICloudThisDeviceKeepsALocalRecoveryCopyASmallControlRecordRemainsInICloudToStopOldDevicesFromRestoringDeletedContent)
        }
        .alert(.useThisMacsCopy, isPresented: $confirmsUsingDeviceCopy) {
            Button(.cancel, role: .cancel) {}
            Button(.useMacCopy) {
                Task { await model.disableICloudSync(.useCurrentCache) }
            }
        } message: {
            Text(.snipSnapCouldNotRefreshICloudYouCanKeepSyncOnAndTryAgainOrTurnItOffWithTheCopyAlreadyOnThisMacThatCopyMayNotIncludeRecentChangesFromOtherDevicesYourICloudDataWillNotBeDeleted)
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
            Button(.restoreFromThisDevice) {
                Task { await model.resolveEncryptedDataReset(.restoreFromThisDevice) }
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
    }

    private var statusImage: String {
        switch model.mode {
        case .localOnly: "internaldrive"
        case .iCloudSync: "icloud"
        }
    }
}
