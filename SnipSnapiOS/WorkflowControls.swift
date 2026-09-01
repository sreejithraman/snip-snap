import SnipSnapCore
import SwiftUI

struct SemanticSwipeAction: View {
    let title: String
    let systemImage: String
    let tint: Color
    let role: ButtonRole?
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
        }
        .tint(tint)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct WorkflowOptionsMenu: View {
    let model: IOSAppModel

    var body: some View {
        Menu("View Options", systemImage: "line.3.horizontal.decrease.circle") {
            Section("Show") {
                Picker("Show", selection: completionFilter) {
                    ForEach(SnipCompletionFilter.allCases, id: \.self) { filter in
                        Text(filter.title)
                            .tag(filter)
                            .accessibilityIdentifier("filter-\(filter.rawValue)")
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            }
            Section("Sort") {
                Picker("Sort", selection: sortMode) {
                    ForEach(SnipSortMode.allCases, id: \.self) { mode in
                        Text(mode.title)
                            .tag(mode)
                            .accessibilityIdentifier("sort-\(mode.rawValue)")
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            }
        }
        .accessibilityIdentifier("workflow-options")
    }

    private var completionFilter: Binding<SnipCompletionFilter> {
        Binding(
            get: { model.completionFilter },
            set: { model.completionFilter = $0 }
        )
    }

    private var sortMode: Binding<SnipSortMode> {
        Binding(
            get: { model.sortMode },
            set: { model.sortMode = $0 }
        )
    }
}

struct SelectionActionsMenu: View {
    let model: IOSAppModel
    let copyShare: IOSCopyShareCoordinator
    let endSelection: () -> Void

    var body: some View {
        Menu("Selected", systemImage: "ellipsis.circle") {
            Button(SnipCompletionLanguage.done, systemImage: "checkmark.circle") {
                Task {
                    if await model.setSelectionDone(true) { endSelection() }
                }
            }
            .accessibilityIdentifier("mark-selection-done")

            Button(SnipCompletionLanguage.notDone, systemImage: "circle") {
                Task {
                    if await model.setSelectionDone(false) { endSelection() }
                }
            }
            .accessibilityIdentifier("mark-selection-not-done")

            Menu("Move", systemImage: "folder") {
                ForEach(model.lists.filter { $0.id != model.selectedListID }) { list in
                    Button(list.displayName) {
                        Task {
                            if await model.moveSelection(to: list.id) { endSelection() }
                        }
                    }
                    .accessibilityIdentifier("move-selection-to-\(list.name)")
                }
            }
            .accessibilityIdentifier("move-selection")

            if model.canReorderVisibleSnips {
                Divider()
                Button("Move Up", systemImage: "arrow.up") {
                    Task { _ = await model.moveSelection(by: -1) }
                }
                .accessibilityIdentifier("move-selection-up")
                Button("Move Down", systemImage: "arrow.down") {
                    Task { _ = await model.moveSelection(by: 1) }
                }
                .accessibilityIdentifier("move-selection-down")
            }

            Divider()
            CopyShareActions(
                snips: model.selectedVisibleSnips,
                model: model,
                coordinator: copyShare,
                identifierSuffix: "selection"
            )

            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task {
                    if await model.deleteSelection() { endSelection() }
                }
            }
            .accessibilityIdentifier("delete-selection")
        }
        .accessibilityIdentifier("selection-actions")
    }
}

private extension SnipSortMode {
    var title: String {
        switch self {
        case .chronological: String(localized: "Newest First")
        case .manual: String(localized: "Manual")
        }
    }
}
