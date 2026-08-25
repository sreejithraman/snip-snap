import AppKit
import Foundation
@testable import SnipSnap

final class SelectionCaptureFixture {
    enum CopyBehavior {
        case write(String)
        case writePayload(text: String?, items: [PasteboardSnapshot.Item])
        case writeWithoutText
        case timeout
    }

    private let source: TestSelectionSourceAccess
    private let clipboard: TestSelectionClipboardAccess
    private let clock = TestSelectionCaptureClock()

    init(
        axTexts: [String?],
        ancestorTexts: [String?] = [],
        copyBehaviors: [CopyBehavior] = [],
        originalItems: [PasteboardSnapshot.Item] = [
            .init(values: [
                .init(type: "public.utf8-plain-text", data: Data("Original".utf8))
            ])
        ],
        thirdPartyTextAfterRead: String? = nil,
        frontmostChecks: [Bool] = [],
        changeClipboardAfterSnapshot: Bool = false,
        restoreShouldFail: Bool = false,
        blockSnapshot: Bool = false
    ) {
        clipboard = TestSelectionClipboardAccess(
            originalItems: originalItems,
            thirdPartyTextAfterRead: thirdPartyTextAfterRead,
            changeAfterSnapshot: changeClipboardAfterSnapshot,
            restoreShouldFail: restoreShouldFail,
            blockSnapshot: blockSnapshot
        )
        source = TestSelectionSourceAccess(
            axTexts: axTexts,
            ancestorTexts: ancestorTexts,
            copyBehaviors: copyBehaviors,
            frontmostChecks: frontmostChecks,
            clipboard: clipboard
        )
    }

    var postedProcessIDs: [pid_t] {
        source.postedProcessIDs
    }

    var focusedReadCount: Int {
        source.focusedReadCount
    }

    var restoreCount: Int {
        clipboard.restoreCount
    }

    var restoreAttempts: Int {
        clipboard.restoreAttempts
    }

    var sleepCount: Int {
        clock.sleepCount
    }

    var snapshotDidStart: Bool {
        clipboard.snapshotDidStart
    }

    var currentPasteboardItems: [PasteboardSnapshot.Item] {
        clipboard.currentItems
    }

    var currentPasteboardString: String? {
        clipboard.currentString
    }

    func makeReader(
        snapshotTimeout: TimeInterval = 0.12,
        copyTimeout: TimeInterval = 0.25,
        pollInterval: TimeInterval = 0.01
    ) -> AccessibilitySelectionReader {
        AccessibilitySelectionReader(
            dependencies: SelectionCaptureDependencies(
                source: source,
                clipboard: clipboard,
                clock: clock
            ),
            snapshotTimeout: snapshotTimeout,
            copyTimeout: copyTimeout,
            pollInterval: pollInterval
        )
    }

    func releaseSnapshot() {
        clipboard.releaseSnapshot()
    }
}

private final class TestSelectionSourceAccess: SelectionSourceAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var axTexts: [String?]
    private var ancestorTexts: [String?]
    private var copyBehaviors: [SelectionCaptureFixture.CopyBehavior]
    private var nodeTexts: [ObjectIdentifier: String] = [:]
    private var nodeParents: [ObjectIdentifier: SelectionAXNode] = [:]
    private var processIDs: [pid_t] = []
    private var frontmostChecks: [Bool]
    private var focusedReadCountValue = 0
    private let clipboard: TestSelectionClipboardAccess

    init(
        axTexts: [String?],
        ancestorTexts: [String?],
        copyBehaviors: [SelectionCaptureFixture.CopyBehavior],
        frontmostChecks: [Bool],
        clipboard: TestSelectionClipboardAccess
    ) {
        self.axTexts = axTexts
        self.ancestorTexts = ancestorTexts
        self.copyBehaviors = copyBehaviors
        self.frontmostChecks = frontmostChecks
        self.clipboard = clipboard
    }

    var isTrusted: Bool { true }

    var postedProcessIDs: [pid_t] {
        lock.withLock { processIDs }
    }

    var focusedReadCount: Int {
        lock.withLock { focusedReadCountValue }
    }

    func isProcessFrontmost(_ processID: pid_t) -> Bool {
        lock.withLock {
            guard !frontmostChecks.isEmpty else { return true }
            return frontmostChecks.removeFirst()
        }
    }

    func focusedElement(_ processID: pid_t) -> SelectionAXNode? {
        lock.withLock {
            focusedReadCountValue += 1
            let focused = SelectionAXNode()
            if !axTexts.isEmpty, let text = axTexts.removeFirst() {
                nodeTexts[ObjectIdentifier(focused)] = text
            }
            if !ancestorTexts.isEmpty, let text = ancestorTexts.removeFirst() {
                let ancestor = SelectionAXNode()
                nodeTexts[ObjectIdentifier(ancestor)] = text
                nodeParents[ObjectIdentifier(focused)] = ancestor
            }
            return focused
        }
    }

    func selectedText(_ node: SelectionAXNode) -> String? {
        lock.withLock { nodeTexts[ObjectIdentifier(node)] }
    }

    func parent(_ node: SelectionAXNode) -> SelectionAXNode? {
        lock.withLock { nodeParents[ObjectIdentifier(node)] }
    }

    func context(_ node: SelectionAXNode) -> SelectionAXContext {
        SelectionAXContext(
            windowTitle: "Work",
            url: "https://example.com/work"
        )
    }

    func postCopy(to processID: pid_t) -> Bool {
        let behavior = lock.withLock { () -> SelectionCaptureFixture.CopyBehavior? in
            processIDs.append(processID)
            guard !copyBehaviors.isEmpty else { return nil }
            return copyBehaviors.removeFirst()
        }
        guard let behavior else { return false }
        clipboard.apply(behavior)
        return true
    }
}

