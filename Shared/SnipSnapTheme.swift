import SwiftUI

struct AppToast: Identifiable {
    enum Action: Equatable {
        case undoDelete
    }

    let id: UUID
    let systemImage: String
    let message: String
    let action: Action?
    let duration: Duration
    let expiresAt: ContinuousClock.Instant

    init(
        id: UUID = UUID(),
        systemImage: String,
        message: String,
        action: Action? = nil,
        duration: Duration = .seconds(4)
    ) {
        self.id = id
        self.systemImage = systemImage
        self.message = message
        self.action = action
        self.duration = duration
        self.expiresAt = ContinuousClock().now.advanced(by: duration)
    }

    static func copied(count: Int) -> Self {
        Self(
            systemImage: "doc.on.doc",
            message: count == 1
                ? String(localized: "Copied")
                : String(localized: "Copied \(count) snips")
        )
    }

    static func deleted(count: Int, id: UUID) -> Self {
        Self(
            id: id,
            systemImage: "trash",
            message: count == 1
                ? String(localized: "Snip deleted")
                : String(localized: "\(count) snips deleted"),
            action: .undoDelete,
            duration: .seconds(6)
        )
    }
}

/// The preferred, nondestructive action in the current view.
///
/// The role is shared, while each platform keeps its native prominent style.
enum AppPrimaryActionPresentation {
    case content
    case floatingGlass
}

struct AppPrimaryActionButton<Label: View>: View {
    var presentation: AppPrimaryActionPresentation = .content
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @ViewBuilder
    var body: some View {
#if os(macOS)
        contentButton
#else
        switch presentation {
        case .content:
            contentButton
        case .floatingGlass:
            Button(action: action) {
                label()
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(SnipSnapTheme.actionAccent)
            .foregroundStyle(SnipSnapTheme.actionLabel)
        }
#endif
    }

    private var contentButton: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(.borderedProminent)
        .tint(SnipSnapTheme.actionAccent)
        .foregroundStyle(SnipSnapTheme.actionLabel)
    }
}

struct AppTintedGlassActionButton<Label: View>: View {
    let isEnabled: Bool
    var tint: Color = SnipSnapTheme.actionGlassTint
    var labelColor: Color = SnipSnapTheme.actionLabel
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(.glass(.regular.tint(
            isEnabled ? tint.opacity(SnipSnapTheme.listGlassTintOpacity) : SnipSnapTheme.disabledActionGlassTint
        )))
        .buttonBorderShape(.capsule)
        .foregroundStyle(
            isEnabled ? labelColor : SnipSnapTheme.disabledActionGlassLabel
        )
        .disabled(!isEnabled)
    }
}

private struct AppToastPresenter: ViewModifier {
    @Binding var toast: AppToast?
    let alignment: Alignment
    let edge: Edge
    let isHidden: Bool
    let reservesSpace: Bool
    let usesFixedExpiry: Bool
    let onAction: (AppToast) -> Void
    let onDismiss: (AppToast) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func body(content: Content) -> some View {
        Group {
            if reservesSpace {
                content.safeAreaInset(edge: .bottom, spacing: 0) {
                    presentedToast
                }
            } else {
                content.overlay(alignment: alignment) {
                    presentedToast
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: toast?.id)
        .task(id: timerID) {
            guard let toast, !isHovering, !isHidden else { return }
            do {
                if usesFixedExpiry {
                    try await ContinuousClock().sleep(until: toast.expiresAt)
                } else {
                    try await Task.sleep(for: toast.duration)
                }
            } catch {
                return
            }
            guard self.toast?.id == toast.id else { return }
            self.toast = nil
            onDismiss(toast)
        }
    }

    @ViewBuilder
    private var presentedToast: some View {
        if !isHidden, let toast {
            toastView(toast)
                .padding(12)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: edge).combined(with: .opacity)
                )
                .onHover { isHovering = $0 }
        }
    }

