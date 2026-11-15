import SnipSnapCloud
import SnipSnapCore
import SnipSnapPersistence
import Observation
import UniformTypeIdentifiers
import UIKit
import SwiftUI

struct SyncedContentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
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
    @Bindable var diagnostics: AppDiagnosticSettingsModel
    @State private var diagnosticDelivery = IOSDiagnosticShareDelivery()
    private var backupError: String? { backupFailure?.message }
    @State private var backupFailure: AppFailure?
    @State private var settingsErrorDetails: AppFailure?
    @State private var settingsToast: AppToast?

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
                    if model.canRetryFailedSync || model.canFinishDeleting, let retryAction {
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
                    if let clipboard, let message = clipboard.persistentErrorMessage {
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
                                if backupLifetime.isPreparingBackup {
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
                                                backupFailure = nil
                            backupLifetime.chooseBackup()
                        } label: {
                            settingsLabel("Import Backup…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(isBackupBusy)
                        .accessibilityIdentifier("import-backup")
                        if let backupError {
                            Label(backupError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let backupFailure {
                                Button("Details") {
                                    showSettingsErrorDetails(backupFailure)
                                }
                            }
                        }
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
        .sheet(item: sharedBackup, onDismiss: { backupLifetime.finishSharingBackup() }) { export in
            IOSBackupExportPicker(url: export.url)
        }
        .fileImporter(
            isPresented: Binding(
                get: { backupLifetime.isChoosingBackup },
                set: { if !$0 { backupLifetime.finishChoosingBackup() } }
            ),
            allowedContentTypes: [.folder, .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                previewBackupImport(from: url)
            case .failure(let error):
                if backupLifetime.isActive {
                    if library?.backupImportSelectionFailed(error) != nil {
                        backupFailure = AppFailure(error: error, operation: "backup.import_select")
                    }
                }
            }
        }
        .confirmationDialog(
            "Import this backup?",
            isPresented: Binding(
                get: { library?.pendingImportPreview != nil },
                set: { if !$0, !backupLifetime.isConfirmingImport { library?.cancelBackupImport() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Import backup", action: confirmBackupImport)
            Button("Cancel", role: .cancel) { library?.cancelBackupImport() }
        } message: {
            Text("Merge this backup with your library.\n\n\(library?.pendingImportPreview?.localizedSummary ?? "")")
        }
        .background {
            IOSShareSheetPresenter(
                request: $diagnosticDelivery.request,
                diagnosticOperation: "diagnostics.export"
            )
                .frame(width: 0, height: 0)
        }
        .onDisappear { diagnostics.deactivate() }
        .sheet(item: $settingsErrorDetails) { failure in
            AppErrorDetailsView(failure: failure, onClose: { settingsErrorDetails = nil })
        }
        .appToast($settingsToast, alignment: .bottom, edge: .bottom,
                  isHidden: library != nil, reservesSpace: true)
        .onChange(of: diagnostics.notice) { _, notice in
            switch notice {
            case .saved:
                presentSettingsToast(AppToast(systemImage: "square.and.arrow.down", message: String(localized: "Diagnostic log saved.")))
                diagnostics.dismissNotice()
            case .cleared:
                presentSettingsToast(AppToast(systemImage: "trash", message: String(localized: "Diagnostic log cleared.")))
                diagnostics.dismissNotice()
            default:
                break
            }
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
            Text("Sync text, images, and pinned files across your devices. Clipboard history already on this device will upload to iCloud. Files that have synced keep syncing after you unpin them.")
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
        diagnostics: AppDiagnosticSettingsModel,
        retryAction: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        self.diagnostics = diagnostics
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

    private func showSettingsErrorDetails(_ failure: AppFailure) {
        if let library { library.showErrorDetails(failure) }
        else { settingsErrorDetails = failure }
    }

    private func presentSettingsToast(_ toast: AppToast) {
        if let library { library.presentToast(toast) }
        else { settingsToast = toast }
    }

    private var diagnosticMessage: String {
        switch diagnostics.notice {
        case .readFailed: String(localized: "Couldn’t read the diagnostics setting. Try again.")
        case .saveFailed: String(localized: "Couldn’t save the diagnostics setting. Try again.")
        case .preparationFailed: String(localized: "Couldn’t prepare the diagnostic log. Try again.")
        case .deliveryFailed: String(localized: "Couldn’t share the diagnostic log. Try again.")
        case .clearFailed: String(localized: "Couldn’t clear the diagnostic log. Try again.")
        case .saved: String(localized: "Diagnostic log saved. You can attach it to your support message.")
        case .cleared: String(localized: "Diagnostic log cleared.")
        case nil: ""
        }
    }

    private var diagnosticsView: some View {
        Form {
            Section {
                if let enabled = diagnostics.recordingEnabled {
                    Toggle(isOn: Binding(
                        get: { diagnostics.recordingEnabled ?? enabled },
                        set: { diagnostics.setRecordingEnabled($0) }
                    )) {
                        settingsLabel("Record local diagnostics", systemImage: "waveform.path")
                    }
                    .disabled(!diagnostics.canPerformActions)
                    .accessibilityIdentifier("diagnostics-recording-toggle")
                } else {
                    LabeledContent {
                        Text("Unavailable")
                    } label: {
                        settingsLabel("Record local diagnostics", systemImage: "waveform.path")
                    }
                    .accessibilityIdentifier("diagnostics-recording-status")
                    Button("Try Again") { diagnostics.refreshRecording() }
                        .disabled(diagnostics.isBusy)
                }
                Picker("Diagnostic log range", selection: $diagnostics.range) {
                    Text("Last 24 hours").tag(AppDiagnosticExportRange.last24Hours)
                    Text("Last 7 days").tag(AppDiagnosticExportRange.last7Days)
                }
                .accessibilityIdentifier("diagnostic-log-range")
                .disabled(!diagnostics.canPerformActions)
                Button {
                    diagnostics.share(deliver: diagnosticDelivery.deliver)
                } label: {
                    settingsLabel("Share diagnostic log", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("share-diagnostic-log")
                .disabled(!diagnostics.canPerformActions)
                Button(action: diagnostics.clear) {
                    settingsLabel("Clear diagnostic log", systemImage: "trash")
                }
                .accessibilityIdentifier("clear-diagnostic-log")
                .disabled(!diagnostics.canPerformActions)
                if diagnostics.isBusy {
                    ProgressView()
                        .accessibilityLabel("Updating diagnostics")
                }
                if let notice = diagnostics.notice, notice != .saved, notice != .cleared {
                    Label(diagnosticMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Details") {
                        if let failure = diagnostics.failure {
                            showSettingsErrorDetails(AppFailure(message: diagnosticMessage,
                                operation: failure.operation, diagnosticCode: failure.code))
                        }
                    }
                    .disabled(diagnostics.failure == nil)
                }
            } footer: {
                Text("Diagnostics stay on this device for up to 7 days; storage limits may shorten history. They exclude snip content and file names. Nothing is uploaded automatically. Turning recording off keeps retained logs; clear them separately. The system may keep separate logs.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { diagnostics.activate() }
        .onDisappear { diagnostics.deactivate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { diagnostics.refreshRecording() }
        }
    }

    private func createBackup() {
        guard let library, !isBackupBusy, backupLifetime.isActive else { return }
        backupFailure = nil
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapBackup-\(UUID().uuidString)", isDirectory: true)
        backupLifetime.startPreparingBackup(root: root) { operation in
            do {
                let url = root.appendingPathComponent(String(localized: "Snip Snap Backup"), isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try await library.createBackup(at: url)
                try Task.checkCancellation()
                guard backupLifetime.shareBackup(IOSBackupExport(url: url), operation: operation) else {
                    throw CancellationError()
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: root)
            } catch {
                try? FileManager.default.removeItem(at: root)
                AppDiagnosticRecorder.live.record(.failure(
                    operation: "backup.export", error: error, visibility: .user
                ))
                if backupLifetime.isActive, !Task.isCancelled {
                    backupFailure = AppFailure(error: error, operation: "backup.export")
                }
            }
        }
    }

    private var isBackupBusy: Bool {
        backupLifetime.isBusy || library?.pendingImportPreview != nil
    }

    private var sharedBackup: Binding<IOSBackupExport?> {
        Binding(
            get: { backupLifetime.sharedBackup },
            set: { if $0 == nil { backupLifetime.finishSharingBackup() } }
        )
    }

    private func previewBackupImport(from url: URL) {
        guard let library else { return }
        backupLifetime.startPreviewingImport { _ in
            do {
                try await library.previewBackupImport(from: url)
                guard backupLifetime.isActive, !Task.isCancelled else {
                    library.cancelBackupImport()
                    return
                }
            } catch is CancellationError {
                // Closing Settings or choosing another backup abandons this preview.
            } catch {
                if backupLifetime.isActive, !Task.isCancelled {
                    backupFailure = AppFailure(error: error, operation: "backup.import_preview")
                }
            }
        }
    }

    private func confirmBackupImport() {
        guard let library else { return }
        backupLifetime.startConfirmingImport { _ in
            do {
                try await library.confirmBackupImport()
            } catch is CancellationError {
                // The dismissal cancelled an import that had not started committing.
            } catch {
                if backupLifetime.isActive, !Task.isCancelled {
                    backupFailure = AppFailure(error: error, operation: "backup.import_apply")
                }
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

struct IOSBackupExport: Identifiable {
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
    private struct Operation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum Phase {
        case inactive
        case idle
        case choosingBackup
        case preparingBackup(Operation, root: URL)
        case sharingBackup(IOSBackupExport, root: URL)
        case previewingImport(Operation)
        case confirmingImport(Operation)
    }

    typealias OperationBody = @MainActor @Sendable (_ operation: UUID) async -> Void

    private var phase = Phase.inactive

    var isActive: Bool {
        if case .inactive = phase { return false }
        return true
    }

    var isBusy: Bool {
        switch phase {
        case .inactive, .idle: false
        case .choosingBackup, .preparingBackup, .sharingBackup, .previewingImport, .confirmingImport: true
        }
    }

    var isChoosingBackup: Bool {
        if case .choosingBackup = phase { return true }
        return false
    }

    var isPreparingBackup: Bool {
        if case .preparingBackup = phase { return true }
        return false
    }

    var isConfirmingImport: Bool {
        if case .confirmingImport = phase { return true }
        return false
    }

    var sharedBackup: IOSBackupExport? {
        guard case .sharingBackup(let export, _) = phase else { return nil }
        return export
    }

    func begin() {
        guard case .inactive = phase else { return }
        phase = .idle
    }

    func end(library: IOSAppModel) {
        let ended = phase
        phase = .inactive
        switch ended {
        case .preparingBackup(let operation, let root):
            operation.task.cancel()
            try? FileManager.default.removeItem(at: root)
        case .sharingBackup(_, let root):
            try? FileManager.default.removeItem(at: root)
        case .previewingImport(let operation), .confirmingImport(let operation):
            operation.task.cancel()
        case .inactive, .idle, .choosingBackup:
            break
        }
        library.cancelBackupImport()
    }

    @discardableResult
    func chooseBackup() -> Bool {
        guard case .idle = phase else { return false }
        phase = .choosingBackup
        return true
    }

    func finishChoosingBackup() {
        guard case .choosingBackup = phase else { return }
        phase = .idle
    }

    @discardableResult
    func startPreparingBackup(root: URL, _ body: @escaping OperationBody) -> Bool {
        guard case .idle = phase else { return false }
        phase = .preparingBackup(start(body), root: root)
        return true
    }

    /// Returns false when the operation was ended or replaced, so the export must not be shown.
    func shareBackup(_ export: IOSBackupExport, operation: UUID) -> Bool {
        guard case .preparingBackup(let current, let root) = phase, current.id == operation else { return false }
        phase = .sharingBackup(export, root: root)
        return true
    }

    func finishSharingBackup() {
        guard case .sharingBackup(_, let root) = phase else { return }
        try? FileManager.default.removeItem(at: root)
        phase = .idle
    }

    @discardableResult
    func startPreviewingImport(_ body: @escaping OperationBody) -> Bool {
        switch phase {
        case .idle, .choosingBackup:
            phase = .previewingImport(start(body))
            return true
        case .inactive, .preparingBackup, .sharingBackup, .previewingImport, .confirmingImport:
            return false
        }
    }

    @discardableResult
    func startConfirmingImport(_ body: @escaping OperationBody) -> Bool {
        guard case .idle = phase else { return false }
        phase = .confirmingImport(start(body))
        return true
    }

    private func start(_ body: @escaping OperationBody) -> Operation {
        let id = UUID()
        let task = Task { @MainActor in
            await body(id)
            self.finishOperation(id)
        }
        return Operation(id: id, task: task)
    }

    private func finishOperation(_ id: UUID) {
        switch phase {
        case .preparingBackup(let operation, _), .previewingImport(let operation), .confirmingImport(let operation):
            guard operation.id == id else { return }
            phase = .idle
        case .inactive, .idle, .choosingBackup, .sharingBackup:
            return
        }
    }
}
