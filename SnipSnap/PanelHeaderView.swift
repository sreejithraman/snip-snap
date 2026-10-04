import SnipSnapCore
import SwiftUI

struct PanelHeaderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var accessibilityPermissions: AccessibilityPermissionController
    @FocusState.Binding var focusedTarget: PanelFocusTarget?
    let closePanel: () -> Void
    let expandSearch: () -> Void
    let collapseSearch: () -> Void
    let reviewRecovery: () -> Void
    let moveSelectionToNewList: () -> Void
    let selectAllVisible: () -> Void
    let syncedContentSettings: SyncedContentSettingsModel?
    let syncNow: (@MainActor () async -> Void)?

    private let searchControlInset: CGFloat = 8
    private let compactSearchWidth: CGFloat = 128

    private var sideControlsWidth: CGFloat {
        let count = (model.isSearchExpanded ? 1 : 2)
            + (model.needsAttentionCount > 0 ? 1 : 0)
        return CGFloat(count) * PanelControlMetrics.floatingRowHeight
            + CGFloat(count - 1) * SnipSnapSpacing.relatedContent
    }

    var body: some View {
        HStack(spacing: SnipSnapSpacing.relatedContent) {
            Button(action: closePanel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SnipSnapColors.textSecondary)
                    .panelStandaloneActionControl()
            }
            .buttonStyle(.plain)
            .help("Close panel")
            .accessibilityLabel("Close panel")
            .accessibilityIdentifier("panel-close")
            .frame(width: sideControlsWidth, alignment: .leading)

            searchControl
                .frame(maxWidth: .infinity)

            HStack(spacing: SnipSnapSpacing.relatedContent) {
                if model.needsAttentionCount > 0 {
                    needsAttentionButton
                }

                if !model.isSearchExpanded {
                    PanelViewOptionsButton(model: model)
                }

                PanelMoreButton(
                    model: model,
                    accessibilityPermissions: accessibilityPermissions,
                    focusedTarget: $focusedTarget,
                    moveSelectionToNewList: moveSelectionToNewList,
                    selectAllVisible: selectAllVisible,
                    syncedContentSettings: syncedContentSettings,
                    syncNow: syncNow
                )
            }
            .frame(width: sideControlsWidth, alignment: .trailing)
        }
        .background { PanelDragRegion() }
    }

    private var searchControl: some View {
        HStack(spacing: 0) {
            if model.isSearchExpanded {
                Button {
                    focusedTarget = .search
                } label: {
                    searchIcon
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.editingID != nil)
                .padding(.leading, searchControlInset)
                .accessibilityLabel("Focus search")
                .accessibilityIdentifier("global-search-expand")

                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(SnipSnapColors.textPrimary)
                    .focused($focusedTarget, equals: .search)
                    .disabled(model.editingID != nil)
                    .accessibilityLabel("Search all lists and Clipboard")
                    .accessibilityIdentifier("global-search-field")

                Button(action: collapseSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(SnipSnapColors.textSecondary)
                        .frame(
                            width: PanelControlMetrics.floatingRowHeight - searchControlInset,
                            height: PanelControlMetrics.floatingRowHeight
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.editingID != nil)
                .padding(.trailing, searchControlInset)
                .accessibilityLabel("Close search")
                .accessibilityIdentifier("global-search-close")
            } else {
                Button(action: expandSearch) {
                    HStack(spacing: 0) {
                        searchIcon
                        Text("Search")
                    }
                    .foregroundStyle(SnipSnapColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: PanelControlMetrics.floatingRowHeight)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.editingID != nil)
                .help("Search all lists and Clipboard")
                .accessibilityLabel("Search all lists and Clipboard")
                .accessibilityIdentifier("global-search-expand")
            }
        }
        .frame(maxWidth: model.isSearchExpanded ? .infinity : compactSearchWidth)
        .frame(height: PanelControlMetrics.floatingRowHeight)
        .panelGlassSurface(
            in: Capsule(),
            interactive: true,
            tint: SnipSnapColors.nestedGlassTint
        )
    }

    private var searchIcon: some View {
        Image(systemName: "magnifyingglass")
            .foregroundStyle(SnipSnapColors.textSecondary)
            .frame(
                width: PanelControlMetrics.floatingRowHeight - searchControlInset,
                height: PanelControlMetrics.floatingRowHeight
            )
    }

    private var needsAttentionButton: some View {
        Button(action: reviewRecovery) {
            Image(systemName: "exclamationmark.circle.fill")
                .panelStandaloneActionControl()
        }
        .buttonStyle(.plain)
        .disabled(model.editingID != nil)
        .accessibilityLabel("Needs attention (\(model.needsAttentionCount))")
        .help("Needs attention (\(model.needsAttentionCount))")
    }
}
