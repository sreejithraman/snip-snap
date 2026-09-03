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

struct AppProminentActionButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(.glassProminent)
        .tint(SnipSnapTheme.controlTint)
        .foregroundStyle(SnipSnapTheme.prominentControlLabel)
        .buttonBorderShape(.capsule)
    }
}

struct AppTintedGlassActionButton<Label: View>: View {
    let isEnabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .tint(
            isEnabled
                ? SnipSnapTheme.actionGlassTint
                : SnipSnapTheme.disabledActionGlassTint
        )
        .foregroundStyle(
            isEnabled
                ? SnipSnapTheme.actionGlassLabel
                : SnipSnapTheme.disabledActionGlassLabel
        )
        .disabled(!isEnabled)
    }
}

private struct AppToastPresenter: ViewModifier {
    @Binding var toast: AppToast?
    let alignment: Alignment
    let edge: Edge
    let onAction: (AppToast) -> Void
    let onDismiss: (AppToast) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if let toast {
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
            .animation(reduceMotion ? nil : .snappy, value: toast?.id)
            .task(id: timerID) {
                guard let toast, !isHovering else { return }
                do {
                    try await Task.sleep(for: toast.duration)
                } catch {
                    return
                }
                guard self.toast?.id == toast.id else { return }
                self.toast = nil
                onDismiss(toast)
            }
    }

    private var timerID: String {
        "\(toast?.id.uuidString ?? "none")-\(isHovering)"
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
                    AppProminentActionButton {
                        self.toast = nil
                        onAction(toast)
                    } label: {
                        Text("Undo")
                    }
                    .font(.subheadline.weight(.bold))
                    .controlSize(.small)
                    .accessibilityIdentifier("toast-action")
                }
            }
            .padding(.horizontal, SnipSnapSpacing.cardContentInset)
            .padding(.vertical, SnipSnapSpacing.relatedContent)
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
}

extension View {
    func appToast(
        _ toast: Binding<AppToast?>,
        alignment: Alignment,
        edge: Edge,
        onAction: @escaping (AppToast) -> Void = { _ in },
        onDismiss: @escaping (AppToast) -> Void = { _ in }
    ) -> some View {
        modifier(
            AppToastPresenter(
                toast: toast,
                alignment: alignment,
                edge: edge,
                onAction: onAction,
                onDismiss: onDismiss
            )
        )
    }

}

/// Color roles shared by the Mac and iOS app chrome.
///
/// Platform views own their layout, but both apps read these roles so controls
/// keep the same monochrome Snip Snap look in light and dark mode.
enum SnipSnapTheme {
    static let controlTint = Color.primary
    static let actionGlassTint = Color.primary
    static let disabledActionGlassTint = Color.primary.opacity(0.08)
    static let actionGlassLabel = Color.primary
    static let disabledActionGlassLabel = Color.primary.opacity(0.40)
#if os(macOS)
    static let prominentControlLabel = Color(nsColor: .windowBackgroundColor)
#else
    static let prominentControlLabel = Color(uiColor: .systemBackground)
#endif
    static let selectionFill = Color.primary.opacity(0.10)
    static let compactSelectionFill = Color.primary.opacity(0.18)
    static let compactActionFill = Color.primary.opacity(0.10)
    static let glassEdge = Color.primary.opacity(0.10)
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
