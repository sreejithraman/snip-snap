import SwiftUI

/// List and clipboard items keep the same text, previews, and footer order.
struct ItemRowContent<TextContent: View, Previews: View, Metadata: View>: View {
    @ViewBuilder let text: () -> TextContent
    @ViewBuilder let previews: () -> Previews
    @ViewBuilder let metadata: () -> Metadata

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            text()
            previews()
            metadata()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The same bounded, expandable text presentation for either kind of item.
struct ItemRowText: View {
    let text: String
    var lineLimit: Int? = previewLineLimit
    var isDone = false
    var allowsExpansion = true
    var accessibilityIdentifier = ""
    var onActivate: (_ isPointerClick: Bool) -> Bool = { _ in true }
    var onDoubleClick: (() -> Void)? = nil

    static var previewLineLimit: Int {
#if os(macOS)
        5
#else
        3
#endif
    }

    private var strikethroughColor: Color? {
#if os(macOS)
        SnipSnapColors.doneStrikethrough
#else
        nil
#endif
    }

    private var lineSpacing: CGFloat {
#if os(macOS)
        2
#else
        0
#endif
    }

    var body: some View {
        Group {
            if let lineLimit {
                ExpandableSnipText(
                    text: text,
                    lineLimit: lineLimit,
                    isDone: isDone,
                    strikethroughColor: strikethroughColor,
                    lineSpacing: lineSpacing,
                    allowsExpansion: allowsExpansion,
                    accessibilityIdentifier: accessibilityIdentifier,
                    onActivate: onActivate,
                    onDoubleClick: onDoubleClick
                )
            } else {
                Text(text)
                    .strikethrough(isDone)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.body)
#if os(macOS)
        .foregroundStyle(SnipSnapColors.textPrimary)
        .opacity(isDone ? SnipSnapColors.doneTextOpacity : 1)
#else
        .foregroundStyle(isDone ? .secondary : .primary)
#endif
    }
}
