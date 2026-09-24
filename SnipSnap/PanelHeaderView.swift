import SwiftUI

struct PanelHeaderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var accessibilityPermissions: AccessibilityPermissionController
    @FocusState.Binding var focusedTarget: PanelFocusTarget?
    let expandSearch: () -> Void
    let collapseSearch: () -> Void
    let reviewRecovery: () -> Void
    let moveSelectionToNewList: () -> Void
    let selectAllVisible: () -> Void

    private let searchControlInset: CGFloat = 8

    var body: some View {
        HStack(spacing: SnipSnapSpacing.relatedContent) {
            searchControl

            if !model.isSearchExpanded {
                Text(model.isShowingClipboard ? String(localized: "Clipboard") : model.activeList.displayName)
                    .font(.headline)
                    .foregroundStyle(SnipSnapColors.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
            }

            if model.needsAttentionCount > 0 {
                needsAttentionButton
            }

            PanelMoreButton(
                model: model,
                accessibilityPermissions: accessibilityPermissions,
                focusedTarget: $focusedTarget,
                moveSelectionToNewList: moveSelectionToNewList,
                selectAllVisible: selectAllVisible
            )
        }
        .background { PanelDragRegion() }
    }

    private var searchControl: some View {
        HStack(spacing: 0) {
            Button {
                if model.isSearchExpanded {
                    focusedTarget = .search
                } else {
                    expandSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SnipSnapColors.textPrimary)
                    .frame(
                        width: model.isSearchExpanded
                            ? PanelControlMetrics.floatingRowHeight - searchControlInset
                            : PanelControlMetrics.floatingRowHeight,
                        height: PanelControlMetrics.floatingRowHeight
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.editingID != nil)
            .padding(.leading, model.isSearchExpanded ? searchControlInset : 0)
            .accessibilityLabel(
                model.isSearchExpanded
                    ? String(localized: "Focus search")
                    : String(localized: "Search all lists and Clipboard")
            )
            .accessibilityIdentifier("global-search-expand")

            if model.isSearchExpanded {
                TextField("Search", text: $model.query)
                    .panelInputStyle()
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
            }
        }
        .frame(width: model.isSearchExpanded ? nil : PanelControlMetrics.floatingRowHeight)
        .frame(maxWidth: model.isSearchExpanded ? .infinity : nil)
        .frame(height: PanelControlMetrics.floatingRowHeight)
        .panelGlassSurface(in: Capsule(), interactive: true)
    }

    @ViewBuilder
    private var needsAttentionButton: some View {
        if model.isSearchExpanded {
            Button(action: reviewRecovery) {
                Image(systemName: "exclamationmark.circle.fill")
                    .frame(
                        width: PanelControlMetrics.floatingRowHeight,
                        height: PanelControlMetrics.floatingRowHeight
                    )
                    .panelStandaloneActionControl()
            }
            .buttonStyle(.plain)
            .disabled(model.editingID != nil)
            .accessibilityLabel("Needs attention (\(model.needsAttentionCount))")
            .help("Review recovered versions")
        } else {
            Button(action: reviewRecovery) {
                Label("Needs attention (\(model.needsAttentionCount))", systemImage: "exclamationmark.circle.fill")
            }
            .buttonStyle(.bordered)
            .disabled(model.editingID != nil)
            .help("Review recovered versions")
        }
    }
}
