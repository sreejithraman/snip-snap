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
        Picker("Show: \(completionFilterTitle)", selection: $model.completionFilter) {
            Text("All").tag(SnipCompletionFilter.all)
            Text(SnipCompletionLanguage.done).tag(SnipCompletionFilter.done)
            Text(SnipCompletionLanguage.notDone).tag(SnipCompletionFilter.notDone)
        }

        Picker("Sort: \(sortModeTitle)", selection: sortModeBinding) {
            Text("Newest First").tag(SnipSortMode.chronological)
            Text("Manual").tag(SnipSortMode.manual)
        }

        Divider()

        Button("Select All") {
            selectAllVisible()
        }
        .disabled(model.filteredSnips.isEmpty)

        Button("Move to New List…") {
            focusedTarget = nil
            moveSelectionToNewList()
        }
        .disabled(model.selection.isEmpty)

        Divider()

        Picker("Appearance", selection: appearanceBinding) {
            Label("System", systemImage: "circle.lefthalf.filled")
                .tag(AppAppearance.system)
            Label("Light", systemImage: "sun.max")
                .tag(AppAppearance.light)
            Label("Dark", systemImage: "moon")
                .tag(AppAppearance.dark)
        }

        Button(accessibilityPermissions.menuActionTitle) {
            accessibilityPermissions.performMenuAction()
        }

        Button("Keyboard Shortcuts…") {
            openSettings()
        }
    }

    private var sortModeBinding: Binding<SnipSortMode> {
        Binding(
            get: { model.sortMode },
            set: { model.setSortMode($0) }
        )
    }

    private var developmentBuild: DevelopmentBuildIdentity? {
        DevelopmentBuildIdentity.current
    }

    private var moreLabel: String {
        guard let developmentBuild else { return String(localized: "More") }
        return String(localized: "More, development build \(developmentBuild.slot)")
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { model.appearance },
            set: { model.setAppearance($0) }
        )
    }

    private var completionFilterTitle: String {
        model.completionFilter.title
    }

    private var sortModeTitle: String {
        switch model.sortMode {
        case .chronological:
            String(localized: "Newest First")
        case .manual:
            String(localized: "Manual")
        }
    }
}
