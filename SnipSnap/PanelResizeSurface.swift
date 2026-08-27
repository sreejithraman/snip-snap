import AppKit
import SwiftUI

struct PanelResizeEdges: OptionSet, Equatable {
    let rawValue: Int

    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let bottom = Self(rawValue: 1 << 2)
    static let top = Self(rawValue: 1 << 3)
}

enum PanelResizeGeometry {
    static func frame(
        from initialFrame: CGRect,
        dragDelta: CGPoint,
        edges: PanelResizeEdges,
        minimumSize: CGSize,
        maximumSize: CGSize
    ) -> CGRect {
        var minX = initialFrame.minX
        var maxX = initialFrame.maxX
        var minY = initialFrame.minY
        var maxY = initialFrame.maxY

        if edges.contains(.left) { minX += dragDelta.x }
        if edges.contains(.right) { maxX += dragDelta.x }
        if edges.contains(.bottom) { minY += dragDelta.y }
        if edges.contains(.top) { maxY += dragDelta.y }

        clamp(
            minimum: &minX,
            maximum: &maxX,
            minimumLength: minimumSize.width,
            maximumLength: maximumSize.width,
            movesMinimum: edges.contains(.left)
        )
        clamp(
            minimum: &minY,
            maximum: &maxY,
            minimumLength: minimumSize.height,
            maximumLength: maximumSize.height,
            movesMinimum: edges.contains(.bottom)
        )

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private static func clamp(
        minimum: inout CGFloat,
        maximum: inout CGFloat,
        minimumLength: CGFloat,
        maximumLength: CGFloat,
        movesMinimum: Bool
    ) {
        let upperLength = max(maximumLength, minimumLength)
        let length = min(max(maximum - minimum, minimumLength), upperLength)
        if movesMinimum {
            minimum = maximum - length
        } else {
            maximum = minimum + length
        }
    }
}

enum PanelResizeHitTesting {
    static let edgeWidth: CGFloat = 5
    static let cornerSize: CGFloat = 10

    struct Region: Equatable {
        let rect: CGRect
        let edges: PanelResizeEdges
    }

    static func regions(in bounds: CGRect) -> [Region] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }

        let cornerWidth = min(cornerSize, bounds.width / 2)
        let cornerHeight = min(cornerSize, bounds.height / 2)
        let horizontalEdgeWidth = min(edgeWidth, bounds.width)
        let verticalEdgeHeight = min(edgeWidth, bounds.height)
        let middleHeight = max(0, bounds.height - 2 * cornerHeight)
        let middleWidth = max(0, bounds.width - 2 * cornerWidth)

        return [
            Region(
                rect: CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: cornerWidth,
                    height: cornerHeight
                ),
                edges: [.left, .bottom]
            ),
            Region(
                rect: CGRect(
                    x: bounds.maxX - cornerWidth,
                    y: bounds.minY,
                    width: cornerWidth,
                    height: cornerHeight
                ),
                edges: [.right, .bottom]
            ),
            Region(
                rect: CGRect(
                    x: bounds.minX,
                    y: bounds.maxY - cornerHeight,
                    width: cornerWidth,
                    height: cornerHeight
                ),
                edges: [.left, .top]
            ),
            Region(
                rect: CGRect(
                    x: bounds.maxX - cornerWidth,
                    y: bounds.maxY - cornerHeight,
                    width: cornerWidth,
                    height: cornerHeight
                ),
                edges: [.right, .top]
            ),
            Region(
                rect: CGRect(
                    x: bounds.minX,
                    y: bounds.minY + cornerHeight,
                    width: horizontalEdgeWidth,
                    height: middleHeight
                ),
                edges: .left
            ),
            Region(
                rect: CGRect(
                    x: bounds.maxX - horizontalEdgeWidth,
                    y: bounds.minY + cornerHeight,
                    width: horizontalEdgeWidth,
                    height: middleHeight
                ),
                edges: .right
            ),
            Region(
                rect: CGRect(
                    x: bounds.minX + cornerWidth,
                    y: bounds.minY,
                    width: middleWidth,
                    height: verticalEdgeHeight
                ),
                edges: .bottom
            ),
            Region(
                rect: CGRect(
                    x: bounds.minX + cornerWidth,
                    y: bounds.maxY - verticalEdgeHeight,
                    width: middleWidth,
                    height: verticalEdgeHeight
                ),
                edges: .top
            )
        ].filter { !$0.rect.isEmpty }
    }

    static func edges(at point: CGPoint, in bounds: CGRect) -> PanelResizeEdges {
        guard bounds.contains(point) else { return [] }
        return regions(in: bounds).first { $0.rect.contains(point) }?.edges ?? []
    }
}

struct PanelResizeSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> PanelResizeView {
        PanelResizeView(frame: .zero)
    }

    func updateNSView(_ nsView: PanelResizeView, context: Context) { }
}

final class PanelResizeView: NSView {
    static let trackingEdgesKey = "PanelResizeEdges"

