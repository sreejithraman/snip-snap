import SnipSnapCore
import SwiftUI
import UIKit

/// How the regular-width library shows its lists.
enum RegularLibraryLayout: String {
    case sidebar
    case rail

    /// Phone panels, such as the open iPhone Duo or a large iPhone in landscape, get the rail.
    @MainActor static let current: RegularLibraryLayout = TryOverride.value("SNIP_SNAP_REGULAR_LAYOUT")
        ?? (UIDevice.current.userInterfaceIdiom == .phone ? .rail : .sidebar)
}

/// Launch-time switches for trying design candidates on a device. Release builds ignore them.
enum TryOverride {
    static func value<Value: RawRepresentable>(_ key: String) -> Value? where Value.RawValue == String {
#if DEBUG
        ProcessInfo.processInfo.environment[key].flatMap(Value.init(rawValue:))
#else
        nil
#endif
    }
}

extension EnvironmentValues {
    /// Paste and library actions ask for the system's trailing column of round buttons.
    @Entry var prefersSideButtons = false
}

extension ToolbarContent {
    /// Joins the open iPhone Duo's trailing column of round buttons. Without that column it stays put.
    @ToolbarContentBuilder
    func sideButton() -> some ToolbarContent {
        if #available(iOS 27.1, *) {
            axisBehavior(.verticalPreferred)
        } else {
            self
        }
    }
}

enum NewListButtonStyle: String {
    case roundPlus
    case roundCompose
    case inlinePlus
    case inlineStackBadgePlus

    static let current: NewListButtonStyle = TryOverride.value("SNIP_SNAP_NEW_LIST_BUTTON") ?? .roundPlus

    var systemImage: String {
        switch self {
        case .roundPlus, .inlinePlus: "plus"
        case .roundCompose: "square.and.pencil"
        case .inlineStackBadgePlus: "rectangle.stack.badge.plus"
        }
    }

    /// Round styles pin a glass circle to the bottom of the rail; the others follow the last list.
    var isPinned: Bool { self == .roundPlus || self == .roundCompose }
}

/// What the rail draws for a list in place of its name.
enum RailListMark: Equatable {
    case icon(String)
    case letters(String)

    enum Policy: String {
        case letterBadgeForDefaultIcon = "letters"
        case iconOnly = "icons"

        static let current: Policy = TryOverride.value("SNIP_SNAP_RAIL_LIST_MARK") ?? .letterBadgeForDefaultIcon
    }

    /// Icons a list has until someone picks one: the app's new-list icon and the core fallback.
    static let defaultIcons: Set<String> = [ListIconSymbol.defaultName, "circle.grid.2x2.fill"]

    init(name: String, systemImage: String, policy: Policy = .current) {
        guard policy == .letterBadgeForDefaultIcon, Self.defaultIcons.contains(systemImage) else {
            self = .icon(systemImage)
            return
        }
        let initials = name.split(whereSeparator: \.isWhitespace)
            .compactMap { word in word.first(where: { $0.isLetter || $0.isNumber }) }
            .prefix(2)
        self = initials.isEmpty ? .icon(systemImage) : .letters(String(initials).uppercased())
    }
}

/// The open iPhone Duo's narrow list column: icons only, beside the page card.
struct LibraryRailView: View {
    static let width: CGFloat = 80
    let model: IOSAppModel
    @Binding var sheet: AppSheet?
    let deleteList: (UUID) async -> Void
    private let newListStyle = NewListButtonStyle.current

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                RailButton(
                    title: String(localized: "Clipboard"),
                    isSelected: model.selectedPage == .clipboard,
                    action: { model.selectPage(.clipboard) }
                ) {
                    RailIcon(systemImage: "clipboard", color: .primary)
                }
                .accessibilityIdentifier("clipboard-sidebar")

                if model.recoverySnapshot.needsAttentionCount > 0 {
                    needsAttention
                }

                Divider()
                    .frame(width: 36)
                    .padding(.vertical, 4)

                ForEach(model.lists) { list in
                    RailButton(
                        title: list.displayName,
                        isSelected: model.selectedPage == .list(list.id),
                        action: { model.selectPage(.list(list.id)) }
                    ) {
                        RailListMarkView(list: list)
                    }
                    .accessibilityIdentifier("list-\(list.name)")
                    .listContextActions(
                        list: list,
                        beforeDelete: model.haptics.invalidatePendingFeedback,
                        edit: { model.editListInline(id: list.id) },
                        delete: { Task { await deleteList(list.id) } }
                    )
                }

                if !newListStyle.isPinned {
                    newListButton
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if newListStyle.isPinned {
                newListButton
                    .padding(.vertical, 12)
            }
        }
        .frame(width: Self.width)
    }

    private var needsAttention: some View {
        RailButton(
            title: String(localized: "Needs attention"),
            isSelected: false,
            action: { sheet = .recoveryCenter }
        ) {
            RailIcon(systemImage: "exclamationmark.bubble", color: .primary)
                .overlay(alignment: .topTrailing) {
                    Text(model.recoverySnapshot.needsAttentionCount, format: .number)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(.red, in: Capsule())
                        .offset(x: 10, y: -10)
                }
        }
        .accessibilityValue(Text(model.recoverySnapshot.needsAttentionCount, format: .number))
        .accessibilityIdentifier("needs-attention")
    }

    private var newListButton: some View {
        Group {
            if newListStyle.isPinned {
                Button {
                    Task { await model.openNewList() }
                } label: {
                    Image(systemName: newListStyle.systemImage)
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("New List")
                .accessibilityShowsLargeContentViewer {
                    Label("New List", systemImage: newListStyle.systemImage)
                }
            } else {
                RailButton(
                    title: String(localized: "New List"),
                    isSelected: false,
                    action: { Task { await model.openNewList() } }
                ) {
                    RailIcon(systemImage: newListStyle.systemImage, color: .secondary)
                }
            }
        }
        .accessibilityIdentifier("new-list")
#if DEBUG
        .anchorPreference(key: DevelopmentMenuBoundsKey.self, value: .bounds) { $0 }
#endif
    }
}

private struct RailButton<Mark: View>: View {
    private static var length: CGFloat { 56 }
    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        Button(action: action) {
            mark()
                .frame(width: Self.length, height: Self.length)
                .background {
                    // The card's color ties the selected list to the page beside it.
                    if isSelected { Self.shape.fill(Color(.systemBackground)) }
                }
                .contentShape([.interaction, .contextMenuPreview], Self.shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label { Text(title) } icon: { mark() }
        }
    }
}

private struct RailIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(color)
    }
}

private struct RailListMarkView: View {
    @Environment(\.self) private var environment
    let list: SnipList

    var body: some View {
        switch RailListMark(name: list.displayName, systemImage: list.displaySystemImage) {
        case .icon(let systemImage):
            RailIcon(systemImage: systemImage, color: list.accent.color)
        case .letters(let letters):
            Text(verbatim: letters)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(list.color == nil ? Color.primary : list.accent.filledControlLabel(in: environment))
                .padding(4)
                .frame(width: 36, height: 36)
                .background(list.color == nil ? Color(.systemGray4) : list.accent.color, in: Circle())
        }
    }
}
