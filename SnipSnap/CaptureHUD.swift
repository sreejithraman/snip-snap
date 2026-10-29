import AppKit
import SwiftUI

@MainActor
final class CaptureHUDController {
    enum FailureFeedback: Equatable {
        case ignored
        case confirmation
        case failure
    }

    private let panel: NSPanel
    private var dismissWorkItem: DispatchWorkItem?
    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
    }

    @discardableResult
    func show(failure: SelectionCaptureFailure) -> FailureFeedback {
        // With no selection, many apps leave the clipboard unchanged on Copy.
        // The reader reports that as a timeout, so keep both empty outcomes quiet.
        guard failure != .noSelection, failure != .copyTimedOut else { return .ignored }
        show(
            message: failure.localizedDescription,
            symbol: failure == .duplicateSelection ? "scissors" : "exclamationmark.triangle"
        )
        return failure == .duplicateSelection ? .confirmation : .failure
    }

    func show(message: String, symbol: String, detail: String? = nil) {
        dismissWorkItem?.cancel()
        let hostingView = NSHostingView(
            rootView: CaptureHUDView(message: message, symbol: symbol, detail: detail)
        )
        panel.contentView = hostingView
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(
                    x: frame.midX - panel.frame.width / 2,
                    y: frame.minY + 36
                )
            )
        }
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak panel] in
            panel?.orderOut(nil)
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: workItem)
    }
}

private struct CaptureHUDView: View {
    let message: String
    let symbol: String
    let detail: String?

    var body: some View {
        content
            .panelGlassSurface(
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }

    private var content: some View {
        HStack {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
