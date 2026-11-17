import SnipSnapCore
import SwiftUI

struct WorkflowOptionsMenu: View {
    let model: IOSAppModel

    var body: some View {
        Menu("View options", systemImage: "line.3.horizontal.decrease") {
            Menu {
                Picker("Show", selection: completionFilter) {
                    ForEach(SnipCompletionFilter.allCases, id: \.self) { filter in
                        Text(filter.title)
                            .tag(filter)
                            .accessibilityIdentifier("filter-\(filter.rawValue)")
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
                if model.completionFilter == .all {
                    Divider()
                    Menu {
                        Picker("Done shown", selection: doneLimit) {
                            ForEach(SnipDoneLimit.allCases, id: \.self) { limit in
                                Text(limit.title).tag(limit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.inline)
                    } label: {
                        Text("Done shown")
                        Text(model.doneLimit.title)
                    }
                    .disabled(model.snipEditorDraft != nil)
                }
            } label: {
                Text("Show")
                Text(model.completionFilter.title)
            }
            .accessibilityIdentifier("workflow-show")

            Menu {
                Picker("Written by", selection: originFilter) {
                    ForEach(SnipOriginFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            } label: {
                Text("Written by")
                Text(model.originFilter.title)
            }
            .disabled(model.snipEditorDraft != nil)
            .accessibilityIdentifier("workflow-author")

            Menu {
                Picker("Sort", selection: sortMode) {
                    ForEach(SnipSortMode.allCases, id: \.self) { mode in
                        Text(mode.title)
                            .tag(mode)
                            .accessibilityIdentifier("sort-\(mode.rawValue)")
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            } label: {
                Text("Sort")
                Text(model.sortMode.title)
            }
            .accessibilityIdentifier("workflow-sort")
        }
        .menuOrder(.fixed)
        .menuActionDismissBehavior(.disabled)
        .accessibilityIdentifier("workflow-options")
    }

    private var doneLimit: Binding<SnipDoneLimit> {
        Binding(
            get: { model.doneLimit },
            set: { model.setDoneLimit($0) }
        )
    }

    private var completionFilter: Binding<SnipCompletionFilter> {
        Binding(
            get: { model.completionFilter },
            set: { model.completionFilter = $0 }
        )
    }

    private var originFilter: Binding<SnipOriginFilter> {
        Binding(
            get: { model.originFilter },
            set: {
                model.haptics.invalidatePendingFeedback()
                model.originFilter = $0
            }
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
    @State private var isPresented = false
    let model: IOSAppModel
    let copyShare: IOSCopyShareCoordinator
    let performAction: (@escaping @MainActor () async -> Bool) -> Void

    var body: some View {
        Button { isPresented.toggle() } label: {
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
        .glassMenu(isPresented: $isPresented, label: "Selection actions", identifier: "selection-actions-panel") { _ in
            VStack(spacing: 2) { actions }
                .padding(6)
                .buttonStyle(GlassMenuActionStyle())
        }
        .onChange(of: model.selectedSnipIDs) { _, ids in
            if ids.isEmpty { isPresented = false }
        }
    }

    @ViewBuilder
    private var actions: some View {
        CopyShareActions(
            snips: model.selectedSnips,
            model: model,
            coordinator: copyShare,
            identifierSuffix: "selection",
            includesCopy: false,
            beforeAction: { isPresented = false }
        )

        Divider()
        if model.selectedSnips.count >= 2 {
            Button("Merge Snips", systemImage: "arrow.triangle.merge") {
                isPresented = false
                performAction { await model.mergeSelection() }
            }
            .accessibilityIdentifier("merge-selection")
        }
        if model.selectedSnips.contains(where: { !$0.isDone }) {
            Button(SnipCompletionLanguage.menuActionTitle(isDone: false), systemImage: "checkmark") {
                isPresented = false
                let snips = model.selectedSnips
                performAction { await copyShare.markDone(snips: snips, model: model) }
            }
            .disabled(!model.selectedSnips.contains { !$0.isPinned })
            .accessibilityIdentifier("mark-selection-done")
        }

        if model.selectedSnips.contains(where: \.isDone) {
            Button(SnipCompletionLanguage.menuActionTitle(isDone: true), systemImage: "arrow.uturn.backward") {
                isPresented = false
                performAction { await model.setSelectionDone(false) }
            }
            .disabled(!model.selectedSnips.contains { !$0.isPinned })
            .accessibilityIdentifier("mark-selection-not-done")
        }
    }
}
