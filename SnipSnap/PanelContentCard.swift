import SwiftUI

private enum PanelContentCardMetrics {
    static let cornerRadius: CGFloat = 14
}

struct PanelContentCardState: Equatable {
    var isSelected = false
    var isSubdued = false
}

struct PanelContentCard<Leading: View, Main: View, Trailing: View>: View {
    let state: PanelContentCardState
    let alignment: VerticalAlignment
    private let hasLeading: Bool
    private let hasTrailing: Bool
    private let leading: Leading
    private let main: Main
    private let trailing: Trailing

    init(
        state: PanelContentCardState = .init(),
        alignment: VerticalAlignment = .top,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder main: () -> Main,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.state = state
        self.alignment = alignment
        hasLeading = true
        hasTrailing = true
        self.leading = leading()
        self.main = main()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: SnipSnapSpacing.relatedContent) {
            if hasLeading {
                leading
                    .fixedSize(horizontal: true, vertical: false)
            }

            main
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasTrailing {
                trailing
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(SnipSnapSpacing.cardContentInset)
        .background {
            shape
                .fill(.regularMaterial)
                .overlay {
                    if state.isSelected {
                        shape.fill(SnipSnapColors.selectionFill)
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        edge.color,
                        lineWidth: edge.width
                    )
                }
                .shadow(
                    color: SnipSnapColors.contentCardShadow(isSelected: state.isSelected),
                    radius: state.isSelected ? 8 : 7,
                    y: 3
                )
        }
        .contentShape(shape)
        .opacity(state.isSubdued ? SnipSnapColors.doneCardOpacity : 1)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PanelContentCardMetrics.cornerRadius,
            style: .continuous
        )
    }

    private var edge: PanelEdgeStyle {
        state.isSelected ? .selected : .content
    }
}

extension PanelContentCard where Trailing == EmptyView {
    init(
        state: PanelContentCardState = .init(),
        alignment: VerticalAlignment = .top,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder main: () -> Main
    ) {
        self.state = state
        self.alignment = alignment
        hasLeading = true
        hasTrailing = false
        self.leading = leading()
        self.main = main()
        trailing = EmptyView()
    }
}

extension PanelContentCard where Leading == EmptyView {
    init(
        state: PanelContentCardState = .init(),
        alignment: VerticalAlignment = .top,
        @ViewBuilder main: () -> Main,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.state = state
        self.alignment = alignment
        hasLeading = false
        hasTrailing = true
        leading = EmptyView()
        self.main = main()
        self.trailing = trailing()
    }
}

extension PanelContentCard where Leading == EmptyView, Trailing == EmptyView {
    init(
        state: PanelContentCardState = .init(),
        alignment: VerticalAlignment = .top,
        @ViewBuilder main: () -> Main
    ) {
        self.state = state
        self.alignment = alignment
        hasLeading = false
        hasTrailing = false
        leading = EmptyView()
        self.main = main()
        trailing = EmptyView()
    }
}

struct PanelContentCardMain<Media: View, Content: View>: View {
    private let hasMedia: Bool
    private let media: Media
    private let content: Content

    init(
        @ViewBuilder media: () -> Media,
        @ViewBuilder content: () -> Content
    ) {
        hasMedia = true
        self.media = media()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            if hasMedia {
                media
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PanelContentCardMain where Media == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        hasMedia = false
        media = EmptyView()
        self.content = content()
    }
}
