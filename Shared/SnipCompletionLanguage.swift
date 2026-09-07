import Foundation
import SnipSnapCore

enum SnipCompletionLanguage {
    static let done = String(localized: .snipCompletionDone)
    static let notDone = String(localized: .snipCompletionNotDone)
    static let toggle = String(localized: .snipCompletionToggle)

    static func actionTitle(isDone: Bool) -> String {
        stateTitle(isDone: !isDone)
    }

    static func menuActionTitle(isDone: Bool) -> String {
        isDone ? String(localized: "Mark Not Done") : String(localized: "Mark Done")
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

extension SnipImportPreview {
    var localizedSummary: String {
        var parts = [totalSnipCount == 1
            ? String(localized: "1 snip")
            : String(localized: "\(totalSnipCount) snips")]
        if addedSnipCount > 0 {
            parts.append(String(localized: "\(addedSnipCount) new"))
        }
        if recoveredSnipCount > 0 {
            parts.append(recoveredSnipCount == 1
                ? String(localized: "1 recovered edit")
                : String(localized: "\(recoveredSnipCount) recovered edits"))
        }
        if addedListCount > 0 {
            parts.append(addedListCount == 1
                ? String(localized: "1 new list")
                : String(localized: "\(addedListCount) new lists"))
        }
        if addedAttachmentCount > 0 {
            parts.append(addedAttachmentCount == 1
                ? String(localized: "1 attachment")
                : String(localized: "\(addedAttachmentCount) attachments"))
        }
        return parts.joined(separator: ", ")
    }
}
