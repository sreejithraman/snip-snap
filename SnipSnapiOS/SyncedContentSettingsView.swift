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
    @State private var diagnosticsShareRequest: IOSShareRequest?
    @State private var diagnosticsMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Toggle(isOn: $haptics.isEnabled) {
                        settingsLabel("Haptics", systemImage: "waveform") {
                            Text("Feel feedback when you use Snip Snap.")
                        }
                    }
                    .accessibilityIdentifier("haptics-toggle")
                }

                Section("iCloud") {
                    Toggle(isOn: syncEnabled) {
                        settingsLabel("Sync with iCloud", systemImage: "icloud")
                    }
                    .disabled(!canChangeSync)
                    .accessibilityIdentifier("icloud-sync-toggle")
                    syncStatus
                    if let clipboard {
                        Toggle(isOn: Binding(
                            get: { clipboard.syncEnabled },
                            set: { enabled in
                                if enabled { confirmsClipboardSync = true }
                                else { Task { await clipboard.setSyncEnabled(false) } }
                            }
                        )) {
                            settingsLabel("Sync clipboard history", systemImage: "doc.on.clipboard") {
                                Text("Turning this off doesn’t delete your history.")
                            }
                        }
                        .disabled(model.mode != .iCloudSync)
                        .accessibilityIdentifier("clipboard-sync-toggle")
                    }
                    if let message = clipboard?.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.canRetryFailedSync, let retryAction {
                        Button {
                            Task { await retryAction() }
                        } label: {
                            settingsLabel("Retry sync", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier("retry-icloud-sync")
                    }
                }

                if model.canDelete {
                    Section {
                        Button(role: .destructive) {
                            confirmsDelete = true
                        } label: {
                            Label("Delete synced content…", systemImage: "trash")
                        }
                        .accessibilityIdentifier("delete-synced-content")
                    } header: {
                        Text("iCloud Data")
                    } footer: {
                        Text("Remove synced content from iCloud and your synced devices.")
                    }
                }

                Section("Support") {
                    Button {
                        shareDiagnostics()
                    } label: {
                        settingsLabel("Share diagnostic log", systemImage: "square.and.arrow.up") {
                            Text("Includes only recent sync stages and error codes—not your content or file names.")
                        }
                    }
                    .accessibilityIdentifier("share-diagnostic-log")

                    Button {
                        clearDiagnostics()
                    } label: {
                        settingsLabel("Clear diagnostic log", systemImage: "trash")
                    }
                    .accessibilityIdentifier("clear-diagnostic-log")
                }

                Section("About") {
                    Link(destination: URL(string: "https://sree.world/snip-snap/privacy")!) {
                        HStack {
                            settingsLabel("Privacy policy", systemImage: "hand.raised")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("privacy-policy")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .background {
            IOSShareSheetPresenter(request: $diagnosticsShareRequest)
                .frame(width: 0, height: 0)
        }
        .alert("Diagnostics", isPresented: Binding(
            get: { diagnosticsMessage != nil },
            set: { if !$0 { diagnosticsMessage = nil } }
        )) {
            Button("OK") { diagnosticsMessage = nil }
        } message: {
            Text(diagnosticsMessage ?? "")
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
                        clipboard?.presentError(
                            error,
                            operation: "clipboard.delete_synced",
                            message: ClipboardSyncErrorMessage.deleteSyncedHistory(for: error)
                        )
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

    private var syncStatus: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if isSyncBusy {
                    ProgressView()
                } else {
                    Image(systemName: statusImage)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)
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

    private func settingsLabel(
        _ title: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        settingsLabel(title, systemImage: systemImage) { EmptyView() }
    }

    private func settingsLabel<Detail: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                detail()
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    private func shareDiagnostics() {
        do {
            let url = try CloudSyncDiagnosticsExport.makeShareableFile()
            diagnosticsShareRequest = IOSShareRequest(items: [.file(url)])
        } catch {
            AppDiagnostics.shared.record(.failure(
                operation: "diagnostics.export",
                error: error,
                visibility: .user
            ))
            diagnosticsMessage = String(localized: "Couldn’t prepare the diagnostic log. Try again.")
        }
    }

    private func clearDiagnostics() {
        do {
            try CloudSyncDiagnosticsExport.clear()
            diagnosticsMessage = String(localized: "Diagnostic log cleared.")
        } catch {
            AppDiagnostics.shared.record(.failure(
                operation: "diagnostics.clear",
                error: error,
                visibility: .user
            ))
            diagnosticsMessage = String(localized: "Couldn’t clear the diagnostic log. Try again.")
        }
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
