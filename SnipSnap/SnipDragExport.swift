import AppKit
import SnipSnapCore
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

struct SnipDragExportPackage: PanelDragExportPackage {
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

    static func sourceOperationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
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

    static let privateType = NSPasteboard.PasteboardType(UTType.snipSnapSnipDrag.identifier)

}

enum SnipDragPreview {
    @MainActor
    static func image(
        for payload: SnipDragPayload,
        in context: PanelDragSourceContext
    ) -> NSImage {
        let attachmentImages = payload.attachmentURLs.prefix(3).map { url in
            if let preview = PreviewImageCache.shared.cachedFileThumbnail(
                url: url,
                scale: context.scale
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
                size: context.sourceFrame.size
            )
            .environment(\.colorScheme, context.colorScheme)
        )
        renderer.scale = context.scale
        return renderer.nsImage ?? NSWorkspace.shared.icon(for: .data)
    }
}

private struct DragPreviewAttachment {
    let image: NSImage
    let fillsTile: Bool
}

private struct SnipDragPreviewCard: View {
    let payload: SnipDragPayload
    let attachmentImages: [DragPreviewAttachment]
    let size: NSSize

    var body: some View {
        previewBody
            .frame(width: size.width, height: size.height, alignment: .leading)
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
