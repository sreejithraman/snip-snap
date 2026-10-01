import SnipSnapCore
import SwiftUI

struct WorkflowOptionsMenu: View {
    let model: IOSAppModel
    var beginReordering: (() -> Void)? = nil

    var body: some View {
        Menu("View options", systemImage: "line.3.horizontal.decrease") {
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
            if let beginReordering {
                Divider()
                Button("Reorder Snips", systemImage: "arrow.up.arrow.down", action: beginReordering)
                    .disabled(!model.canReorderVisibleSnips || model.visibleSnips.count < 2)
                    .accessibilityIdentifier("reorder-snips")
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
            set: {
                model.haptics.invalidatePendingFeedback()
                model.sortMode = $0
            }
        )
    }
}

struct SelectionActionsMenu: View {
    let model: IOSAppModel
    let copyShare: IOSCopyShareCoordinator
    let performAction: (@escaping @MainActor () async -> Bool) -> Void

    var body: some View {
        Menu {
            actions
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .frame(minWidth: 30, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(SnipSnapTheme.actionAccent)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Selection actions")
        .accessibilityIdentifier("selection-actions")
    }

    @ViewBuilder
    private var actions: some View {
        CopyShareActions(
            snips: model.selectedSnips,
            model: model,
            coordinator: copyShare,
            identifierSuffix: "selection",
            includesCopy: false
        )

        Divider()
        if model.selectedSnips.count >= 2 {
            Button("Merge Snips", systemImage: "arrow.triangle.merge") {
                performAction { await model.mergeSelection() }
            }
            .accessibilityIdentifier("merge-selection")
        }
        if model.selectedSnips.contains(where: { !$0.isDone }) {
            Button(SnipCompletionLanguage.menuActionTitle(isDone: false), systemImage: "checkmark") {
                let snips = model.selectedSnips
                performAction { await copyShare.markDone(snips: snips, model: model) }
            }
            .disabled(!model.selectedSnips.contains { !$0.isPinned })
            .accessibilityIdentifier("mark-selection-done")
        }

        if model.selectedSnips.contains(where: \.isDone) {
            Button(SnipCompletionLanguage.menuActionTitle(isDone: true), systemImage: "arrow.uturn.backward") {
                performAction { await model.setSelectionDone(false) }
            }
            .disabled(!model.selectedSnips.contains { !$0.isPinned })
            .accessibilityIdentifier("mark-selection-not-done")
        }
    }
}

private extension SnipSortMode {
    var title: String {
        switch self {
        case .chronological: String(localized: "Newest first")
        case .manual: String(localized: "Manual")
        }
    }
}
