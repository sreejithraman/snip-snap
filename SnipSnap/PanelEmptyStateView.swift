import SnipSnapCore
import SwiftUI

struct PanelEmptyStateView: View {
    @ObservedObject var model: AppModel
    let captureShortcutName: String

    var body: some View {
        VStack(spacing: SnipSnapSpacing.relatedContent) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(SnipSnapColors.textTertiary)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SnipSnapColors.textSecondary)
            if !model.isSearchExpanded, model.completionFilter == .all {
                Text("Select text, then press \(captureShortcutName) to save it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SnipSnapColors.textTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { PanelDragRegion() }
    }

    private var icon: String {
        if model.isSearchExpanded { return "magnifyingglass" }
        if model.completionFilter != .all { return "line.3.horizontal.decrease.circle" }
        return "tray"
    }

    private var title: String {
        if model.isSearchExpanded && !model.hasActiveQuery {
            return String(localized: "Search all lists and Clipboard")
        }
        if model.hasActiveQuery { return String(localized: "No results") }
        return model.completionFilter.emptyStateTitle
    }
}
