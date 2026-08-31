import AppKit
import SnipSnapCore
import Foundation

enum SelectionCaptureFailure: Error, Equatable, LocalizedError, Sendable {
    case accessibilityPermissionRequired
    case sourceUnavailable
    case selectionUnavailable
    case noSelection
    case copyTimedOut
    case clipboardUnavailable
    case clipboardSnapshotTimedOut
    case clipboardChanged
    case clipboardRestoreFailed
    case sourceChanged
    case duplicateSelection

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            String(localized: .allowAccessibilityAccessToCaptureTheSelection)
        case .sourceUnavailable:
            String(localized: .snipSnapCouldNotReachTheFrontmostApp)
        case .selectionUnavailable:
            String(localized: .snipSnapCouldNotCopyTheSelectionFromThisApp)
        case .noSelection:
            String(localized: .selectTextOrAnImageThenTryAgain)
        case .copyTimedOut:
            String(localized: .snipSnapTimedOutWhileCopyingTheSelection)
        case .clipboardUnavailable:
            String(localized: .snipSnapCouldNotPreserveTheClipboard)
        case .clipboardSnapshotTimedOut:
            String(localized: .snipSnapTimedOutWhileReadingTheClipboardSnipSnapChangedNothing)
        case .clipboardChanged:
            String(localized: .theClipboardChangedBeforeSnipSnapCouldCopy)
        case .clipboardRestoreFailed:
            String(localized: .snipSnapCouldNotRestoreTheClipboardSoItDidNotSaveTheCapture)
        case .sourceChanged:
            String(localized: .theSourceAppIsNoLongerActive)
        case .duplicateSelection:
            String(localized: .alreadyCaptured)
        }
    }
}

struct SelectionCaptureAttachment: Equatable, Sendable {
    let fileName: String
    let data: Data
}

struct SelectionCapture: Equatable, Sendable {
    let content: String
    let source: SnipSource
    let attachments: [SelectionCaptureAttachment]

    init(
        content: String,
        source: SnipSource,
        attachments: [SelectionCaptureAttachment] = []
    ) {
        self.content = content
        self.source = source
        self.attachments = attachments
    }
}

