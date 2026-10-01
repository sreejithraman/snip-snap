import AppKit
import SnipSnapCloud
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers

struct SyncedContentSettingsView: View {
    @Bindable var model: SyncedContentSettingsModel
    @ObservedObject var clipboard: ClipboardHistory
    @State private var confirmsClipboardSync = false
    var retryAction: (@MainActor @Sendable () async -> Void)?
    @State private var confirmsUsingDeviceCopy = false
    @State private var isRetryingSync = false
    @State private var isRetryingClipboardSync = false
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsMessage: String?

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
                VStack(alignment: .leading, spacing: 8) {
                    Button("Share diagnostic log", systemImage: "square.and.arrow.up", action: shareDiagnostics)
                        .accessibilityIdentifier("share-diagnostic-log")
                    Button("Clear diagnostic log", systemImage: "trash", action: clearDiagnostics)
                        .accessibilityIdentifier("clear-diagnostic-log")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(.bordered)
                .disabled(isExportingDiagnostics)
            } header: {
                Text("Support")
            } footer: {
                Text("Includes only recent sync stages and error codes—not your content or file names.")
            }
        }
        .formStyle(.grouped)
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
            get: { diagnosticsMessage != nil },
            set: { if !$0 { diagnosticsMessage = nil } }
        )) {
            Button("OK", role: .cancel) { diagnosticsMessage = nil }
        } message: {
            Text(diagnosticsMessage ?? "")
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

    private func shareDiagnostics() {
        guard !isExportingDiagnostics else { return }
        isExportingDiagnostics = true
        let panel = NSSavePanel()
        panel.title = String(localized: "Share diagnostic log")
        panel.prompt = String(localized: "Save")
        panel.nameFieldStringValue = "Snip-Snap-Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            defer { isExportingDiagnostics = false }
            guard response == .OK, let destination = panel.url else { return }
            let didAccess = destination.startAccessingSecurityScopedResource()
            defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }
            do {
                let source = try CloudSyncDiagnosticsExport.makeShareableFile()
                try Data(contentsOf: source).write(to: destination, options: .atomic)
                diagnosticsMessage = String(localized: "Diagnostic log saved. You can attach it to your support message.")
            } catch {
                AppDiagnostics.shared.record(.failure(
                    operation: "diagnostics.export",
                    error: error,
                    visibility: .user
                ))
                diagnosticsMessage = String(localized: "Couldn’t save the diagnostic log. Try again.")
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func clearDiagnostics() {
        guard !isExportingDiagnostics else { return }
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
