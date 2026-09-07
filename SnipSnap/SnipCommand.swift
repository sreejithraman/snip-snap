import Foundation

enum SnipCommand {
    case copy
    case toggleDone
    case edit
    case merge
    case delete

    var title: String {
        switch self {
        case .copy:
            String(localized: "Copy")
        case .toggleDone:
            SnipCompletionLanguage.done
        case .edit:
            String(localized: "Edit")
        case .merge:
            String(localized: "Merge Snips")
        case .delete:
            String(localized: "Delete")
        }
    }

    func title(allSelectedAreDone: Bool) -> String {
        guard self == .toggleDone else { return title }
        return SnipCompletionLanguage.actionTitle(isDone: allSelectedAreDone)
    }

    func isAvailable(for selectionCount: Int) -> Bool {
        switch self {
        case .edit:
            selectionCount == 1
        case .merge:
            selectionCount >= 2
        case .copy, .toggleDone, .delete:
            selectionCount >= 1
        }
    }
}

@MainActor
struct SnipCommandDispatcher {
    let model: AppModel

    func perform(_ command: SnipCommand, on ids: Set<UUID>? = nil) {
        let targets = ids ?? model.selection
        Task { await performNow(command, on: targets) }
    }

    func performNow(_ command: SnipCommand, on ids: Set<UUID>) async {
        let snips = model.snips.filter { ids.contains($0.id) }
        guard command.isAvailable(for: snips.count) else { return }
        switch command {
        case .copy:
            _ = await model.placeOnClipboardNow(.snips(snips), feedback: .notify)
        case .toggleDone:
            await model.toggleDoneNow(ids: ids)
        case .edit:
            if let snip = snips.first { _ = await model.beginEditing(snip.id) }
        case .merge:
            await model.mergeSelectionNow(ids: ids)
        case .delete:
            await model.deleteSelectionNow(ids: ids)
        }
    }
}
