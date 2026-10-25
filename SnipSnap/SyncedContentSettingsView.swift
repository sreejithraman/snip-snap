import AppKit
import Observation
import SnipSnapCloud
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers

struct SyncedContentSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: SyncedContentSettingsModel
    @ObservedObject var clipboard: ClipboardHistory
    @State private var confirmsClipboardSync = false
    var retryAction: (@MainActor @Sendable () async -> Void)?
    @State private var confirmsUsingDeviceCopy = false
    @State private var isRetryingSync = false
    @State private var isRetryingClipboardSync = false
    @State private var diagnostics = MacDiagnosticSettingsState()

    var body: some View {
        Form {
            Section("iCloud") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Sync with iCloud", isOn: syncEnabled)
                        .disabled(!canChangeSync)
                        .accessibilityIdentifier("icloud-sync-toggle")
                    syncMessage
                }

                if model.canRetryFailedSync, let retryAction {
                    Button("Try Again") {
                        isRetryingSync = true
                        Task {
                            await retryAction()
                            isRetryingSync = false
                        }
                    }
                    .disabled(isRetryingSync)
                    .accessibilityIdentifier("retry-icloud-sync")
                }
            }

            Section("Clipboard") {
                Toggle(isOn: Binding(
                    get: { model.canEnableClipboardSync && clipboard.clipboardSyncEnabled },
                    set: { enabled in
                        if enabled {
                            guard model.canEnableClipboardSync else { return }
                            confirmsClipboardSync = true
                        }
                        else { clipboard.setSyncEnabled(false) }
                    }
                )) {
                    Text("Sync clipboard history")
                }
                .disabled(!model.canEnableClipboardSync)
                .accessibilityIdentifier("clipboard-sync-toggle")

                if let error = clipboard.syncError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        isRetryingClipboardSync = true
                        Task {
                            await clipboard.syncNow()
                            isRetryingClipboardSync = false
                        }
                    }
                    .disabled(isRetryingClipboardSync)
                    .accessibilityIdentifier("retry-clipboard-sync")
                }
            }

            Section {
                Toggle("Record local diagnostics", isOn: Binding(
                    get: { diagnostics.recordingEnabled ?? true },
                    set: { diagnostics.setRecordingEnabled($0) }
                ))
                .accessibilityIdentifier("diagnostics-recording-toggle")
                Picker("Diagnostic log range", selection: $diagnostics.range) {
                    Text("Last 24 hours").tag(AppDiagnosticExportRange.last24Hours)
                    Text("Last 7 days").tag(AppDiagnosticExportRange.last7Days)
                }
                .accessibilityIdentifier("diagnostic-log-range")
                VStack(alignment: .leading, spacing: 8) {
                    Button("Share diagnostic log", systemImage: "square.and.arrow.up", action: diagnostics.share)
                        .accessibilityIdentifier("share-diagnostic-log")
                    Button("Clear diagnostic log", systemImage: "trash", action: diagnostics.clear)
                        .accessibilityIdentifier("clear-diagnostic-log")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(.bordered)
                if diagnostics.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating diagnostics")
                }
            } header: {
                Text("Support")
            } footer: {
                Text("Diagnostics stay on this device for up to 7 days; storage limits may shorten history. They exclude snip content and file names. Nothing is uploaded automatically. Turning recording off keeps retained logs; clear them separately. The system may keep separate logs.")
            }
            .disabled(diagnostics.isBusy || diagnostics.recordingEnabled == nil)
        }
        .formStyle(.grouped)
        .onAppear { diagnostics.activate() }
        .onDisappear { diagnostics.deactivate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { diagnostics.refreshRecording() }
        }
        .onChange(of: model.canEnableClipboardSync) { _, canEnable in
            if !canEnable { confirmsClipboardSync = false }
        }
        .alert("Sync clipboard history?", isPresented: $confirmsClipboardSync) {
            Button("Cancel", role: .cancel) {}
            Button("Sync clipboard history") {
                guard model.canEnableClipboardSync else { return }
                clipboard.setSyncEnabled(true)
            }
        } message: {
            Text("Sync text, images, and pinned files across your devices. Files that have synced keep syncing after you unpin them.")
        }
        .alert("Turn off sync?", isPresented: $confirmsUsingDeviceCopy) {
            Button("Cancel", role: .cancel) {}
            Button("Turn off sync") {
                Task { await model.disableICloudSync(.useCurrentCache) }
            }
        } message: {
            Text("Couldn’t get the latest iCloud changes. Turning off sync uses this Mac’s copy, which may be out of date. Your iCloud data stays.")
        }
        .alert("Diagnostics", isPresented: Binding(
            get: { diagnostics.message != nil },
            set: { if !$0 { diagnostics.message = nil } }
        )) {
            if diagnostics.recordingEnabled == nil {
                Button("Try Again") { diagnostics.refreshRecording() }
            }
            Button("OK", role: .cancel) { diagnostics.message = nil }
        } message: {
            Text(diagnostics.message ?? "")
        }
    }

    init(
        model: SyncedContentSettingsModel,
        clipboard: ClipboardHistory,
        retryAction: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        self.model = model
        self.clipboard = clipboard
        self.retryAction = retryAction
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
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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

    private var isSyncBusy: Bool {
        switch model.state {
        case .enabling, .syncing, .disabling, .deleting: true
        case .ready, .removalPending, .deleted, .failed: false
        }
    }
}

