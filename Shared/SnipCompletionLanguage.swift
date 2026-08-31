import Foundation
import SnipSnapCore

enum SnipCompletionLanguage {
    static let done = String(
        localized: "snip.completion.done",
        defaultValue: "Done",
        comment: "Action or state for a snip that is finished."
    )
    static let notDone = String(
        localized: "snip.completion.notDone",
        defaultValue: "Not Done",
        comment: "Action or state for a snip that is not finished."
    )
    static let toggle = String(
        localized: "snip.completion.toggle",
        defaultValue: "Done or Not Done",
        comment: "Command that toggles a snip's completion state."
    )

    static func actionTitle(isDone: Bool) -> String {
        stateTitle(isDone: !isDone)
    }

    static func stateTitle(isDone: Bool) -> String {
        isDone ? done : notDone
    }
}

extension SnipCompletionFilter {
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .done: SnipCompletionLanguage.done
        case .notDone: SnipCompletionLanguage.notDone
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .all: String(localized: "Nothing captured yet")
        case .done: String(localized: "No done snips")
        case .notDone: String(localized: "No unfinished snips")
        }
    }
}

extension SnipList {
    var displayName: String {
        guard id == Self.inboxID, name == "Inbox" else { return name }
        return String(localized: "Inbox")
    }
}

extension Snip {
    var displaySourceLabel: String {
        if let source {
            let label = source.conciseLabel
            if !label.isEmpty { return label }
        }
        return switch origin {
        case .selection: String(localized: "Captured Selection")
        case .quickEntry: String(localized: "Snip Snap — Quick Entry")
        case .clipboard: String(localized: "Clipboard")
        case .share: String(localized: "Shared")
        }
    }
}
