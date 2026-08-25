import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class SelectionAXNode: @unchecked Sendable {
    fileprivate let element: AXUIElement?

    init() {
        element = nil
    }

    fileprivate init(_ element: AXUIElement) {
        self.element = element
    }
}

struct SelectionAXContext: Equatable, Sendable {
    let windowTitle: String?
    let url: String?
}

protocol SelectionSourceAccess: Sendable {
    var isTrusted: Bool { get }
    func isProcessFrontmost(_ processID: pid_t) -> Bool
    func focusedElement(_ processID: pid_t) -> SelectionAXNode?
    func selectedText(_ node: SelectionAXNode) -> String?
    func parent(_ node: SelectionAXNode) -> SelectionAXNode?
    func context(_ node: SelectionAXNode) -> SelectionAXContext
    func postCopy(to processID: pid_t) -> Bool
}

protocol SelectionClipboardAccess: Sendable {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot?
    func copiedContent(maxImageCount: Int, maxTotalImageBytes: Int) -> SelectionCopiedContentRead?
    func restore(
        _ snapshot: PasteboardSnapshot,
        ifChangeCountIs expectedChangeCount: Int
    ) -> PasteboardRestoreOutcome
}

struct SelectionCopiedContentRead: Equatable, Sendable {
    let changeCount: Int
    let text: String?
    let attachments: [SelectionCaptureAttachment]
}

protocol SelectionCaptureClock: Sendable {
    var uptime: TimeInterval { get }
    func sleep(for interval: TimeInterval)
}

struct SelectionCaptureDependencies: Sendable {
    let source: any SelectionSourceAccess
    let clipboard: any SelectionClipboardAccess
    let clock: any SelectionCaptureClock

    static let live = SelectionCaptureDependencies(
        source: LiveSelectionSourceAccess(),
        clipboard: LiveSelectionClipboardAccess(),
        clock: SystemSelectionCaptureClock()
    )
}

private final class LiveSelectionSourceAccess: SelectionSourceAccess {
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func isProcessFrontmost(_ processID: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
    }

    func focusedElement(_ processID: pid_t) -> SelectionAXNode? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.35)
        guard let value = Self.attribute(
            kAXFocusedUIElementAttribute as CFString,
            from: application
        ), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return SelectionAXNode(unsafeDowncast(value, to: AXUIElement.self))
    }

    func selectedText(_ node: SelectionAXNode) -> String? {
        guard let element = node.element else { return nil }
        return Self.stringAttribute(
            kAXSelectedTextAttribute as CFString,
            from: element
        )
    }

    func parent(_ node: SelectionAXNode) -> SelectionAXNode? {
        guard let element = node.element,
              let value = Self.attribute(
                kAXParentAttribute as CFString,
                from: element
              ), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return SelectionAXNode(unsafeDowncast(value, to: AXUIElement.self))
    }

    func context(_ node: SelectionAXNode) -> SelectionAXContext {
        guard let element = node.element else {
            return SelectionAXContext(windowTitle: nil, url: nil)
        }
        var windowTitle: String?
        if let windowValue = Self.attribute(
            kAXWindowAttribute as CFString,
            from: element
        ), CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            let window = unsafeDowncast(windowValue, to: AXUIElement.self)
            windowTitle = Self.stringAttribute(
                kAXTitleAttribute as CFString,
                from: window
            )
        }

        var url: String?
        var current: AXUIElement? = element
        for _ in 0..<7 {
            guard let currentElement = current else { break }
            if url == nil {
                url = Self.stringAttribute(
                    kAXDocumentAttribute as CFString,
                    from: currentElement
                ) ?? Self.urlAttribute(from: currentElement)
            }
            guard let parentValue = Self.attribute(
                kAXParentAttribute as CFString,
                from: currentElement
            ), CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                break
            }
            current = unsafeDowncast(parentValue, to: AXUIElement.self)
        }
        return SelectionAXContext(windowTitle: windowTitle, url: url)
    }

    func postCopy(to processID: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_C),
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_C),
                keyDown: false
              ) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processID)
        keyUp.postToPid(processID)
        return true
    }

    private static func stringAttribute(
        _ name: CFString,
        from element: AXUIElement
    ) -> String? {
        attribute(name, from: element) as? String
    }

    private static func urlAttribute(from element: AXUIElement) -> String? {
        guard let value = attribute(kAXURLAttribute as CFString, from: element) else {
            return nil
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        return value as? String
    }

    private static func attribute(
        _ name: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        guard error == .success else { return nil }
        return value
    }
}

private final class LiveSelectionClipboardAccess: SelectionClipboardAccess {
    private var pasteboard: NSPasteboard { .general }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func snapshot() -> PasteboardSnapshot? {
        PasteboardSnapshotStore.snapshot(pasteboard)
    }

    func copiedContent(
        maxImageCount: Int,
        maxTotalImageBytes: Int
    ) -> SelectionCopiedContentRead? {
        let changeCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        var result: [SelectionCaptureAttachment] = []
        var remainingBytes = maxTotalImageBytes
        for item in pasteboard.pasteboardItems ?? [] where result.count < maxImageCount {
            let candidates: [(NSPasteboard.PasteboardType, String)] = [
                (.png, "Selection.png"),
                (.tiff, "Selection.tiff")
            ]
            guard let (type, name) = candidates.first(where: { item.types.contains($0.0) }),
                  let data = item.data(forType: type),
                  data.count <= remainingBytes else { continue }
            result.append(SelectionCaptureAttachment(fileName: name, data: data))
            remainingBytes -= data.count
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        return SelectionCopiedContentRead(
            changeCount: changeCount,
            text: text,
            attachments: result
        )
    }

    func restore(
        _ snapshot: PasteboardSnapshot,
        ifChangeCountIs expectedChangeCount: Int
    ) -> PasteboardRestoreOutcome {
        PasteboardSnapshotStore.restore(
            snapshot,
            to: pasteboard,
            ifChangeCountIs: expectedChangeCount
        )
    }
}

private struct SystemSelectionCaptureClock: SelectionCaptureClock {
    var uptime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(for interval: TimeInterval) {
        Thread.sleep(forTimeInterval: interval)
    }
}
