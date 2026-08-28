import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class SnipMarkdownPromiseDelegate: NSObject,
    NSFilePromiseProviderDelegate,
    @unchecked Sendable {
    private let contents: Data
    private let queue: OperationQueue

    init(markdown: String) {
        contents = Data(markdown.utf8)
        queue = OperationQueue()
        queue.name = "world.sree.snipsnap.snip-markdown-promise"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        "Snip Snap Snip.md"
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

struct SnipDragExportPackage {
    let payload: SnipDragPayload
    private let markdownPromiseDelegate: SnipMarkdownPromiseDelegate?
    private let markdownPromiseProvider: NSFilePromiseProvider?

    init(payload: SnipDragPayload) {
        self.payload = payload
        if !payload.text.isEmpty, !payload.attachmentURLs.isEmpty {
            let delegate = SnipMarkdownPromiseDelegate(markdown: Self.markdown(for: payload))
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

    static func markdown(for payload: SnipDragPayload) -> String {
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

    static let privateType = NSPasteboard.PasteboardType(UTType.snipSnapSnipDrag.identifier)

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
            content: SnipDragPreviewCard(
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

private struct SnipDragPreviewCard: View {
    private enum Metrics {
        static let width: CGFloat = 280
        static let shadowAllowance: CGFloat = 12
    }

    let payload: SnipDragPayload
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
        PanelContentCard(
            state: PanelContentCardState(isSubdued: payload.previewIsDone)
        ) {
            PanelContentCardMain {
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
            } content: {
                SnipCardText(
                    text: payload.text,
                    isDone: payload.previewIsDone
                )
            }
        }
    }
}

struct SnipDragSourceRegion: NSViewRepresentable {
    let controller: PanelDragSessionController
    let id: UUID
    let payload: SnipDragPayload
    let onBegan: () -> Void
    let onMoved: (NSPoint) -> Void
    let onEnded: (PanelDragSessionOutcome, NSPoint) -> Void

    func makeNSView(context: Context) -> SnipDragSourceRegionView {
        SnipDragSourceRegionView(
            controller: controller,
            id: id,
            payload: payload,
            onBegan: onBegan,
            onMoved: onMoved,
            onEnded: onEnded
        )
    }

    func updateNSView(_ nsView: SnipDragSourceRegionView, context: Context) {
        nsView.configure(
            payload: payload,
            onBegan: onBegan,
            onMoved: onMoved,
            onEnded: onEnded
        )
    }

    static func dismantleNSView(_ nsView: SnipDragSourceRegionView, coordinator: ()) {
        nsView.removeFromController()
    }
}

@MainActor
final class SnipDragSourceRegionView: PanelDragSourceRegionView {
    private struct RegionKey: Hashable {
        let id: UUID
    }

    init(
        controller: PanelDragSessionController,
        id: UUID,
        payload: SnipDragPayload,
        onBegan: @escaping () -> Void,
        onMoved: @escaping (NSPoint) -> Void,
        onEnded: @escaping (PanelDragSessionOutcome, NSPoint) -> Void
    ) {
        super.init(
            controller: controller,
            regionID: PanelDragSessionRegionID(RegionKey(id: id)),
            adapter: Self.makeAdapter(
                payload: payload,
                onBegan: onBegan,
                onMoved: onMoved,
                onEnded: onEnded
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        payload: SnipDragPayload,
        onBegan: @escaping () -> Void,
        onMoved: @escaping (NSPoint) -> Void,
        onEnded: @escaping (PanelDragSessionOutcome, NSPoint) -> Void
    ) {
        super.configure(
            adapter: Self.makeAdapter(
                payload: payload,
                onBegan: onBegan,
                onMoved: onMoved,
                onEnded: onEnded
            )
        )
    }

    private static func makeAdapter(
        payload: SnipDragPayload,
        onBegan: @escaping () -> Void,
        onMoved: @escaping (NSPoint) -> Void,
        onEnded: @escaping (PanelDragSessionOutcome, NSPoint) -> Void
    ) -> PanelDragSessionAdapter {
        PanelDragSessionAdapter(
            makeSession: { origin, scale, colorScheme, sourceFrame in
                let export = SnipDragExportPackage(payload: payload)
                return PanelDragSessionContent(
                    draggingItems: export.draggingItems(
                        at: origin,
                        scale: scale,
                        colorScheme: colorScheme,
                        sourceFrame: sourceFrame
                    ),
                    retainedExport: export
                )
            },
            sourceOperationMask: { context in
                context == .withinApplication ? .move : .copy
            },
            onBegan: onBegan,
            onMoved: onMoved,
            onEnded: onEnded
        )
    }
}
