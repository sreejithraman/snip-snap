import AppKit
import SwiftUI

@MainActor
final class SnipListReorderGeometry: ObservableObject {
    var rowFrames: [UUID: CGRect] = [:]
    var listFrame: CGRect = .zero
    var scrollOffsetY: CGFloat = 0
}

struct SnipListWindowFrameReader: NSViewRepresentable {
    let onChange: @MainActor (CGRect, CGFloat) -> Void

    func makeNSView(context: Context) -> SnipListWindowFrameReaderView {
        SnipListWindowFrameReaderView(onChange: onChange)
    }

    func updateNSView(_ nsView: SnipListWindowFrameReaderView, context: Context) {
        nsView.onChange = onChange
        nsView.reportFrameIfNeeded()
    }
}

@MainActor
final class SnipListWindowFrameReaderView: NSView {
    var onChange: @MainActor (CGRect, CGFloat) -> Void
    private var lastFrame: CGRect?
    private var lastScrollOffsetY: CGFloat?
    private weak var observedClipView: NSClipView?

    init(onChange: @escaping @MainActor (CGRect, CGFloat) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        observeScrollIfNeeded()
        reportFrameIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScrollIfNeeded()
        reportFrameIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func reportFrameIfNeeded() {
        guard window != nil else { return }
        let nextFrame = convert(bounds, to: nil)
        let nextScrollOffsetY = enclosingScrollView?.contentView.bounds.origin.y ?? 0
        guard nextFrame != lastFrame || nextScrollOffsetY != lastScrollOffsetY else { return }
        lastFrame = nextFrame
        lastScrollOffsetY = nextScrollOffsetY
        onChange(nextFrame, nextScrollOffsetY)
    }

    private func observeScrollIfNeeded() {
        let clipView = window == nil ? nil : enclosingScrollView?.contentView
        guard observedClipView !== clipView else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
        observedClipView = clipView
        guard let clipView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc
    private func clipViewBoundsDidChange(_ notification: Notification) {
        reportFrameIfNeeded()
    }
}