/// Owns diagnostic operations for this settings presentation, including save-panel lifetime.
@MainActor
@Observable
private final class MacDiagnosticSettingsState {
    var range: AppDiagnosticExportRange = .last24Hours
    private(set) var recordingEnabled: Bool?
    var message: String?
    private var task: Task<Void, Never>?
    private var savePanel: NSSavePanel?
    private var isActive = false

    var isBusy: Bool { task != nil || savePanel != nil }

    func activate() {
        isActive = true
        refreshRecording()
    }

    func deactivate() {
        isActive = false
        message = nil
        task?.cancel()
        let panel = savePanel
        savePanel = nil
        panel?.cancel(nil)
    }

    func refreshRecording() {
        guard isActive, !isBusy else { return }
        perform(operation: "diagnostics.recording", work: { try AppDiagnosticsExport.readRecordingEnabled() }) { result in
            switch result {
            case .success(let enabled): self.recordingEnabled = enabled
            case .failure:
                self.message = String(localized: "Couldn’t read the diagnostics setting. Try again.")
            }
        }
    }

    func setRecordingEnabled(_ enabled: Bool) {
        guard let previous = recordingEnabled, isActive, !isBusy else { return }
        recordingEnabled = enabled
        perform(operation: "diagnostics.recording", work: {
            try AppDiagnosticsExport.setRecordingEnabled(enabled)
            return enabled
        }) { result in
            switch result {
            case .success(let saved): self.recordingEnabled = saved
            case .failure:
                self.recordingEnabled = previous
                self.message = String(localized: "Couldn’t save the diagnostics setting. Try again.")
            }
        }
    }

    func share() {
        guard isActive, !isBusy else { return }
        let selectedRange = range
        let panel = NSSavePanel()
        savePanel = panel
        panel.title = String(localized: "Share diagnostic log")
        panel.prompt = String(localized: "Save")
        panel.nameFieldStringValue = "Snip-Snap-Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, self.savePanel === panel else { return }
            self.savePanel = nil
            guard self.isActive, response == .OK, let destination = panel.url else { return }
            self.perform(operation: "diagnostics.export", work: {
                let source = try AppDiagnosticsExport.makeShareableFile(range: selectedRange)
                defer { AppDiagnosticsExport.removeShareableFile(source) }
                try Task.checkCancellation()
                let didAccess = destination.startAccessingSecurityScopedResource()
                defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: source)
                try Task.checkCancellation()
                try data.write(to: destination, options: .atomic)
            }) { result in
                switch result {
                case .success:
                    self.message = String(localized: "Diagnostic log saved. You can attach it to your support message.")
                case .failure:
                    self.message = String(localized: "Couldn’t save the diagnostic log. Try again.")
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func clear() {
        guard isActive, !isBusy else { return }
        perform(operation: "diagnostics.clear", work: { try AppDiagnosticsExport.clear() }) { result in
            switch result {
            case .success: self.message = String(localized: "Diagnostic log cleared.")
            case .failure: self.message = String(localized: "Couldn’t clear the diagnostic log. Try again.")
            }
        }
    }

    private func perform<Output: Sendable>(
        operation: StaticString? = nil,
        work: @escaping @Sendable () throws -> Output,
        completion: @escaping @MainActor (Result<Output, any Error>) -> Void
    ) {
        guard isActive, !isBusy else { return }
        let worker = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                return try work()
            } catch {
                if !(error is CancellationError), let operation {
                    AppDiagnosticRecorder.live.record(.failure(operation: operation, error: error, visibility: .user))
                }
                throw error
            }
        }
        task = Task {
            defer {
                task = nil
                // A reopened settings view must reconcile a write that finished after cancellation.
                if isActive, Task.isCancelled { refreshRecording() }
            }
            do {
                let output = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard isActive, !Task.isCancelled else { return }
                completion(.success(output))
            } catch {
                guard isActive, !Task.isCancelled else { return }
                completion(.failure(error))
            }
        }
    }
}
