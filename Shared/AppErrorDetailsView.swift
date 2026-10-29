import SnipSnapCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AppUndoRecoveryView: View {
    let failure: AppFailure
    let onRetry: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.title, systemImage: "exclamationmark.triangle")
                .fontWeight(.semibold)
            HStack {
                Button(action: onRetry) {
                    Text("Retry Undo")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                Button(action: onDetails) {
                    Text("Details")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("undo-recovery")
    }
}

struct AppErrorDetailsView: View {
    let failure: AppFailure
    let onClose: () -> Void
    var onRetry: (() -> Void)? = nil

    var body: some View {
        AppErrorDetailsContent(failure: failure, onClose: onClose, onRetry: onRetry)
            .id(failure.id)
    }
}

private struct AppErrorDetailsContent: View {
    let failure: AppFailure
    let onClose: () -> Void
    let onRetry: (() -> Void)?

    @State private var diagnostics = AppDiagnosticSettingsModel()
    @State private var didCopy = false
    @State private var isCopying = false
    @State private var copyTask: Task<Void, Never>?
#if os(macOS)
    @State private var delivery = MacDiagnosticDelivery()
#else
    @State private var delivery = IOSDiagnosticShareDelivery()
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(failure.title, systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(failure.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Error details")
                    .font(.subheadline.weight(.semibold))
                Text(failure.operation)
                Text(failure.code)
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            if let onRetry {
                Button("Try Again", action: onRetry)
                    .accessibilityIdentifier("retry-error-action")
            }
            Button {
                copyErrorDetails()
            } label: {
                Label(didCopy ? String(localized: "Error details copied") : String(localized: "Copy error details"),
                      systemImage: didCopy ? "doc.on.clipboard" : "doc.on.doc")
            }
            .disabled(isCopying)
            .accessibilityIdentifier("copy-error-details")
            Button("Share diagnostic log") {
                diagnostics.share(deliver: delivery.deliver)
            }
            .disabled(!diagnostics.canPerformActions)
            .accessibilityIdentifier("share-error-diagnostic-log")
            if let message = diagnosticNotice {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("error-diagnostic-notice")
            }
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("close-error-details")
            }
        }
        .padding(20)
        .frame(maxWidth: 460, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error-details")
        .onAppear { diagnostics.activate() }
        .onDisappear {
            copyTask?.cancel()
            diagnostics.deactivate()
        }
#if os(iOS)
        .background {
            IOSShareSheetPresenter(request: $delivery.request, diagnosticOperation: "diagnostics.export")
                .frame(width: 0, height: 0)
        }
#endif
    }

    private func copyErrorDetails() {
        isCopying = true
        let failure = failure
#if os(macOS)
        let clipboardRevision = NSPasteboard.general.changeCount
#else
        let clipboardRevision = UIPasteboard.general.changeCount
#endif
        copyTask = Task { @MainActor in
            let report = await Task.detached(priority: .userInitiated) {
                let logs = try? AppDiagnosticsExport.readLog(limit: 20, errorsOnly: true)
                let relevant = logs?.text.split(separator: "\n").filter {
                    $0.contains(failure.operation) && $0.contains(failure.code)
                }.suffix(5).joined(separator: "\n") ?? ""
                return relevant.isEmpty ? failure.diagnosticReport
                    : failure.diagnosticReport + "\n\nRecent matching diagnostics\n" + relevant
            }.value
            guard !Task.isCancelled else { return }
#if os(macOS)
            guard NSPasteboard.general.changeCount == clipboardRevision else {
                isCopying = false
                return
            }
            NSPasteboard.general.clearContents()
            didCopy = NSPasteboard.general.setString(report, forType: .string)
#else
            guard UIPasteboard.general.changeCount == clipboardRevision else {
                isCopying = false
                return
            }
            UIPasteboard.general.string = report
            didCopy = true
#endif
            isCopying = false
        }
    }

    private var diagnosticNotice: String? {
        switch diagnostics.notice {
        case .readFailed: String(localized: "Couldn’t read the diagnostics setting. Try again.")
        case .saveFailed: String(localized: "Couldn’t save the diagnostics setting. Try again.")
        case .preparationFailed: String(localized: "Couldn’t prepare the diagnostic log. Try again.")
        case .deliveryFailed: String(localized: "Couldn’t share the diagnostic log. Try again.")
        case .clearFailed: String(localized: "Couldn’t clear the diagnostic log. Try again.")
        case .saved: String(localized: "Diagnostic log saved. You can attach it to your support message.")
        case .cleared: String(localized: "Diagnostic log cleared.")
        case nil: nil
        }
    }
}
