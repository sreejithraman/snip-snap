import AppKit
import SwiftUI

private final class PanelDragPanGestureRecognizer: NSPanGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: NSGestureRecognizer) -> Bool {
        true
    }

    override func canBePrevented(by preventingGestureRecognizer: NSGestureRecognizer) -> Bool {
        false
    }
}

enum PanelDragSessionOutcome: Equatable {
    case copy
    case move
    case cancelled

    init(operation: NSDragOperation) {
        if operation.contains(.copy) {
            self = .copy
        } else if operation.contains(.move) {
            self = .move
        } else {
            self = .cancelled
        }
    }
}

enum PanelDragSessionRegionID: Hashable {
    case snip(UUID)
    case clipboardEntry(UUID)
}

struct PanelDragSourceContext {
    let scale: CGFloat
    let colorScheme: ColorScheme
    let sourceFrame: NSRect
}

protocol PanelDragExportPackage {
    static func sourceOperationMask(for context: NSDraggingContext) -> NSDragOperation

    func pasteboardWriters() -> [NSPasteboardWriting]
}

@MainActor
struct PanelDragSessionCallbacks {
    let onBegan: () -> Void
    let onMoved: (NSPoint) -> Void
    let onEnded: (PanelDragSessionOutcome, NSPoint) -> Void

    static let none = Self(
        onBegan: {},
        onMoved: { _ in },
        onEnded: { _, _ in }
    )
}

@MainActor
struct PanelDragSessionContent {
    let draggingItems: [NSDraggingItem]
    let retainedExport: Any

    init<Export: PanelDragExportPackage>(
        retaining export: Export,
        context: PanelDragSourceContext,
        previewImage: NSImage
    ) {
        draggingItems = export.pasteboardWriters().enumerated().map { index, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            if index == 0 {
                item.setDraggingFrame(context.sourceFrame, contents: previewImage)
            } else {
                item.draggingFrame = NSRect(
                    origin: context.sourceFrame.origin,
                    size: NSSize(width: 1, height: 1)
                )
                item.imageComponentsProvider = { [] }
            }
            return item
        }
        retainedExport = export
    }
}

@MainActor
struct PanelDragSessionAdapter {
    let canBegin: () -> Bool
    let onBlocked: () -> Void
    let makeSession: (PanelDragSourceContext) -> PanelDragSessionContent
    let sourceOperationMask: (NSDraggingContext) -> NSDragOperation
    let onBegan: () -> Void
    let onMoved: (NSPoint) -> Void
    let onEnded: (PanelDragSessionOutcome, NSPoint) -> Void

    static func exporting<Export: PanelDragExportPackage>(
        makeExport: @escaping () -> Export,
        previewImage: @escaping (Export, PanelDragSourceContext) -> NSImage,
        canBegin: @escaping () -> Bool = { true },
        onBlocked: @escaping () -> Void = {},
        callbacks: PanelDragSessionCallbacks = .none
    ) -> Self {
        Self(
            canBegin: canBegin,
            onBlocked: onBlocked,
            makeSession: { context in
                let export = makeExport()
                return PanelDragSessionContent(
                    retaining: export,
                    context: context,
                    previewImage: previewImage(export, context)
                )
            },
            sourceOperationMask: { context in
                Export.sourceOperationMask(for: context)
            },
            onBegan: callbacks.onBegan,
            onMoved: callbacks.onMoved,
            onEnded: callbacks.onEnded
        )
    }
}

struct PanelDragSessionInspection: Equatable {
    let regionID: PanelDragSessionRegionID
}

/// Shared AppKit bridge for registering one SwiftUI card as a drag source.
///
/// Content-specific views only build the adapter; this view owns registration,
/// window attachment, hit testing, updates, and teardown.
struct PanelDragSourceRegion: NSViewRepresentable {
    let controller: PanelDragSessionController
    let regionID: PanelDragSessionRegionID
    let adapter: PanelDragSessionAdapter

    func makeNSView(context: Context) -> PanelDragSourceRegionView {
        PanelDragSourceRegionView(
            controller: controller,
            regionID: regionID,
            adapter: adapter
        )
    }

