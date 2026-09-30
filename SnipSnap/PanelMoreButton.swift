import SwiftUI
import SnipSnapCore

struct PanelMoreButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var accessibilityPermissions: AccessibilityPermissionController
    @FocusState.Binding var focusedTarget: PanelFocusTarget?
    let moveSelectionToNewList: () -> Void
    let selectAllVisible: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            actions
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .panelStandaloneActionControl()
                .frame(
                    width: PanelControlMetrics.floatingRowHeight,
                    height: PanelControlMetrics.floatingRowHeight
                )
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help(moreLabel)
        .accessibilityLabel(moreLabel)
        .accessibilityIdentifier("panel-more")
    }

    @ViewBuilder
    private var actions: some View {
        if !model.isShowingClipboard || model.isSearchExpanded {
            Button("Select All") {
                selectAllVisible()
            }
            .disabled(model.editingID != nil || !model.canSelectVisibleSnips)

            Button("Move to New List…") {
                focusedTarget = nil
                moveSelectionToNewList()
            }
            .disabled(model.editingID != nil || !model.canSelectVisibleSnips || model.selection.isEmpty)

            Divider()
        }

        if let title = accessibilityPermissions.menuActionTitle {
            Button(title) {
                accessibilityPermissions.performMenuAction()
            }
        }

        Button("Settings…") {
            openSettings()
        }
    }

    private var developmentBuild: DevelopmentBuildIdentity? {
        DevelopmentBuildIdentity.current
    }

    private var moreLabel: String {
        guard let developmentBuild else { return String(localized: "More") }
        return String(localized: "More, development build \(developmentBuild.slot)")
    }

}

struct PanelViewOptionsButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            if model.isShowingClipboard {
                Section("Show") {
                    Picker("Show", selection: $model.clipboardViewOptions.onlyPinned) {
                        Text("All").tag(false)
                        Text("Pinned").tag(true)
                    }
                    .pickerStyle(.inline)
                }
                Section("Sort") {
                    Picker("Sort", selection: $model.clipboardViewOptions.newestFirst) {
                        Text("Newest first").tag(true)
                        Text("Oldest first").tag(false)
                    }
                    .pickerStyle(.inline)
                }
            } else {
                Section("Show") {
                    Picker("Show", selection: completionFilterBinding) {
                        Text("All").tag(SnipCompletionFilter.all)
                        Text(SnipCompletionLanguage.done).tag(SnipCompletionFilter.done)
                        Text(SnipCompletionLanguage.notDone).tag(SnipCompletionFilter.notDone)
                    }
                    .pickerStyle(.inline)
                }
                Section("Sort") {
                    Picker("Sort", selection: sortModeBinding) {
                        Text("Newest first").tag(SnipSortMode.chronological)
                        Text("Manual").tag(SnipSortMode.manual)
                    }
                    .pickerStyle(.inline)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .semibold))
                .panelStandaloneActionControl()
                .frame(
                    width: PanelControlMetrics.floatingRowHeight,
                    height: PanelControlMetrics.floatingRowHeight
                )
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(model.editingID != nil)
        .help("View options")
        .accessibilityLabel("View options")
        .accessibilityIdentifier("workflow-options")
    }

    private var sortModeBinding: Binding<SnipSortMode> {
        Binding(
            get: { model.sortMode },
            set: { model.setSortMode($0) }
        )
    }

    private var completionFilterBinding: Binding<SnipCompletionFilter> {
        Binding(
            get: { model.completionFilter },
            set: { model.completionFilter = $0 }
        )
    }
}