final class AccessibilitySelectionReader: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "world.sree.snipsnap.selection-capture",
        qos: .userInitiated
    )
    private let access: any SelectionSourceAccess
    private let clipboard: any SelectionClipboardAccess
    private let clock: any SelectionCaptureClock
    private let snapshotReader: SelectionCaptureSnapshotReader
    private let ancestorLimit: Int
    private let copyTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let duplicateInterval: TimeInterval
    private var lastCapture: (fingerprint: CaptureFingerprint, time: TimeInterval)?

    private struct CaptureFingerprint: Equatable {
        let processID: pid_t
        let content: String
        let applicationName: String
        let windowTitle: String?
        let url: String?
        let attachments: [SelectionCaptureAttachment]
    }

    init(
        dependencies: SelectionCaptureDependencies = .live,
        ancestorLimit: Int = 8,
        snapshotTimeout: TimeInterval = 0.12,
        copyTimeout: TimeInterval = 0.25,
        pollInterval: TimeInterval = 0.01,
        duplicateInterval: TimeInterval = 0.75
    ) {
        access = dependencies.source
        clipboard = dependencies.clipboard
        clock = dependencies.clock
        snapshotReader = SelectionCaptureSnapshotReader(
            clipboard: dependencies.clipboard,
            timeout: max(0, snapshotTimeout)
        )
        self.ancestorLimit = max(1, ancestorLimit)
        self.copyTimeout = max(0, copyTimeout)
        self.pollInterval = max(0, pollInterval)
        self.duplicateInterval = max(0, duplicateInterval)
    }

    var isTrusted: Bool {
        access.isTrusted
    }

    func capture(
        processID: pid_t,
        applicationName: String,
        completion: @escaping @Sendable (Result<SelectionCapture, SelectionCaptureFailure>) -> Void
    ) {
        guard isTrusted else {
            completion(.failure(.accessibilityPermissionRequired))
            return
        }

        queue.async { [self] in
            guard access.isProcessFrontmost(processID) else {
                completion(.failure(.sourceChanged))
                return
            }
            let focusedElement = access.focusedElement(processID)
            let context = focusedElement.map(access.context)
                ?? SelectionAXContext(windowTitle: nil, url: nil)

            var selectedText: String?
            var current = focusedElement
            for _ in 0..<ancestorLimit {
                guard let element = current else { break }
                if let text = access.selectedText(element), !Self.isBlank(text) {
                    selectedText = text
                    break
                }
                current = access.parent(element)
            }

            captureWithCopyFallback(
                processID: processID,
                applicationName: applicationName,
                context: context,
                fallbackText: selectedText,
                completion: completion
            )
        }
    }

    private func captureWithCopyFallback(
        processID: pid_t,
        applicationName: String,
        context: SelectionAXContext,
        fallbackText: String?,
        completion: @escaping @Sendable (Result<SelectionCapture, SelectionCaptureFailure>) -> Void
    ) {
        let snapshot: PasteboardSnapshot
        switch snapshotReader.read() {
        case .success(let value):
            snapshot = value
        case .unavailable:
            finishFallback(
                fallbackText,
                failure: .clipboardUnavailable,
                processID: processID,
                applicationName: applicationName,
                context: context,
                completion: completion
            )
            return
        case .timedOut:
            finishFallback(
                fallbackText,
                failure: .clipboardSnapshotTimedOut,
                processID: processID,
                applicationName: applicationName,
                context: context,
                completion: completion
            )
            return
        }
        guard access.isProcessFrontmost(processID) else {
            completion(.failure(.sourceChanged))
            return
        }
        guard clipboard.changeCount == snapshot.changeCount else {
            finishFallback(
                fallbackText,
                failure: .clipboardChanged,
                processID: processID,
                applicationName: applicationName,
                context: context,
                completion: completion
            )
            return
        }
        guard access.postCopy(to: processID) else {
            finishFallback(
                fallbackText,
                failure: .selectionUnavailable,
                processID: processID,
                applicationName: applicationName,
                context: context,
                completion: completion
            )
            return
        }

        let deadline = clock.uptime + copyTimeout
        var copiedChangeCount: Int?
        var copiedText: String?
        var copiedAttachments: [SelectionCaptureAttachment] = []
        repeat {
            let changeCount = clipboard.changeCount
            if changeCount != snapshot.changeCount {
                guard let copiedContent = clipboard.copiedContent(
                    maxImageCount: 10,
                    maxTotalImageBytes: 32 * 1_024 * 1_024
                ), copiedContent.changeCount == changeCount else {
                    finishFallback(
                        fallbackText,
                        failure: .clipboardChanged,
                        processID: processID,
                        applicationName: applicationName,
                        context: context,
                        completion: completion
                    )
                    return
                }
                copiedChangeCount = copiedContent.changeCount
                copiedText = copiedContent.text
                copiedAttachments = copiedContent.attachments
                break
            }
            guard clock.uptime < deadline else { break }
            clock.sleep(for: pollInterval)
        } while true

        guard let copiedChangeCount else {
            finishFallback(
                fallbackText,
                failure: .copyTimedOut,
                processID: processID,
                applicationName: applicationName,
                context: context,
                completion: completion
            )
            return
        }

        let restoreOutcome = clipboard.restore(
            snapshot,
            ifChangeCountIs: copiedChangeCount
        )
        guard restoreOutcome != .failed else {
            completion(.failure(.clipboardRestoreFailed))
            return
        }
        let capturedText = copiedText ?? fallbackText ?? ""
        guard !Self.isBlank(capturedText) || !copiedAttachments.isEmpty else {
            completion(.failure(.noSelection))
            return
        }
        finish(
            text: capturedText,
            processID: processID,
            applicationName: applicationName,
            context: context,
            attachments: copiedAttachments,
            completion: completion
        )
    }

    private func finishFallback(
        _ text: String?,
        failure: SelectionCaptureFailure,
        processID: pid_t,
        applicationName: String,
        context: SelectionAXContext,
        completion: @escaping @Sendable (Result<SelectionCapture, SelectionCaptureFailure>) -> Void
    ) {
        guard let text, !Self.isBlank(text) else {
            completion(.failure(failure))
            return
        }
        finish(
            text: text,
            processID: processID,
            applicationName: applicationName,
            context: context,
            completion: completion
        )
    }

    private func finish(
        text: String,
        processID: pid_t,
        applicationName: String,
        context: SelectionAXContext,
        attachments: [SelectionCaptureAttachment] = [],
        completion: @escaping @Sendable (Result<SelectionCapture, SelectionCaptureFailure>) -> Void
    ) {
        let fingerprint = CaptureFingerprint(
            processID: processID,
            content: text,
            applicationName: applicationName,
            windowTitle: context.windowTitle,
            url: context.url,
            attachments: attachments
        )
        let now = clock.uptime
        if let lastCapture,
           lastCapture.fingerprint == fingerprint,
           now - lastCapture.time <= duplicateInterval {
            completion(.failure(.duplicateSelection))
            return
        }
        lastCapture = (fingerprint, now)
        let source = SnipSource(
            applicationName: applicationName,
            windowTitle: context.windowTitle,
            url: context.url
        )
        completion(.success(SelectionCapture(
            content: text,
            source: source,
            attachments: attachments
        )))
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
