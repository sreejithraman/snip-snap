import SwiftUI

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

struct ItemRowText: View {
    let content: SnipTextContent
    var lineLimit: Int? = previewLineLimit
    var isDone = false
    var allowsExpansion = true
    var accessibilityIdentifier = ""
    var onActivate: (_ isPointerClick: Bool) -> Bool = { _ in true }
    var onDoubleClick: (() -> Void)? = nil

    static var previewLineLimit: Int {
        SnipTextPresentation.previewLineLimit
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
            if allowsExpansion, let lineLimit {
                ExpandableSnipText(
                    content: content,
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
                let label = Text(content.presentation(lineLimit: lineLimit).preview)
                (isDone ? label.strikethrough(color: strikethroughColor) : label)
                    .lineLimit(lineLimit)
                    .lineSpacing(lineSpacing)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .redacted(reason: content.isLoading ? .placeholder : [])
        .accessibilityLabel(Text(content.accessibilityText))
        .allowsHitTesting(!content.isLoading)
        .font(.body)
#if os(macOS)
        .foregroundStyle(SnipSnapColors.textPrimary)
        .opacity(isDone ? SnipSnapColors.doneTextOpacity : 1)
#else
        .foregroundStyle(isDone ? .secondary : .primary)
#endif
    }
}
