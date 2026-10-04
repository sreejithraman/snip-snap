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
