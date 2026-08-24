enum InboxItemCommand {
    case copy
    case toggleDone
    case edit
    case editInNewWindow
    case merge
    case delete

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
struct InboxItemCommandDispatcher {
    let model: AppModel
    let coordinator: AppCoordinator

    func perform(_ command: InboxItemCommand) {
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