    func updateNSView(_ nsView: PanelDragSourceRegionView, context: Context) {
        nsView.configure(adapter: adapter)
    }

    static func dismantleNSView(_ nsView: PanelDragSourceRegionView, coordinator: ()) {
        nsView.removeFromController()
    }
}

@MainActor
final class PanelDragSourceRegionView: NSView {
    private let controller: PanelDragSessionController
    private let regionID: PanelDragSessionRegionID
    private var adapter: PanelDragSessionAdapter

    init(
        controller: PanelDragSessionController,
        regionID: PanelDragSessionRegionID,
        adapter: PanelDragSessionAdapter
    ) {
        self.controller = controller
        self.regionID = regionID
        self.adapter = adapter
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(adapter: PanelDragSessionAdapter) {
        self.adapter = adapter
        updateController()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateController()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func removeFromController() {
        controller.unregisterRegion(id: regionID)
    }

    private func updateController() {
        controller.registerRegion(
            id: regionID,
            view: window == nil ? nil : self,
            adapter: adapter
        )
    }
}

/// Owns the panel's single drag gesture and drag-session lifecycle.
///
/// Content adapters provide their own writers, previews, and operation policy
/// without competing for the same mouse gesture.
@MainActor
final class PanelDragSessionController: NSObject, NSDraggingSource, NSGestureRecognizerDelegate {
    private final class WeakView {
        weak var value: NSView?

        init(_ value: NSView) {
            self.value = value
        }
    }

    private final class Region {
        let id: PanelDragSessionRegionID
        weak var view: NSView?
        let adapter: PanelDragSessionAdapter

        init(
            id: PanelDragSessionRegionID,
            view: NSView,
            adapter: PanelDragSessionAdapter
        ) {
            self.id = id
            self.view = view
            self.adapter = adapter
        }
    }

    private weak var hostView: NSView?
    private var regions: [PanelDragSessionRegionID: Region] = [:]
    private var blockingViews: [UUID: WeakView] = [:]
    private var pendingRegion: Region?
    private var activeRegion: Region?
    private var activeSessionContent: PanelDragSessionContent?
    private lazy var panRecognizer: NSPanGestureRecognizer = {
        let recognizer = PanelDragPanGestureRecognizer(
            target: self,
            action: #selector(handlePan(_:))
        )
        recognizer.delegate = self
        recognizer.delaysPrimaryMouseButtonEvents = false
        return recognizer
    }()

    func attach(to hostView: NSView) {
        guard self.hostView !== hostView else { return }
        if let current = self.hostView {
            current.removeGestureRecognizer(panRecognizer)
        }
        self.hostView = hostView
        hostView.addGestureRecognizer(panRecognizer)
    }

    func registerRegion(
        id: PanelDragSessionRegionID,
        view: NSView?,
        adapter: PanelDragSessionAdapter
    ) {
        guard let view, view.window != nil else {
            regions.removeValue(forKey: id)
            if pendingRegion?.id == id {
                pendingRegion = nil
            }
            return
        }
        regions[id] = Region(
            id: id,
            view: view,
            adapter: adapter
        )
    }

    func unregisterRegion(id: PanelDragSessionRegionID) {
        regions.removeValue(forKey: id)
        if pendingRegion?.id == id {
            pendingRegion = nil
        }
    }

    func registerBlockingRegion(id: UUID, view: NSView?) {
        guard let view, view.window != nil else {
            blockingViews.removeValue(forKey: id)
            return
        }
        blockingViews[id] = WeakView(view)
    }

    func unregisterBlockingRegion(id: UUID) {
        blockingViews.removeValue(forKey: id)
    }

    func inspection(atWindowPoint point: NSPoint) -> PanelDragSessionInspection? {
        region(atWindowPoint: point).map {
            PanelDragSessionInspection(regionID: $0.id)
        }
    }

    var hasPendingRegionForTesting: Bool {
        pendingRegion != nil
    }

    private func region(atWindowPoint point: NSPoint) -> Region? {
        if let hostView,
           let hitView = hostView.hitTest(hostView.convert(point, from: nil)),
           sequence(first: hitView, next: \NSView.superview).contains(where: {
               $0 is PanelResizeView
           }) {
            return nil
        }
        blockingViews = blockingViews.filter { $0.value.value?.window != nil }
        let isBlocked = blockingViews.values.contains { blockingView in
            guard let view = blockingView.value else { return false }
            return isVisible(point, in: view)
        }
        guard !isBlocked else { return nil }
        regions = regions.filter { $0.value.view?.window != nil }
        return regions.values.first { region in
            guard let view = region.view else { return false }
            return isVisible(point, in: view)
        }
    }

    private func isVisible(_ windowPoint: NSPoint, in view: NSView) -> Bool {
        guard !view.isHidden, view.alphaValue > 0 else { return false }
        let localPoint = view.convert(windowPoint, from: nil)
        return view.bounds.intersection(view.visibleRect).contains(localPoint)
    }

    func gestureRecognizer(
        _: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        guard event.type == .leftMouseDown else { return false }
        pendingRegion = region(atWindowPoint: event.locationInWindow)
        return pendingRegion != nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: NSGestureRecognizer
    ) -> Bool {
        false
    }

    @objc
    private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        guard recognizer.state == .began else {
            if recognizer.state == .failed
                || recognizer.state == .cancelled
                || recognizer.state == .ended {
                pendingRegion = nil
            }
            return
        }
        guard let hostView,
              let event = NSApp.currentEvent,
              let region = pendingRegion,
              let regionView = region.view else {
            pendingRegion = nil
            return
        }
        defer { pendingRegion = nil }
        guard region.adapter.canBegin() else {
            region.adapter.onBlocked()
            return
        }
        let scale = hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let colorScheme: ColorScheme = hostView.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua ? .dark : .light
        let sourceFrame = regionView.convert(regionView.bounds, to: hostView)
        let sessionContent = region.adapter.makeSession(
            PanelDragSourceContext(
                scale: scale,
                colorScheme: colorScheme,
                sourceFrame: sourceFrame
            )
        )
        guard !sessionContent.draggingItems.isEmpty else { return }
        region.adapter.onBegan()
        activeRegion = region
        activeSessionContent = sessionContent
        let session = hostView.beginDraggingSession(
            with: sessionContent.draggingItems,
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        activeRegion?.adapter.sourceOperationMask(context) ?? []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        movedTo screenPoint: NSPoint
    ) {
        activeRegion?.adapter.onMoved(windowPoint(from: screenPoint))
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let region = activeRegion
        activeRegion = nil
        activeSessionContent = nil
        pendingRegion = nil
        region?.adapter.onEnded(
            PanelDragSessionOutcome(operation: operation),
            windowPoint(from: screenPoint)
        )
    }

    private func windowPoint(from screenPoint: NSPoint) -> NSPoint {
        hostView?.window?.convertPoint(fromScreen: screenPoint) ?? screenPoint
    }
}

struct PanelDragBlockingRegion: NSViewRepresentable {
    let controller: PanelDragSessionController
    let id: UUID

    func makeNSView(context: Context) -> PanelDragBlockingRegionView {
        PanelDragBlockingRegionView(controller: controller, id: id)
    }

    func updateNSView(_ nsView: PanelDragBlockingRegionView, context: Context) {
        nsView.updateController()
    }

    static func dismantleNSView(_ nsView: PanelDragBlockingRegionView, coordinator: ()) {
        nsView.removeFromController()
    }
}

@MainActor
final class PanelDragBlockingRegionView: NSView {
    private let controller: PanelDragSessionController
    private let id: UUID

    init(controller: PanelDragSessionController, id: UUID) {
        self.controller = controller
        self.id = id
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateController()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func updateController() {
        controller.registerBlockingRegion(id: id, view: window == nil ? nil : self)
    }

    func removeFromController() {
        controller.unregisterBlockingRegion(id: id)
    }
}