private final class TestSelectionClipboardAccess: SelectionClipboardAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PasteboardSnapshot.Item]
    private var stringValue: String?
    private var changeCountValue = 10
    private var restoreCountValue = 0
    private var restoreAttemptsValue = 0
    private var thirdPartyTextAfterRead: String?
    private var changeAfterSnapshot: Bool
    private let restoreShouldFail: Bool
    private let blockSnapshot: Bool
    private let snapshotStarted = DispatchSemaphore(value: 0)
    private let snapshotRelease = DispatchSemaphore(value: 0)

    init(
        originalItems: [PasteboardSnapshot.Item],
        thirdPartyTextAfterRead: String?,
        changeAfterSnapshot: Bool,
        restoreShouldFail: Bool,
        blockSnapshot: Bool
    ) {
        items = originalItems
        self.thirdPartyTextAfterRead = thirdPartyTextAfterRead
        self.changeAfterSnapshot = changeAfterSnapshot
        self.restoreShouldFail = restoreShouldFail
        self.blockSnapshot = blockSnapshot
    }

    var changeCount: Int {
        lock.withLock { changeCountValue }
    }

    var restoreCount: Int {
        lock.withLock { restoreCountValue }
    }

    var restoreAttempts: Int {
        lock.withLock { restoreAttemptsValue }
    }

    var snapshotDidStart: Bool {
        snapshotStarted.wait(timeout: .now()) == .success
    }

    var currentItems: [PasteboardSnapshot.Item] {
        lock.withLock { items }
    }

    var currentString: String? {
        lock.withLock { stringValue }
    }

    func snapshot() -> PasteboardSnapshot? {
        if blockSnapshot {
            snapshotStarted.signal()
            snapshotRelease.wait()
        }
        return lock.withLock {
            let snapshot = PasteboardSnapshot(
                changeCount: changeCountValue,
                items: items
            )
            if changeAfterSnapshot {
                changeAfterSnapshot = false
                changeCountValue += 1
            }
            return snapshot
        }
    }

    func copiedContent(
        maxImageCount: Int,
        maxTotalImageBytes: Int
    ) -> SelectionCopiedContentRead? {
        lock.withLock {
            let readChangeCount = changeCountValue
            let copiedText = stringValue
            var result: [SelectionCaptureAttachment] = []
            var remaining = maxTotalImageBytes
            for item in items where result.count < maxImageCount {
                guard let value = item.values.first(where: {
                    $0.type == NSPasteboard.PasteboardType.png.rawValue
                        || $0.type == NSPasteboard.PasteboardType.tiff.rawValue
                }), value.data.count <= remaining else { continue }
                let name = value.type == NSPasteboard.PasteboardType.tiff.rawValue
                    ? "Selection.tiff" : "Selection.png"
                result.append(.init(fileName: name, data: value.data))
                remaining -= value.data.count
            }
            if let thirdPartyTextAfterRead {
                self.thirdPartyTextAfterRead = nil
                changeCountValue += 1
                stringValue = thirdPartyTextAfterRead
                items = [
                    .init(values: [
                        .init(
                            type: "public.utf8-plain-text",
                            data: Data(thirdPartyTextAfterRead.utf8)
                        )
                    ])
                ]
            }
            guard changeCountValue == readChangeCount else { return nil }
            return SelectionCopiedContentRead(
                changeCount: readChangeCount,
                text: copiedText,
                attachments: result
            )
        }
    }

    func restore(
        _ snapshot: PasteboardSnapshot,
        ifChangeCountIs expectedChangeCount: Int
    ) -> PasteboardRestoreOutcome {
        lock.withLock {
            restoreAttemptsValue += 1
            guard changeCountValue == expectedChangeCount else {
                return .skippedNewerChange
            }
            guard !restoreShouldFail else { return .failed }
            changeCountValue += 1
            items = snapshot.items
            stringValue = nil
            restoreCountValue += 1
            return .restored
        }
    }

    func apply(_ behavior: SelectionCaptureFixture.CopyBehavior) {
        lock.withLock {
            switch behavior {
            case .write(let text):
                changeCountValue += 1
                stringValue = text
                items = [
                    .init(values: [
                        .init(type: "public.utf8-plain-text", data: Data(text.utf8))
                    ])
                ]
            case .writePayload(let text, let copiedItems):
                changeCountValue += 1
                stringValue = text
                items = copiedItems
            case .writeWithoutText:
                changeCountValue += 1
                stringValue = nil
                items = [
                    .init(values: [
                        .init(type: "com.example.no-text", data: Data([1, 2, 3]))
                    ])
                ]
            case .timeout:
                break
            }
        }
    }

    func releaseSnapshot() {
        snapshotRelease.signal()
    }
}

private final class TestSelectionCaptureClock: SelectionCaptureClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var sleepCountValue = 0

    var uptime: TimeInterval {
        lock.withLock { time }
    }

    var sleepCount: Int {
        lock.withLock { sleepCountValue }
    }

    func sleep(for interval: TimeInterval) {
        lock.withLock {
            sleepCountValue += 1
            time += interval
        }
    }
}
