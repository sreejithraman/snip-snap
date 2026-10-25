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
    @Bindable var diagnostics: AppDiagnosticSettingsModel
    @State private var diagnosticDelivery = MacDiagnosticDelivery()

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
                if let enabled = diagnostics.recordingEnabled {
                    Toggle("Record local diagnostics", isOn: Binding(
                        get: { diagnostics.recordingEnabled ?? enabled },
                        set: { diagnostics.setRecordingEnabled($0) }
                    ))
                    .disabled(!diagnostics.canPerformActions)
                    .accessibilityIdentifier("diagnostics-recording-toggle")
                } else {
                    LabeledContent("Record local diagnostics", value: String(localized: "Unavailable"))
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
                VStack(alignment: .leading, spacing: 8) {
                    Button("Share diagnostic log", systemImage: "square.and.arrow.up") {
                        diagnostics.share(deliver: diagnosticDelivery.deliver)
                    }
                    .accessibilityIdentifier("share-diagnostic-log")
                    Button("Clear diagnostic log", systemImage: "trash", action: diagnostics.clear)
                        .accessibilityIdentifier("clear-diagnostic-log")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(.bordered)
                .disabled(!diagnostics.canPerformActions)
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
            get: { diagnostics.notice != nil },
            set: { if !$0 { diagnostics.dismissNotice() } }
        )) {
            if diagnostics.recordingEnabled == nil {
                Button("Try Again") { diagnostics.refreshRecording() }
            }
            Button("OK", role: .cancel) { diagnostics.dismissNotice() }
        } message: {
            Text(diagnosticMessage)
        }
    }

    init(
        model: SyncedContentSettingsModel,
        clipboard: ClipboardHistory,
        diagnostics: AppDiagnosticSettingsModel,
        retryAction: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        self.diagnostics = diagnostics
        self.model = model
        self.clipboard = clipboard
        self.retryAction = retryAction
    }

    private var diagnosticMessage: String {
        switch diagnostics.notice {
        case .readFailed: String(localized: "Couldn’t read the diagnostics setting. Try again.")
        case .saveFailed: String(localized: "Couldn’t save the diagnostics setting. Try again.")
        case .preparationFailed: String(localized: "Couldn’t prepare the diagnostic log. Try again.")
        case .deliveryFailed: String(localized: "Couldn’t save the diagnostic log. Try again.")
        case .clearFailed: String(localized: "Couldn’t clear the diagnostic log. Try again.")
        case .saved: String(localized: "Diagnostic log saved. You can attach it to your support message.")
        case .cleared: String(localized: "Diagnostic log cleared.")
        case nil: ""
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

/// AppKit delivery owns destination access and settles only after panel/copy completion.
@MainActor
@Observable
private final class MacDiagnosticDelivery {
    private var panel: NSSavePanel?

    func deliver(_ source: URL) async throws -> AppDiagnosticSettingsModel.DeliveryOutcome {
        try Task.checkCancellation()
        let savePanel = NSSavePanel()
        panel = savePanel
        let panelIdentity = ObjectIdentifier(savePanel)
        savePanel.title = String(localized: "Share diagnostic log")
        savePanel.prompt = String(localized: "Save")
        savePanel.nameFieldStringValue = "Snip-Snap-Diagnostics.txt"
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true
        let destination: URL? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion: (NSApplication.ModalResponse) -> Void = { [weak savePanel] response in
                    continuation.resume(returning: response == .OK ? savePanel?.url : nil)
                }
                if let window = NSApp.keyWindow {
                    savePanel.beginSheetModal(for: window, completionHandler: completion)
                } else {
                    savePanel.begin(completionHandler: completion)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let panel = self?.panel, ObjectIdentifier(panel) == panelIdentity else { return }
                panel.cancel(nil)
            }
        }
        panel = nil
        guard let destination else { return .cancelled }
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let didAccess = destination.startAccessingSecurityScopedResource()
            defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: source)
            try Task.checkCancellation()
            try data.write(to: destination, options: .atomic)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        return .saved
    }
}