    private let screenMouseLocation: (NSEvent?) -> CGPoint
    private var initialMouseLocation: CGPoint?
    private var initialWindowFrame: CGRect?
    private var activeEdges: PanelResizeEdges = []
    private var hoverEdges: PanelResizeEdges = []
    private var resizeTrackingAreas: [NSTrackingArea] = []
    private weak var cursorRectsWindow: NSWindow?

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        screenMouseLocation = { _ in NSEvent.mouseLocation }
        super.init(frame: frameRect)
    }

    init(
        frame frameRect: NSRect,
        screenMouseLocation: @escaping (NSEvent?) -> CGPoint
    ) {
        self.screenMouseLocation = screenMouseLocation
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        screenMouseLocation = { _ in NSEvent.mouseLocation }
        super.init(coder: coder)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            hoverEdges = []
            finishResize()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        for area in resizeTrackingAreas {
            removeTrackingArea(area)
        }
        resizeTrackingAreas.removeAll(keepingCapacity: true)
        super.updateTrackingAreas()

        for region in PanelResizeHitTesting.regions(in: bounds) {
            let area = NSTrackingArea(
                rect: region.rect,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: [Self.trackingEdgesKey: region.edges.rawValue]
            )
            addTrackingArea(area)
            resizeTrackingAreas.append(area)
        }

        if let window {
            let previousHoverEdges = hoverEdges
            updateHover(
                atWindowPoint: window.convertPoint(
                    fromScreen: screenMouseLocation(nil)
                )
            )
            if activeEdges.isEmpty,
               !previousHoverEdges.isEmpty || !hoverEdges.isEmpty {
                updateCursorForHover()
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let edges = PanelResizeHitTesting.edges(at: point, in: bounds)
        return edges.isEmpty ? nil : self
    }

    override func mouseEntered(with event: NSEvent) {
        hoverEdges = trackedEdges(from: event)
        guard !hoverEdges.isEmpty else { return }
        resizeCursor(for: hoverEdges).set()
    }

    override func mouseExited(with event: NSEvent) {
        guard trackedEdges(from: event) == hoverEdges else { return }
        hoverEdges = []
        guard activeEdges.isEmpty else { return }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let edges = PanelResizeHitTesting.edges(
            at: convert(event.locationInWindow, from: nil),
            in: bounds
        )
        guard !edges.isEmpty, let window else { return }
        activeEdges = edges
        initialMouseLocation = screenMouseLocation(event)
        initialWindowFrame = window.frame
        if cursorRectsWindow == nil {
            cursorRectsWindow = window
            window.disableCursorRects()
        }
        resizeCursor(for: edges).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let initialMouseLocation,
              let initialWindowFrame,
              !activeEdges.isEmpty else { return }
        let currentLocation = screenMouseLocation(event)
        let dragDelta = CGPoint(
            x: currentLocation.x - initialMouseLocation.x,
            y: currentLocation.y - initialMouseLocation.y
        )
        let frame = PanelResizeGeometry.frame(
            from: initialWindowFrame,
            dragDelta: dragDelta,
            edges: activeEdges,
            minimumSize: window.minSize,
            maximumSize: window.maxSize
        )
        window.setFrame(frame, display: true)
        resizeCursor(for: activeEdges).set()
    }

    override func mouseUp(with event: NSEvent) {
        updateHover(atWindowPoint: event.locationInWindow)
        finishResize()
    }

    override func cancelOperation(_ sender: Any?) {
        guard !activeEdges.isEmpty else {
            nextResponder?.tryToPerform(
                #selector(cancelOperation(_:)),
                with: sender
            )
            return
        }
        if let window {
            updateHover(
                atWindowPoint: window.convertPoint(
                    fromScreen: screenMouseLocation(nil)
                )
            )
        } else {
            hoverEdges = []
        }
        finishResize()
    }

    private func updateHover(atWindowPoint point: CGPoint) {
        hoverEdges = PanelResizeHitTesting.edges(
            at: convert(point, from: nil),
            in: bounds
        )
    }

    private func finishResize() {
        activeEdges = []
        initialMouseLocation = nil
        initialWindowFrame = nil
        cursorRectsWindow?.enableCursorRects()
        cursorRectsWindow = nil
        updateCursorForHover()
    }

    private func updateCursorForHover() {
        if hoverEdges.isEmpty {
            NSCursor.arrow.set()
        } else {
            resizeCursor(for: hoverEdges).set()
        }
    }

    private func trackedEdges(from event: NSEvent) -> PanelResizeEdges {
        guard let rawValue = event.trackingArea?
            .userInfo?[Self.trackingEdgesKey] as? Int else { return [] }
        return PanelResizeEdges(rawValue: rawValue)
    }

    private func resizeCursor(for edges: PanelResizeEdges) -> NSCursor {
        .frameResize(position: cursorPosition(for: edges), directions: .all)
    }

    private func cursorPosition(for edges: PanelResizeEdges) -> NSCursor.FrameResizePosition {
        switch edges {
        case [.left, .bottom]: .bottomLeft
        case [.right, .bottom]: .bottomRight
        case [.left, .top]: .topLeft
        case [.right, .top]: .topRight
        case .left: .left
        case .right: .right
        case .bottom: .bottom
        default: .top
        }
    }
}
