import AppKit
import SwiftUI

/// Builds the pasteboard items for dragging a Clipboard Entry to another app.
///
/// The package copies the entry's stored forms rather than flattening them into
/// a Snip. Each stored clipboard item stays one drag item and keeps its place.
struct ClipboardEntryDragExportPackage {
    let entry: ClipboardEntry

    var sourceOperationMask: NSDragOperation { .copy }

    func pasteboardWriters() -> [NSPasteboardWriting] {
        let needsPlainTextFallback = !entry.items.contains { item in
            item.representations.contains { representation in
                representation.type == NSPasteboard.PasteboardType.string.rawValue
            }
        }

        return entry.items.enumerated().map { index, payload in
            let item = NSPasteboardItem()
            for representation in payload.representations {
                item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.type)
                )
            }
            if index == 0, needsPlainTextFallback, !entry.text.isEmpty {
                item.setString(entry.text, forType: .string)
            }
            return item
        }
    }

    func draggingItems(preview: NSImage, sourceFrame: NSRect) -> [NSDraggingItem] {
        pasteboardWriters().enumerated().map { index, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            if index == 0 {
                item.setDraggingFrame(sourceFrame, contents: preview)
            } else {
                item.draggingFrame = NSRect(origin: sourceFrame.origin, size: NSSize(width: 1, height: 1))
                item.imageComponentsProvider = { [] }
            }
            return item
        }
    }
}

typealias ClipboardEntryDragPreviewRenderer = @MainActor (
    _ scale: CGFloat,
    _ colorScheme: ColorScheme,
    _ size: NSSize
) -> NSImage

struct ClipboardEntryDragSourceRegion: NSViewRepresentable {
    let controller: PanelDragSessionController
    let id: UUID
    let package: ClipboardEntryDragExportPackage
    let previewRenderer: ClipboardEntryDragPreviewRenderer

    func makeNSView(context: Context) -> ClipboardEntryDragSourceRegionView {
        ClipboardEntryDragSourceRegionView(
            controller: controller,
            id: id,
            package: package,
            previewRenderer: previewRenderer
        )
    }

    func updateNSView(_ nsView: ClipboardEntryDragSourceRegionView, context: Context) {
        nsView.configure(package: package, previewRenderer: previewRenderer)
    }

    static func dismantleNSView(
        _ nsView: ClipboardEntryDragSourceRegionView,
        coordinator: ()
    ) {
        nsView.removeFromController()
    }
}

@MainActor
final class ClipboardEntryDragSourceRegionView: PanelDragSourceRegionView {
    private struct RegionKey: Hashable {
        let id: UUID
    }

    init(
        controller: PanelDragSessionController,
        id: UUID,
        package: ClipboardEntryDragExportPackage,
        previewRenderer: @escaping ClipboardEntryDragPreviewRenderer
    ) {
        super.init(
            controller: controller,
            regionID: PanelDragSessionRegionID(RegionKey(id: id)),
            adapter: Self.makeAdapter(
                package: package,
                previewRenderer: previewRenderer
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        package: ClipboardEntryDragExportPackage,
        previewRenderer: @escaping ClipboardEntryDragPreviewRenderer
    ) {
        super.configure(
            adapter: Self.makeAdapter(
                package: package,
                previewRenderer: previewRenderer
            )
        )
    }

    private static func makeAdapter(
        package: ClipboardEntryDragExportPackage,
        previewRenderer: @escaping ClipboardEntryDragPreviewRenderer
    ) -> PanelDragSessionAdapter {
        PanelDragSessionAdapter(
            makeSession: { _, scale, colorScheme, sourceFrame in
                guard let sourceFrame else {
                    return PanelDragSessionContent(
                        draggingItems: [],
                        retainedExport: package
                    )
                }
                let preview = previewRenderer(scale, colorScheme, sourceFrame.size)
                return PanelDragSessionContent(
                    draggingItems: package.draggingItems(
                        preview: preview,
                        sourceFrame: sourceFrame
                    ),
                    retainedExport: package
                )
            },
            sourceOperationMask: { _ in package.sourceOperationMask },
            onBegan: {},
            onMoved: { _ in },
            onEnded: { _, _ in }
        )
    }
}
