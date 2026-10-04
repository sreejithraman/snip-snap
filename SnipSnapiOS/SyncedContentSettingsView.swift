import SnipSnapCloud
import SnipSnapCore
import SnipSnapPersistence
import Observation
import UniformTypeIdentifiers
import UIKit
import SwiftUI

struct SyncedContentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var settingsIconWidth: CGFloat = 24
    @Bindable var model: SyncedContentSettingsModel
    var clipboard: IOSClipboardModel?
    @Bindable var haptics: IOSHapticFeedback
    var library: IOSAppModel?
    var backupLifetime: IOSSettingsBackupLifetime
    var retryAction: (@MainActor @Sendable () async -> Void)?
    @State private var confirmsClipboardSync = false
    @State private var confirmsUsingDeviceCopy = false
    @State private var isRetryingSync = false
    @State private var isRetryingClipboardSync = false
    @State private var diagnosticsShareRequest: IOSShareRequest?
    @State private var diagnosticsMessage: String?
    @State private var isImportingBackup = false
    @State private var isPreparingBackup = false
    @State private var isProcessingImport = false
    @State private var isConfirmingImport = false
    @State private var backupExport: IOSBackupExport?
    @State private var backupError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Toggle(isOn: $haptics.isEnabled) {
                        settingsLabel("Haptics", systemImage: "waveform")
                    }
                    .accessibilityIdentifier("haptics-toggle")
                }

                Section("iCloud") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: syncEnabled) {
                            settingsLabel("Sync with iCloud", systemImage: "icloud")
                        }
                        .disabled(!canChangeSync || isRetryingSync || isRetryingClipboardSync)
                        .accessibilityIdentifier("icloud-sync-toggle")
                        syncMessage
                            .padding(.leading, settingsIconWidth + 12)
                    }
                    if model.canRetryFailedSync, let retryAction {
                        Button {
                            guard !isRetryingSync, !isRetryingClipboardSync else { return }
                            isRetryingSync = true
                            Task {
                                await retryAction()
                                isRetryingSync = false
                            }
                        } label: {
                            retryLabel(isBusy: isRetryingSync)
                        }
                        .disabled(isRetryingSync || isRetryingClipboardSync || isSyncBusy)
                        .accessibilityIdentifier("retry-icloud-sync")
                    }
                    if let clipboard {
                        Toggle(isOn: Binding(
                            get: { model.canEnableClipboardSync && clipboard.syncEnabled },
                            set: { enabled in
                                if enabled {
                                    guard model.canEnableClipboardSync else { return }
                                    confirmsClipboardSync = true
                                }
                                else { Task { await clipboard.setSyncEnabled(false) } }
                            }
                        )) {
                            settingsLabel("Sync clipboard history", systemImage: "doc.on.clipboard")
                        }
                        .disabled(!model.canEnableClipboardSync)
                        .accessibilityIdentifier("clipboard-sync-toggle")
                    }
                    if let clipboard, let message = clipboard.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if clipboard.syncIsActive {
                            Button {
                                guard !isRetryingClipboardSync, !isRetryingSync, !clipboard.isSyncing else { return }
                                isRetryingClipboardSync = true
                                Task {
                                    await clipboard.synchronize()
                                    isRetryingClipboardSync = false
                                }
                            } label: {
                                retryLabel(isBusy: isRetryingClipboardSync)
                            }
                            .disabled(isRetryingClipboardSync || isRetryingSync || isSyncBusy || clipboard.isSyncing)
                            .accessibilityIdentifier("retry-clipboard-sync")
                        }
                    }
                }

                if let library {
                    Section("Backups") {
                        Button(action: createBackup) {
                            HStack {
                                settingsLabel("Create Backup…", systemImage: "square.and.arrow.up")
                                if isPreparingBackup {
                                    Spacer()
                                    ProgressView()
                                        .accessibilityLabel("Preparing backup")
                                }
                            }
                        }
                        .disabled(isBackupBusy)
                        .accessibilityIdentifier("create-backup")
                        Button {
                            guard !isBackupBusy else { return }
                            library.haptics.invalidatePendingFeedback()
                            isImportingBackup = true
                        } label: {
                            settingsLabel("Import Backup…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(isBackupBusy)
                        .accessibilityIdentifier("import-backup")
                    }
                }

                Section("Support") {
                    NavigationLink {
                        diagnosticsView
                    } label: {
                        settingsLabel("Diagnostics", systemImage: "stethoscope")
                    }
                    .accessibilityIdentifier("diagnostics")
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
        .sheet(item: $backupExport, onDismiss: clearExportedBackup) { export in
            IOSBackupExportPicker(url: export.url)
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.folder, .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                previewBackupImport(from: url)
            case .failure(let error):
                if backupLifetime.isActive, (error as NSError).code != NSUserCancelledError {
                    backupError = error.localizedDescription
                }
            }
        }
        .confirmationDialog(
            "Import this backup?",
            isPresented: Binding(
                get: { library?.pendingImportPreview != nil },
                set: { if !$0, !isConfirmingImport { library?.cancelBackupImport() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Import backup", action: confirmBackupImport)
            Button("Cancel", role: .cancel) { library?.cancelBackupImport() }
        } message: {
            Text("Merge this backup with your library.\n\n\(library?.pendingImportPreview?.localizedSummary ?? "")")
        }
        .alert("Couldn’t Complete Backup", isPresented: Binding(
            get: { backupError != nil },
            set: { if !$0 { backupError = nil } }
        )) {
            Button("OK") { backupError = nil }
        } message: {
            Text(backupError ?? "")
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
        .onChange(of: model.canEnableClipboardSync) { _, canEnable in
            if !canEnable { confirmsClipboardSync = false }
        }
        .alert("Sync clipboard history?", isPresented: $confirmsClipboardSync) {
            Button("Cancel", role: .cancel) {}
            Button("Sync clipboard history") {
                Task {
                    guard model.canEnableClipboardSync else { return }
                    await clipboard?.setSyncEnabled(true)
                }
            }
        } message: {
            Text("Sync text, images, and pinned files across your devices. Files that have synced keep syncing after you unpin them.")
        }
        .onAppear(perform: showUITestIssueIfNeeded)
        .alert("Turn off sync?", isPresented: $confirmsUsingDeviceCopy) {
            Button("Cancel", role: .cancel) {}
            Button("Turn off sync") {
                Task { await model.disableICloudSync(.useCurrentCache) }
            }
        } message: {
            Text("Couldn’t get the latest iCloud changes. Turning off sync uses this device’s copy, which may be out of date. Your iCloud data stays.")
        }
    }

    @ViewBuilder
    private var syncMessage: some View {
        if showsSyncMessage {
            HStack(alignment: .top, spacing: 6) {
                if isSyncBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusTitle)
                        .accessibilityIdentifier("sync-status")
                    if showsSyncDetail {
                        Text(model.detail)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func retryLabel(isBusy: Bool) -> some View {
        HStack {
            settingsLabel("Try Again", systemImage: "arrow.clockwise")
            if isBusy {
                Spacer()
                ProgressView()
            }
        }
    }

    private func settingsLabel(
        _ title: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: settingsIconWidth)
                .accessibilityHidden(true)
            Text(title)
        }
    }

    init(
        model: SyncedContentSettingsModel,
        clipboard: IOSClipboardModel? = nil,
        haptics: IOSHapticFeedback,
        library: IOSAppModel? = nil,
        backupLifetime: IOSSettingsBackupLifetime,
        retryAction: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        self.model = model
        self.haptics = haptics
        self.library = library
        self.backupLifetime = backupLifetime
        self.clipboard = clipboard
        self.retryAction = retryAction
    }

    private var showsSyncDetail: Bool {
        if case .enabling(let issue) = model.state { return issue != nil }
        return !isSyncBusy
    }

    private var showsSyncMessage: Bool {
        switch model.state {
        case .ready, .deleted: false
        case .enabling, .syncing, .disabling, .deleting, .removalPending, .failed: true
        }
    }

    private var diagnosticsView: some View {
        Form {
            Section {
                Button(action: shareDiagnostics) {
                    settingsLabel("Share diagnostic log", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("share-diagnostic-log")
                Button(action: clearDiagnostics) {
                    settingsLabel("Clear diagnostic log", systemImage: "trash")
                }
                .accessibilityIdentifier("clear-diagnostic-log")
            } footer: {
                Text("Includes only recent sync stages and error codes—not your content or file names.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func createBackup() {
        guard let library, !isBackupBusy, backupLifetime.isActive else { return }
        isPreparingBackup = true
        let operationID = backupLifetime.beginOperation()
        backupLifetime.task = Task {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SnipSnapBackup-\(UUID().uuidString)", isDirectory: true)
            backupLifetime.exportRoot = root
            do {
                let url = root.appendingPathComponent(String(localized: "Snip Snap Backup"), isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try await library.createBackup(at: url)
                try Task.checkCancellation()
                guard backupLifetime.isActive else { throw CancellationError() }
                backupExport = IOSBackupExport(url: url)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: root)
            } catch {
                try? FileManager.default.removeItem(at: root)
                AppDiagnosticRecorder.live.record(.failure(
                    operation: "backup.export", error: error, visibility: .user
                ))
                if backupLifetime.isActive, !Task.isCancelled { backupError = error.localizedDescription }
            }
            isPreparingBackup = false
            backupLifetime.finishOperation(operationID)
        }
    }

    private var isBackupBusy: Bool {
        isPreparingBackup || isProcessingImport || isConfirmingImport || isImportingBackup
            || library?.pendingImportPreview != nil || backupExport != nil
    }

    private func clearExportedBackup() {
        backupLifetime.clearExportedBackup()
        backupExport = nil
    }

    private func previewBackupImport(from url: URL) {
        guard let library, backupLifetime.isActive, !isProcessingImport, !isPreparingBackup else { return }
        isProcessingImport = true
        let operationID = backupLifetime.beginOperation()
        backupLifetime.task = Task {
            defer {
                isProcessingImport = false
                backupLifetime.finishOperation(operationID)
            }
            do {
                try await library.previewBackupImport(from: url)
                guard backupLifetime.isActive, !Task.isCancelled else {
                    library.cancelBackupImport()
                    return
                }
            } catch is CancellationError {
                // Closing Settings or choosing another backup abandons this preview.
            } catch {
                if backupLifetime.isActive, !Task.isCancelled { backupError = error.localizedDescription }
            }
        }
    }

    private func confirmBackupImport() {
        guard let library, backupLifetime.isActive, !isProcessingImport, !isConfirmingImport else { return }
        isConfirmingImport = true
        let operationID = backupLifetime.beginOperation()
        backupLifetime.task = Task {
            defer {
                isConfirmingImport = false
                backupLifetime.finishOperation(operationID)
            }
            do {
                try await library.confirmBackupImport()
            } catch is CancellationError {
                // The dismissal cancelled an import that had not started committing.
            } catch {
                if backupLifetime.isActive, !Task.isCancelled { backupError = error.localizedDescription }
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
            let url = try AppDiagnosticsExport.makeShareableFile()
            diagnosticsShareRequest = IOSShareRequest(items: [.file(url)])
        } catch {
            AppDiagnosticRecorder.live.record(.failure(
                operation: "diagnostics.export",
                error: error,
                visibility: .user
            ))
            diagnosticsMessage = String(localized: "Couldn’t prepare the diagnostic log. Try again.")
        }
    }

    private func clearDiagnostics() {
        do {
            try AppDiagnosticsExport.clear()
            diagnosticsMessage = String(localized: "Diagnostic log cleared.")
        } catch {
            AppDiagnosticRecorder.live.record(.failure(
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

    private var isSyncBusy: Bool {
        switch model.state {
        case .enabling, .syncing, .disabling, .deleting: true
        case .ready, .removalPending, .deleted, .failed: false
        }
    }
}

private struct IOSBackupExport: Identifiable {
    let id = UUID()
    let url: URL
}

private struct IOSBackupExportPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) { self.dismiss = dismiss }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            dismiss()
        }
    }
}

@MainActor
@Observable
final class IOSSettingsBackupLifetime {
    private(set) var isActive = false
    var task: Task<Void, Never>?
    var exportRoot: URL?
    private var operationID: UUID?

    func begin() { isActive = true }

    func end(library: IOSAppModel) {
        isActive = false
        task?.cancel()
        task = nil
        operationID = nil
        library.cancelBackupImport()
        clearExportedBackup()
    }

    func beginOperation() -> UUID {
        let id = UUID()
        operationID = id
        return id
    }

    func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        task = nil
    }

    func clearExportedBackup() {
        guard let root = exportRoot else { return }
        try? FileManager.default.removeItem(at: root)
        exportRoot = nil
    }
}
