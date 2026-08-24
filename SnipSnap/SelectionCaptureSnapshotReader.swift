import Foundation

enum SelectionCaptureSnapshotAttempt {
    case success(PasteboardSnapshot)
    case unavailable
    case timedOut
}

final class SelectionCaptureSnapshotReader: @unchecked Sendable {
    private let clipboard: any SelectionClipboardAccess
    private let timeout: TimeInterval
    private let queue = DispatchQueue(
        label: "world.sree.snipsnap.clipboard-snapshot",
        qos: .userInitiated
    )
    private let state = SelectionCaptureSnapshotState()

    init(clipboard: any SelectionClipboardAccess, timeout: TimeInterval) {
        self.clipboard = clipboard
        self.timeout = timeout
    }

    func read() -> SelectionCaptureSnapshotAttempt {
        guard state.begin() else { return .timedOut }
        let result = SelectionCaptureSnapshotResult()
        let completed = DispatchSemaphore(value: 0)
        let clipboard = clipboard
        let state = state
        queue.async {
            result.store(clipboard.snapshot())
            state.end()
            completed.signal()
        }
        guard completed.wait(timeout: .now() + timeout) == .success else {
            return .timedOut
        }
        guard let snapshot = result.value else { return .unavailable }
        return .success(snapshot)
    }
}

private final class SelectionCaptureSnapshotState: @unchecked Sendable {
    private let lock = NSLock()
    private var isReading = false

    func begin() -> Bool {
        lock.withLock {
            guard !isReading else { return false }
            isReading = true
            return true
        }
    }

    func end() {
        lock.withLock { isReading = false }
    }
}

private final class SelectionCaptureSnapshotResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: PasteboardSnapshot?

    var value: PasteboardSnapshot? {
        lock.withLock { storedValue }
    }

    func store(_ value: PasteboardSnapshot?) {
        lock.withLock { storedValue = value }
    }
}
