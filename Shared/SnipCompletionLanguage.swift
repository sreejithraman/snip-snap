import Foundation
import SnipSnapCore

enum SnipCompletionLanguage {
    static let done = String(localized: .snipCompletionDone)
    static let notDone = String(localized: .snipCompletionNotDone)
    static let toggle = String(localized: .snipCompletionToggle)

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
        case .all: String(localized: .all)
        case .done: SnipCompletionLanguage.done
        case .notDone: SnipCompletionLanguage.notDone
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .all: String(localized: .nothingCapturedYet)
        case .done: String(localized: .noDoneSnips)
        case .notDone: String(localized: .noUnfinishedSnips)
        }
    }
}

extension SnipList {
    var displayName: String {
        guard id == Self.inboxID, name == "Inbox" else { return name }
        return String(localized: .inbox)
    }
}

extension Snip {
    var displaySourceLabel: String {
        if let source {
            let label = source.conciseLabel
            if !label.isEmpty { return label }
        }
        return switch origin {
        case .selection: String(localized: .capturedSelection)
        case .quickEntry: String(localized: .snipSnapQuickEntry)
        case .clipboard: String(localized: .clipboard)
        case .share: String(localized: .shared)
        }
    }
}
