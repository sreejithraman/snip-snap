import AppKit

/// Builds the pasteboard items for dragging a Clipboard Entry to another app.
///
/// The package copies the entry's stored forms rather than flattening them into
/// a Snip. Each stored clipboard item stays one drag item and keeps its place.
struct ClipboardEntryDragExportPackage: PanelDragExportPackage {
    let entry: ClipboardEntry

    static func sourceOperationMask(for _: NSDraggingContext) -> NSDragOperation {
        .copy
    }

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
}
