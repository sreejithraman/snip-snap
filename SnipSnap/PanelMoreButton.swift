import SwiftUI
import SnipSnapCore

struct PanelMoreButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var accessibilityPermissions: AccessibilityPermissionController
    @FocusState.Binding var focusedTarget: PanelFocusTarget?
    let moveSelectionToNewList: () -> Void
    let selectAllVisible: () -> Void
    let syncedContentSettings: SyncedContentSettingsModel?
    let syncNow: (@MainActor () async -> Void)?

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

        if model.latestFailure != nil {
            Button("Error details", systemImage: "exclamationmark.triangle") {
                model.showLatestErrorDetails()
            }
            .accessibilityIdentifier("latest-error-details")
            Divider()
        }

        if let title = accessibilityPermissions.menuActionTitle {
            Button(title) {
                accessibilityPermissions.performMenuAction()
            }
        }

        if let syncedContentSettings, let syncNow,
           syncedContentSettings.mode == .iCloudSync {
            Button("Sync", systemImage: "arrow.triangle.2.circlepath") {
                Task {
                    guard syncedContentSettings.canSyncNow else { return }
                    await syncNow()
                }
            }
            .disabled(!syncedContentSettings.canSyncNow)
            .accessibilityIdentifier("sync-icloud")
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
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
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
        .buttonStyle(.plain)
        .disabled(model.editingID != nil)
        .help("View options")
        .accessibilityLabel("View options")
        .accessibilityIdentifier("workflow-options")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            options
                .onExitCommand { isPresented = false }
        }
        .onDisappear { isPresented = false }
        .onChange(of: model.editingID) { _, editingID in
            if editingID != nil { isPresented = false }
        }
        .onChange(of: model.isShowingClipboard) { _, _ in
            isPresented = false
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("View options")
                .appFont(.headline)
            if model.isShowingClipboard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Show", selection: $model.clipboardViewOptions.onlyPinned) {
                        Text("All").tag(false)
                        Text("Pinned").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                Divider()
                Picker("Sort", selection: $model.clipboardViewOptions.newestFirst) {
                    Text("Newest first").tag(true)
                    Text("Oldest first").tag(false)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Show", selection: completionFilterBinding) {
                        ForEach(SnipCompletionFilter.allCases, id: \.self) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    if model.completionFilter == .all {
                        Picker("Done shown", selection: Binding(
                            get: { model.doneLimit },
                            set: { model.setDoneLimit($0) }
                        )) {
                            ForEach(SnipDoneLimit.allCases, id: \.self) { limit in
                                Text(limit.title).tag(limit)
                            }
                        }
                    }
                }
                Divider()
                Picker("Written by", selection: originFilterBinding) {
                    ForEach(SnipOriginFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                Picker("Sort", selection: sortModeBinding) {
                    ForEach(SnipSortMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
        }
        .appFont(.body)
        .padding(16)
        .frame(width: PanelDialogMetrics.width)
        .accessibilityIdentifier("workflow-options-popover")
    }

    private var sortModeBinding: Binding<SnipSortMode> {
        Binding(
            get: { model.sortMode },
            set: { model.setSortMode($0) }
        )
    }

    private var originFilterBinding: Binding<SnipOriginFilter> {
        Binding(
            get: { model.originFilter },
            set: { model.originFilter = $0 }
        )
    }

    private var completionFilterBinding: Binding<SnipCompletionFilter> {
        Binding(
            get: { model.completionFilter },
            set: { model.completionFilter = $0 }
        )
    }
}
