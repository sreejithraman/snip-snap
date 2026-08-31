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
        Picker(.filter(completionFilterTitle), selection: $model.completionFilter) {
            Text(.all).tag(SnipCompletionFilter.all)
            Text(SnipCompletionLanguage.done).tag(SnipCompletionFilter.done)
            Text(SnipCompletionLanguage.notDone).tag(SnipCompletionFilter.notDone)
        }

        Picker(.sort(sortModeTitle), selection: sortModeBinding) {
            Text(.chronological).tag(SnipSortMode.chronological)
            Text(.manual).tag(SnipSortMode.manual)
        }

        Picker(.appearance, selection: appearanceBinding) {
            Label(.system, systemImage: "circle.lefthalf.filled")
                .tag(AppAppearance.system)
            Label(.light, systemImage: "sun.max")
                .tag(AppAppearance.light)
            Label(.dark, systemImage: "moon")
                .tag(AppAppearance.dark)
        }

        Divider()

        Button(.moveToNewList) {
            focusedTarget = nil
            moveSelectionToNewList()
        }
        .disabled(model.selection.isEmpty)

        Button(.selectAll) {
            selectAllVisible()
        }
        .disabled(model.filteredSnips.isEmpty)

        Divider()

        Button(.actionOpenKeyboardShortcuts) {
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
        guard let developmentBuild else { return String(localized: .more) }
        return String(localized: .moreDevelopmentBuild(developmentBuild.slot))
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
            String(localized: .chronological)
        case .manual:
            String(localized: .manual)
        }
    }
}
