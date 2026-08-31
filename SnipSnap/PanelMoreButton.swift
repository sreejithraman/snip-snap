import SwiftUI
import SnipSnapCore

struct PanelMoreButton: View {
    @ObservedObject var model: AppModel
    @FocusState.Binding var focusedTarget: PanelFocusTarget?
    let moveSelectionToNewList: () -> Void
    let selectAllVisible: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            actions
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(
                    width: PanelControlMetrics.floatingIconLength,
                    height: PanelControlMetrics.floatingIconLength
                )
                .panelStandaloneActionControl()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help(moreLabel)
        .accessibilityLabel(moreLabel)
    }

    @ViewBuilder
    private var actions: some View {
        Picker("Filter: \(completionFilterTitle)", selection: $model.completionFilter) {
            Text("All").tag(SnipCompletionFilter.all)
            Text(SnipCompletionLanguage.done).tag(SnipCompletionFilter.done)
            Text(SnipCompletionLanguage.notDone).tag(SnipCompletionFilter.notDone)
        }

        Picker("Sort: \(sortModeTitle)", selection: sortModeBinding) {
            Text("Chronological").tag(SnipSortMode.chronological)
            Text("Manual").tag(SnipSortMode.manual)
        }

        Picker("Appearance", selection: appearanceBinding) {
            Label("System", systemImage: "circle.lefthalf.filled")
                .tag(AppAppearance.system)
            Label("Light", systemImage: "sun.max")
                .tag(AppAppearance.light)
            Label("Dark", systemImage: "moon")
                .tag(AppAppearance.dark)
        }

        Divider()

        Button("Move to New List…") {
            focusedTarget = nil
            moveSelectionToNewList()
        }
        .disabled(model.selection.isEmpty)

        Button("Select All") {
            selectAllVisible()
        }
        .disabled(model.filteredSnips.isEmpty)

        Divider()

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
            String(localized: "Chronological")
        case .manual:
            String(localized: "Manual")
        }
    }
}