    private var timerID: String {
        "\(toast?.id.uuidString ?? "none")-\(isHovering)-\(isHidden)"
    }

    private func toastView(_ toast: AppToast) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: SnipSnapSpacing.relatedContent) {
                Image(systemName: toast.systemImage)
                    .foregroundStyle(.secondary)
                Text(toast.message)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if toast.action != nil {
                    AppPrimaryActionButton(presentation: .floatingGlass) {
                        self.toast = nil
                        onAction(toast)
                    } label: {
                        Text("Undo")
                    }
                    .font(.subheadline.weight(.bold))
                    .controlSize(.small)
#if os(iOS)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
#endif
                    .accessibilityIdentifier("toast-action")
                }
            }
            .padding(.horizontal, SnipSnapSpacing.cardContentInset)
            .padding(.vertical, toastVerticalPadding(for: toast))
            .glassEffect(
                toast.action == nil ? .regular : .regular.interactive(),
                in: .capsule
            )
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(toast.message)
        .accessibilityIdentifier("app-toast")
    }

    private func toastVerticalPadding(for toast: AppToast) -> CGFloat {
#if os(iOS)
        toast.action == nil ? SnipSnapSpacing.relatedContent : 4
#else
        SnipSnapSpacing.relatedContent
#endif
    }
}

extension View {
    func appToast(
        _ toast: Binding<AppToast?>,
        alignment: Alignment,
        edge: Edge,
        isHidden: Bool = false,
        reservesSpace: Bool = false,
        usesFixedExpiry: Bool = false,
        onAction: @escaping (AppToast) -> Void = { _ in },
        onDismiss: @escaping (AppToast) -> Void = { _ in }
    ) -> some View {
        modifier(
            AppToastPresenter(
                toast: toast,
                alignment: alignment,
                edge: edge,
                isHidden: isHidden,
                reservesSpace: reservesSpace,
                usesFixedExpiry: usesFixedExpiry,
                onAction: onAction,
                onDismiss: onDismiss
            )
        )
    }

}

/// Color roles shared by the Mac and iOS app chrome.
///
/// Platform views own their layout, but both apps read these roles so controls
/// share neutral chrome and list accents in light and dark mode.
enum SnipSnapTheme {
    static let listGlassTintOpacity = 0.8
    static let listSelectionGlassTint = Color.primary.opacity(0.12)
    static let listEditorGlassTint = Color.primary.opacity(0.03)
    static func sendIconColor(tint: Color) -> Color {
        Color.white.mix(with: tint, by: 0.12)
    }

    /// The app's monochrome accent. Reserve it for active controls,
    /// selection, and one preferred action in a view.
#if os(macOS)
    static let actionAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.92, alpha: 1)
            : NSColor(white: 0.16, alpha: 1)
    })
    static let actionLabel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 1)
            : .white
    })
#else
    static let actionAccent = Color("AccentColor")
    static let actionLabel = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.10, alpha: 1)
            : .white
    })
#endif
    static let controlTint = actionAccent
    static let actionGlassTint = actionAccent
    static let actionGlassLabel = actionLabel
    static let disabledActionGlassTint = Color.primary.opacity(0.08)
    static let disabledActionGlassLabel = Color.primary.opacity(0.40)
    static let selectionFill = Color.primary.opacity(0.10)
    static let compactSelectionFill = Color.primary.opacity(0.18)
    static let compactActionFill = Color.primary.opacity(0.10)
    static let emphasizedGlassEdge = Color.primary.opacity(0.20)
    static let focusedGlassEdge = Color.primary.opacity(0.32)

}

/// Shared gaps and insets for custom surfaces on both platforms.
/// Platform views keep their own control sizes because pointer and touch
/// controls have different system defaults.
enum SnipSnapSpacing {
    static let relatedContent: CGFloat = 8
    static let controlContentInset: CGFloat = 10
    static let cardContentInset: CGFloat = 12
    static let paneContentInset: CGFloat = 16
}
