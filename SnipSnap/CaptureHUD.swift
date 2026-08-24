import AppKit
import SwiftUI

@MainActor
final class CaptureHUDController {
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

    func show(message: String, symbol: String) {
        dismissWorkItem?.cancel()
        let hostingView = NSHostingView(
            rootView: CaptureHUDView(message: message, symbol: symbol)
        )
        panel.contentView = hostingView
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(
                    x: frame.midX - panel.frame.width / 2,
                    y: frame.maxY - panel.frame.height - 36
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
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
