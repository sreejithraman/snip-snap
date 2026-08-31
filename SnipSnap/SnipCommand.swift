enum SnipCommand {
    case copy
    case toggleDone
    case edit
    case editInNewWindow
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
        case .editInNewWindow:
            String(localized: "Edit in New Window")
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
        case .edit, .editInNewWindow:
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
    let coordinator: AppCoordinator

    func perform(_ command: SnipCommand) {
        switch command {
        case .copy:
            _ = model.copySelection()
        case .toggleDone:
            model.toggleDoneSelection()
        case .edit:
            model.beginEditingSelection()
        case .editInNewWindow:
            coordinator.editSelectionInNewWindow()
        case .merge:
            model.mergeSelection()
        case .delete:
            model.deleteSelection()
        }
    }
}
