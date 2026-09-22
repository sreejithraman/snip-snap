import SnipSnapCloud
import SnipSnapCore
import SwiftUI

struct AttachmentSettingsActions {
    let syncNow: @MainActor @Sendable () async -> Void
    let clearDownloads: @MainActor @Sendable () async throws -> Void
}

struct SyncedContentSettingsView: View {
    @Bindable var model: SyncedContentSettingsModel
    @ObservedObject var clipboard: ClipboardHistory
    @State private var confirmsClipboardSync = false
    @State private var clipboardDeleteError: String?
    var retryAction: (@MainActor @Sendable () async -> Void)?
    var attachmentActions: AttachmentSettingsActions?
    @State private var confirmsDelete = false
    @State private var confirmsUsingDeviceCopy = false
    @State private var isClearingDownloads = false
    @State private var isSyncing = false
    @State private var clearDownloadsError: String?

    var body: some View {
        Form {
            Section("iCloud") {
                Toggle("Sync with iCloud", isOn: syncEnabled)
                    .disabled(!canChangeSync)
                    .accessibilityIdentifier("icloud-sync-toggle")

                syncStatus

                Toggle(isOn: Binding(
                    get: { clipboard.clipboardSyncEnabled },
                    set: { enabled in
                        if enabled { confirmsClipboardSync = true }
                        else { clipboard.setSyncEnabled(false) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sync clipboard history")
                        Text("Turning this off doesn’t delete your history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.mode != .iCloudSync)
                .accessibilityIdentifier("clipboard-sync-toggle")

                if let error = clipboard.syncError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Retry clipboard sync") { Task { await clipboard.syncNow() } }
                }
                if model.canRetryFailedSync, let retryAction {
                    Button("Retry sync") { Task { await retryAction() } }
                        .accessibilityIdentifier("retry-icloud-sync")
                }
            }

            attachmentControls

            if model.canDelete {
                Section {
                    Button("Delete synced content…", role: .destructive) {
                        confirmsDelete = true
                    }
                    .accessibilityIdentifier("delete-synced-content")
                } header: {
                    Text("iCloud Data")
                } footer: {
                    Text("Remove synced content from iCloud and your synced devices.")
                }
            }
        }
        .formStyle(.grouped)
        .alert("Delete synced content?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete synced content", role: .destructive) {
                Task {
                    do {
                        try await clipboard.deleteSyncedHistory()
                        await model.deleteSyncedContent()
                    } catch {
                        AppDiagnostics.shared.record(.failure(
                            operation: "clipboard.delete_synced",
                            error: error,
                            visibility: .user
                        ))
                        clipboardDeleteError = ClipboardSyncErrorMessage.deleteSyncedHistory(for: error)
                    }
                }
            }
        } message: {
            Text("Deletes synced snips, attachments, and clipboard history, including pins, from iCloud and your synced devices. This Mac keeps a recovery copy.")
        }
        .alert("Sync clipboard history?", isPresented: $confirmsClipboardSync) {
            Button("Cancel", role: .cancel) {}
            Button("Sync clipboard history") { clipboard.setSyncEnabled(true) }
        } message: {
            Text("Sync text, images, and pinned files across your devices. Files that have synced keep syncing after you unpin them.")
        }
        .alert("Couldn’t delete synced content", isPresented: Binding(get: { clipboardDeleteError != nil }, set: { if !$0 { clipboardDeleteError = nil } })) {
            Button("OK") { clipboardDeleteError = nil }
        } message: { Text(clipboardDeleteError ?? "") }
        .alert("Turn off sync?", isPresented: $confirmsUsingDeviceCopy) {
            Button("Cancel", role: .cancel) {}
            Button("Turn off sync") {
                Task { await model.disableICloudSync(.useCurrentCache) }
            }
        } message: {
            Text("Couldn’t get the latest iCloud changes. Turning off sync uses this Mac’s copy, which may be out of date. Your iCloud data stays.")
        }
    }

    init(
        model: SyncedContentSettingsModel,
        clipboard: ClipboardHistory,
        retryAction: (@MainActor @Sendable () async -> Void)? = nil,
        attachmentActions: AttachmentSettingsActions? = nil
    ) {
        self.model = model
        self.clipboard = clipboard
        self.retryAction = retryAction
        self.attachmentActions = attachmentActions
    }

    private var syncStatus: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if isSyncBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: statusImage)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.statusTitle)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("sync-status")
                Text(model.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var attachmentControls: some View {
        if let attachmentActions {
            Section {
                LabeledContent("iCloud Attachments") {
                    Button(isSyncing ? "Syncing…" : "Sync Now") {
                        isSyncing = true
                        Task {
                            await attachmentActions.syncNow()
                            isSyncing = false
                        }
                    }
                    .disabled(isSyncing)
                    .accessibilityIdentifier("sync-icloud-now")
                }
                LabeledContent("Downloaded files") {
                    Button(isClearingDownloads ? "Clearing…" : "Clear Downloads") {
                        isClearingDownloads = true
                        clearDownloadsError = nil
                        Task {
                            do {
                                try await attachmentActions.clearDownloads()
                            } catch {
                                AppDiagnostics.shared.record(.failure(
                                    operation: "attachment.cache_clear",
                                    error: error,
                                    visibility: .user
                                ))
                                clearDownloadsError = String(localized: "Couldn’t clear downloaded files. Try again.")
                            }
                            isClearingDownloads = false
                        }
                    }
                    .disabled(isClearingDownloads)
                    .accessibilityIdentifier("clear-icloud-downloads")
                }
                if let clearDownloadsError {
                    Label(clearDownloadsError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Downloaded files can be fetched again when you open them.")
            }
        }
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
                        clipboard.stopSync()
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
        switch model.state {
        case .failed, .removalPending: return "exclamationmark.triangle"
        default: break
        }
        switch model.mode {
        case .localOnly: return "internaldrive"
        case .iCloudSync: return "icloud"
        }
    }

    private var isSyncBusy: Bool {
        switch model.state {
        case .enabling, .syncing, .disabling, .deleting: true
        case .ready, .removalPending, .deleted, .failed: false
        }
    }
}
