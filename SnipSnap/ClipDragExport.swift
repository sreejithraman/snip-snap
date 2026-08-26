import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class ClipDragPanGestureRecognizer: NSPanGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: NSGestureRecognizer) -> Bool {
        true
    }

    override func canBePrevented(by preventingGestureRecognizer: NSGestureRecognizer) -> Bool {
        false
    }
}

enum ClipDragOutcome: Equatable {
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

private final class ClipMarkdownPromiseDelegate: NSObject,
    NSFilePromiseProviderDelegate,
    @unchecked Sendable {
    private let contents: Data
    private let queue: OperationQueue

    init(markdown: String) {
        contents = Data(markdown.utf8)
        queue = OperationQueue()
        queue.name = "world.sree.snipsnap.clip-markdown-promise"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        "Snip Snap Clip.md"
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        do {
            try contents.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(
        for filePromiseProvider: NSFilePromiseProvider
    ) -> OperationQueue {
        queue
    }
}

struct ClipDragExportPackage {
    let payload: ClipDragPayload
    private let markdownPromiseDelegate: ClipMarkdownPromiseDelegate?
    private let markdownPromiseProvider: NSFilePromiseProvider?

    init(payload: ClipDragPayload) {
        self.payload = payload
        if !payload.text.isEmpty, !payload.attachmentURLs.isEmpty {
            let delegate = ClipMarkdownPromiseDelegate(markdown: Self.markdown(for: payload))
            markdownPromiseDelegate = delegate
            let provider = NSFilePromiseProvider(
                fileType: UTType.data.identifier,
                delegate: delegate
            )
            provider.userInfo = delegate
            markdownPromiseProvider = provider
        } else {
            markdownPromiseDelegate = nil
            markdownPromiseProvider = nil
        }
    }

    func pasteboardWriters() -> [NSPasteboardWriting] {
        if let markdownPromiseProvider {
            return [markdownPromiseProvider]
                + payload.attachmentURLs.map { $0 as NSURL }
                + [privatePayloadWriter()]
        }

        let primary = NSPasteboardItem()
        if !payload.text.isEmpty {
            primary.setString(payload.text, forType: .string)
            addPrivatePayload(to: primary)
            return [primary] + payload.attachmentURLs.map { $0 as NSURL }
        }

        guard !payload.attachmentURLs.isEmpty else {
            addPrivatePayload(to: primary)
            return [primary]
        }
        return payload.attachmentURLs.map { $0 as NSURL }
            + [privatePayloadWriter()]
    }

    static func markdown(for payload: ClipDragPayload) -> String {
        var result = payload.text
        if !result.hasSuffix("\n") {
            result.append("\n")
        }
        result.append("\n## Attachments\n\n")
        for url in payload.attachmentURLs {
            let name = url.lastPathComponent.replacingOccurrences(of: "`", with: "\\`")
            result.append("- `\(name)`\n")
        }
        return result
    }

    private func addPrivatePayload(to item: NSPasteboardItem) {
        if let encoded = try? JSONEncoder().encode(payload) {
            item.setData(encoded, forType: Self.privateType)
        }
    }

    private func privatePayloadWriter() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        addPrivatePayload(to: item)
        return item
    }

    @MainActor
    func draggingItems(
        at origin: NSPoint,
        scale: CGFloat,
        colorScheme: ColorScheme,
        sourceFrame: NSRect? = nil
    ) -> [NSDraggingItem] {
        let preview = cardPreviewImage(
            scale: scale,
            colorScheme: colorScheme,
            size: sourceFrame?.size
        )
        let previewFrame = sourceFrame ?? NSRect(
            x: origin.x,
            y: origin.y - preview.size.height,
            width: preview.size.width,
            height: preview.size.height
        )
        return pasteboardWriters().enumerated().map { index, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            if index == 0 {
                item.setDraggingFrame(previewFrame, contents: preview)
            } else {
                item.draggingFrame = NSRect(
                    origin: origin,
                    size: NSSize(width: 1, height: 1)
                )
                item.imageComponentsProvider = { [] }
            }
            return item
        }
    }

    static let privateType = NSPasteboard.PasteboardType(UTType.snipSnapClipDrag.identifier)

    @MainActor
    private func cardPreviewImage(
        scale: CGFloat,
        colorScheme: ColorScheme,
        size: NSSize? = nil
    ) -> NSImage {
        let attachmentImages = payload.attachmentURLs.prefix(3).map { url in
            if let preview = PreviewImageCache.shared.cachedFileThumbnail(
                url: url,
                scale: scale
            ) {
                return DragPreviewAttachment(image: preview, fillsTile: true)
            }
            return DragPreviewAttachment(
                image: NSWorkspace.shared.icon(forFile: url.path),
                fillsTile: false
            )
        }
        let renderer = ImageRenderer(
            content: ClipDragPreviewCard(
                payload: payload,
                attachmentImages: attachmentImages,
                size: size
            )
            .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = scale
        return renderer.nsImage ?? NSWorkspace.shared.icon(for: .data)
    }
}

private struct DragPreviewAttachment {
    let image: NSImage
    let fillsTile: Bool
}

private struct ClipDragPreviewCard: View {
    private enum Metrics {
        static let width: CGFloat = 280
        static let shadowAllowance: CGFloat = 12
    }

    let payload: ClipDragPayload
    let attachmentImages: [DragPreviewAttachment]
    let size: NSSize?

    @ViewBuilder
    var body: some View {
        if let size {
            previewBody
                .frame(width: size.width, height: size.height, alignment: .leading)
        } else {
            previewBody
                .frame(width: Metrics.width, alignment: .leading)
                .padding(Metrics.shadowAllowance)
        }
    }

    private var previewBody: some View {
        ClipCardBody(
            text: payload.text,
            isDone: payload.previewIsDone,
            hasAttachments: !attachmentImages.isEmpty,
            leadingInset: SnipSnapSpacing.cardContentInset
        ) {
            if !attachmentImages.isEmpty {
                HStack(spacing: SnipSnapSpacing.relatedContent) {
                    ForEach(Array(attachmentImages.enumerated()), id: \.offset) { _, item in
                        AttachmentPreviewArtwork(
                            image: item.image,
                            fillsTile: item.fillsTile
                        )
                    }
                }
            }
        }
        .panelContentCardSurface(isDone: payload.previewIsDone)
    }
}

@MainActor
final class ClipDragSourceController: NSObject, NSDraggingSource, NSGestureRecognizerDelegate {
    private final class WeakView {
        weak var value: NSView?

        init(_ value: NSView) {
            self.value = value
        }
    }

    private final class Region {
        weak var view: NSView?
        let payload: ClipDragPayload
        let onBegan: () -> Void
        let onMoved: (NSPoint) -> Void
        let onEnded: (ClipDragOutcome, NSPoint) -> Void

        init(
            view: NSView,
            payload: ClipDragPayload,
            onBegan: @escaping () -> Void,
            onMoved: @escaping (NSPoint) -> Void,
            onEnded: @escaping (ClipDragOutcome, NSPoint) -> Void
        ) {
            self.view = view
            self.payload = payload
            self.onBegan = onBegan
            self.onMoved = onMoved
            self.onEnded = onEnded
        }
    }

    private weak var hostView: NSView?
    private var regions: [UUID: Region] = [:]
    private var blockingViews: [UUID: WeakView] = [:]
    private var pendingRegion: Region?
    private var activeRegion: Region?
    private var activeExport: ClipDragExportPackage?
    private lazy var panRecognizer: NSPanGestureRecognizer = {
        let recognizer = ClipDragPanGestureRecognizer(
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

    func updateRegion(
        id: UUID,
        view: NSView?,
        payload: ClipDragPayload,
        onBegan: @escaping () -> Void,
        onMoved: @escaping (NSPoint) -> Void,
        onEnded: @escaping (ClipDragOutcome, NSPoint) -> Void
    ) {
        guard let view, view.window != nil else {
            regions.removeValue(forKey: id)
            return
        }
        regions[id] = Region(
            view: view,
            payload: payload,
            onBegan: onBegan,
            onMoved: onMoved,
            onEnded: onEnded
        )
    }

    func removeRegion(id: UUID) {
        regions.removeValue(forKey: id)
    }

    func updateBlockingView(id: UUID, view: NSView?) {
        guard let view, view.window != nil else {
            blockingViews.removeValue(forKey: id)
            return
        }
        blockingViews[id] = WeakView(view)
    }

    func removeBlockingView(id: UUID) {
        blockingViews.removeValue(forKey: id)
    }

    func payload(atWindowPoint point: NSPoint) -> ClipDragPayload? {
        region(atWindowPoint: point)?.payload
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
            return view.convert(view.bounds, to: nil).contains(point)
        }
        guard !isBlocked else { return nil }
        regions = regions.filter { $0.value.view?.window != nil }
        return regions.values.first { region in
            guard let view = region.view else { return false }
            return view.convert(view.bounds, to: nil).contains(point)
        }
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
        guard recognizer.state == .began,
              let hostView,
              let event = NSApp.currentEvent,
              let region = pendingRegion else { return }
        pendingRegion = nil
        let origin = hostView.convert(event.locationInWindow, from: nil)
        let scale = hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let colorScheme: ColorScheme = hostView.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua ? .dark : .light
        let export = ClipDragExportPackage(payload: region.payload)
        let sourceFrame = region.view.map { $0.convert($0.bounds, to: hostView) }
        region.onBegan()
        activeRegion = region
        activeExport = export
        let session = hostView.beginDraggingSession(
            with: export.draggingItems(
                at: origin,
                scale: scale,
                colorScheme: colorScheme,
                sourceFrame: sourceFrame
            ),
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
        context == .withinApplication ? .move : .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        movedTo screenPoint: NSPoint
    ) {
        activeRegion?.onMoved(windowPoint(from: screenPoint))
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let region = activeRegion
        activeRegion = nil
        activeExport = nil
        pendingRegion = nil
        region?.onEnded(
            ClipDragOutcome(operation: operation),
            windowPoint(from: screenPoint)
        )
    }

    private func windowPoint(from screenPoint: NSPoint) -> NSPoint {
        hostView?.window?.convertPoint(fromScreen: screenPoint) ?? screenPoint
    }
}

struct ClipDragBlockingRegion: NSViewRepresentable {
    let controller: ClipDragSourceController
    let id: UUID

    func makeNSView(context: Context) -> ClipDragBlockingRegionView {
        ClipDragBlockingRegionView(controller: controller, id: id)
    }

    func updateNSView(_ nsView: ClipDragBlockingRegionView, context: Context) {
        nsView.updateController()
    }

    static func dismantleNSView(_ nsView: ClipDragBlockingRegionView, coordinator: ()) {
        nsView.removeFromController()
    }
}

@MainActor
final class ClipDragBlockingRegionView: NSView {
    private let controller: ClipDragSourceController
    private let id: UUID

    init(controller: ClipDragSourceController, id: UUID) {
        self.controller = controller
        self.id = id
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateController()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateController()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func updateController() {
        controller.updateBlockingView(id: id, view: window == nil ? nil : self)
    }

    func removeFromController() {
        controller.removeBlockingView(id: id)
    }
}

struct ClipDragSourceRegion: NSViewRepresentable {
    let controller: ClipDragSourceController
    let id: UUID
    let payload: ClipDragPayload
    let onBegan: () -> Void
    let onMoved: (NSPoint) -> Void
    let onEnded: (ClipDragOutcome, NSPoint) -> Void

    func makeNSView(context: Context) -> ClipDragSourceRegionView {
        ClipDragSourceRegionView(
            controller: controller,
            id: id,
            payload: payload,
            onBegan: onBegan,
            onMoved: onMoved,
            onEnded: onEnded
        )
    }

    func updateNSView(_ nsView: ClipDragSourceRegionView, context: Context) {
        nsView.configure(
            payload: payload,
            onBegan: onBegan,
            onMoved: onMoved,
            onEnded: onEnded
        )
    }

    static func dismantleNSView(_ nsView: ClipDragSourceRegionView, coordinator: ()) {
        nsView.removeFromController()
    }
}

@MainActor
final class ClipDragSourceRegionView: NSView {
    private let controller: ClipDragSourceController
    private let id: UUID
    private var payload: ClipDragPayload
    private var onBegan: () -> Void
    private var onMoved: (NSPoint) -> Void
    private var onEnded: (ClipDragOutcome, NSPoint) -> Void

    init(
        controller: ClipDragSourceController,
        id: UUID,
        payload: ClipDragPayload,
        onBegan: @escaping () -> Void,
        onMoved: @escaping (NSPoint) -> Void,
        onEnded: @escaping (ClipDragOutcome, NSPoint) -> Void
    ) {
        self.controller = controller
        self.id = id
        self.payload = payload
        self.onBegan = onBegan
        self.onMoved = onMoved
        self.onEnded = onEnded
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        payload: ClipDragPayload,
        onBegan: @escaping () -> Void,
        onMoved: @escaping (NSPoint) -> Void,
        onEnded: @escaping (ClipDragOutcome, NSPoint) -> Void
    ) {
        self.payload = payload
        self.onBegan = onBegan
        self.onMoved = onMoved
        self.onEnded = onEnded
        updateController()
    }

    override func layout() {
        super.layout()
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
        controller.removeRegion(id: id)
    }

    private func updateController() {
        controller.updateRegion(
            id: id,
            view: window == nil ? nil : self,
            payload: payload,
            onBegan: onBegan,
            onMoved: onMoved,
            onEnded: onEnded
        )
    }
}
