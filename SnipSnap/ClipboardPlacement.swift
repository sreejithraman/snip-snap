import AppKit
import Foundation
import SnipSnapCore

enum ClipboardPlacement: Equatable {
    case snips([Snip])
    case clipboardEntry(ClipboardEntry)
}

enum ClipboardPlacementFeedback: Equatable {
    case notify
    case silent
}

struct ClipboardCopyPulse: Equatable {
    let entryID: UUID
    let token: UUID

    init(entryID: UUID, token: UUID = UUID()) {
        self.entryID = entryID
        self.token = token
    }
}

/// The newest clipboard write from snips. Any newer placement supersedes it.
@MainActor
final class ClipboardWriteSequence {
    struct Token: Equatable, Sendable {
        private let id: UUID

        fileprivate init() {
            id = UUID()
        }
    }

    private enum Phase {
        case none
        case writing(Token, Task<Bool, Never>)
        /// The newest write ended; its Copy and Done can still mark Done.
        case finished(Token)
    }

    private var phase = Phase.none

    var pendingTask: Task<Bool, Never>? {
        guard case .writing(_, let task) = phase else { return nil }
        return task
    }

    /// Cancels any running write, then starts the next one with a fresh token.
    func begin(
        _ start: (Token) -> Task<Bool, Never>
    ) -> (token: Token, task: Task<Bool, Never>) {
        supersede()
        let token = Token()
        let task = start(token)
        phase = .writing(token, task)
        return (token, task)
    }

    func finish(_ token: Token) {
        guard case .writing(let current, _) = phase, current == token else { return }
        phase = .finished(token)
    }

    func supersede() {
        if case .writing(_, let task) = phase { task.cancel() }
        phase = .none
    }

    func isCurrent(_ token: Token) -> Bool {
        switch phase {
        case .none:
            return false
        case .writing(let current, _), .finished(let current):
            return current == token
        }
    }
}

@MainActor
struct SnipClipboardWrite {
    let token: ClipboardWriteSequence.Token
    let pasteboard: NSPasteboard
    let expectedChangeCount: Int

    var leavesPasteboardUnchanged: Bool {
        pasteboard.changeCount == expectedChangeCount
    }
}
