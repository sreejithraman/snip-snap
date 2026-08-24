import AppKit

struct PasteboardSnapshot: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        struct Value: Equatable, Sendable {
            let type: String
            let data: Data
        }

        let values: [Value]
    }

    let changeCount: Int
    let items: [Item]
}

enum PasteboardRestoreOutcome: Equatable, Sendable {
    case restored
    case skippedNewerChange
    case failed
}

enum PasteboardSnapshotStore {
    static func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        let changeCount = pasteboard.changeCount
        let items = pasteboard.pasteboardItems ?? []
        var capturedItems: [PasteboardSnapshot.Item] = []
        capturedItems.reserveCapacity(items.count)
        for item in items {
            var values: [PasteboardSnapshot.Item.Value] = []
            values.reserveCapacity(item.types.count)
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                values.append(.init(type: type.rawValue, data: data))
            }
            capturedItems.append(.init(values: values))
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        return PasteboardSnapshot(changeCount: changeCount, items: capturedItems)
    }

    static func restore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        ifChangeCountIs expectedChangeCount: Int
    ) -> PasteboardRestoreOutcome {
        guard pasteboard.changeCount == expectedChangeCount else {
            return .skippedNewerChange
        }
        var items: [NSPasteboardItem] = []
        items.reserveCapacity(snapshot.items.count)
        for capturedItem in snapshot.items {
            let item = NSPasteboardItem()
            for value in capturedItem.values {
                guard item.setData(
                    value.data,
                    forType: NSPasteboard.PasteboardType(value.type)
                ) else {
                    return .failed
                }
            }
            items.append(item)
        }
        pasteboard.clearContents()
        guard !items.isEmpty else { return .restored }
        return pasteboard.writeObjects(items) ? .restored : .failed
    }
}
