import SnipSnapCore
import SwiftUI
import Observation

struct AppToast: Identifiable {
    enum CopiedContent {
        case snips
        case text
        case attachments

        var shortDescription: String {
            switch self {
            case .snips: String(localized: "Copied")
            case .text: String(localized: "Text copied")
            case .attachments: String(localized: "Attachments copied")
            }
        }
    }

    enum Action: Equatable {
        case undoDelete
        case undoDone
        case showErrorDetails(UUID)
    }

    let id: UUID
    let systemImage: String
    let message: String
    let detail: String?
    let action: Action?
    let duration: Duration
    let expiresAt: ContinuousClock.Instant
    let lifetime: AppToastLifetime
    private let copiedContent: CopiedContent?

    init(
        id: UUID = UUID(),
        systemImage: String,
        message: String,
        detail: String? = nil,
        action: Action? = nil,
        duration: Duration = .seconds(3),
        copiedContent: CopiedContent? = nil
    ) {
        self.id = id
        self.systemImage = systemImage
        self.message = message
        self.detail = detail
        self.action = action
        self.duration = duration
        self.expiresAt = ContinuousClock().now.advanced(by: duration)
        self.lifetime = AppToastLifetime(expiresAt: expiresAt, isActionable: action != nil)
        self.copiedContent = copiedContent
    }

    static func copied(count: Int) -> Self {
        Self(
            systemImage: "doc.on.doc",
            message: count == 1
                ? String(localized: "Snapped")
                : String(localized: "\(count) snips snapped"),
            detail: String(localized: "Copied to clipboard"),
            copiedContent: .snips
        )
    }

    static func copiedText() -> Self {
        Self(systemImage: "doc.text", message: String(localized: "Snapped"),
             detail: String(localized: "Text copied"), copiedContent: .text)
    }

    static func copiedAttachments() -> Self {
        Self(systemImage: "paperclip", message: String(localized: "Snapped"),
             detail: String(localized: "Attachments copied"), copiedContent: .attachments)
    }

    func addingDoneUndo(_ undo: SavedSnipsDoneUndo) -> Self {
        let copiedDetail = (copiedContent ?? .snips).shortDescription
        let doneDetail = undo.count == 1
            ? String(localized: "Marked Done")
            : String(localized: "\(undo.count) marked Done")
        return Self(id: undo.id, systemImage: systemImage, message: message,
                    detail: String(localized: "\(copiedDetail) · \(doneDetail)"),
                    action: .undoDone, duration: .seconds(6))
    }

    static func markedDone(count: Int, id: UUID) -> Self {
        Self(id: id, systemImage: "checkmark.circle", message: count == 1
             ? String(localized: "Marked Done")
             : String(localized: "\(count) snips marked Done"),
             action: .undoDone, duration: .seconds(6))
    }

    static func failed(_ failure: AppFailure) -> Self {
        Self(systemImage: "exclamationmark.triangle", message: failure.title,
             action: .showErrorDetails(failure.id), duration: .seconds(6))
    }

    var actionTitle: String {
        if case .showErrorDetails = action { return String(localized: "Details") }
        return String(localized: "Undo")
    }

    var actionAccessibilityLabel: String {
        switch action {
        case .undoDone: String(localized: "Undo marking Done")
        case .undoDelete: String(localized: "Undo deletion")
        case .showErrorDetails: String(localized: "Show error details")
        case nil: ""
        }
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

@MainActor
@Observable
final class AppToastLifetime {
    private let expiresAt: ContinuousClock.Instant
    private let isActionable: Bool
    private var pausedAt: ContinuousClock.Instant?
    private var pausedDuration: Duration = .zero
    @ObservationIgnored private var voiceOverEnabled = false
    @ObservationIgnored private var interactionOwners: Set<UUID> = []

    nonisolated init(expiresAt: ContinuousClock.Instant, isActionable: Bool) {
        self.expiresAt = expiresAt
        self.isActionable = isActionable
    }

    var deadline: ContinuousClock.Instant {
        expiresAt.advanced(by: pausedDuration)
    }

    var isPaused: Bool { pausedAt != nil }

    func setVoiceOverEnabled(_ enabled: Bool, at now: ContinuousClock.Instant = ContinuousClock().now) {
        voiceOverEnabled = enabled
        reconcilePause(at: now)
    }

    func setInteractionPaused(
        _ paused: Bool, owner: UUID,
        at now: ContinuousClock.Instant = ContinuousClock().now
    ) {
        if paused { interactionOwners.insert(owner) }
        else { interactionOwners.remove(owner) }
        reconcilePause(at: now)
    }

    func canExpire(at now: ContinuousClock.Instant = ContinuousClock().now) -> Bool {
        !isPaused && now >= deadline
    }

    private func reconcilePause(at now: ContinuousClock.Instant) {
        let shouldPause = (voiceOverEnabled && isActionable) || !interactionOwners.isEmpty
        if shouldPause, pausedAt == nil {
            pausedAt = now
        } else if !shouldPause, let pausedAt {
            pausedDuration += pausedAt.duration(to: now)
            self.pausedAt = nil
        }
    }
}

enum AppPrimaryActionPresentation {
    case content
    case floatingGlass
}

struct AppPrimaryActionButton<Label: View>: View {
#if os(macOS)
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var controlActiveState
#endif
    var presentation: AppPrimaryActionPresentation = .content
    var tint: Color = SnipSnapTheme.actionAccent
    var labelColor: Color = SnipSnapTheme.actionLabel
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
            .tint(tint)
            .foregroundStyle(labelColor)
        }
#endif
    }

    private var contentButton: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .foregroundStyle(contentLabelColor)
    }

    private var contentLabelColor: Color {
#if os(macOS)
        isEnabled && controlActiveState == .key
            ? labelColor : .primary
#else
        labelColor
#endif
    }
}

private struct AppToastPresenter: ViewModifier {
    @Binding var toast: AppToast?
    let alignment: Alignment
    let edge: Edge
    let isHidden: Bool
    let reservesSpace: Bool
    let usesFixedExpiry: Bool
    let bottomInset: CGFloat
    let onAction: (AppToast) -> Void
    let onDismiss: (AppToast) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var interactionOwnerID = UUID()
    @State private var observedLifetime: AppToastLifetime?
    @FocusState private var isActionFocused: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private struct PresentationInput: Equatable {
        let lifetime: ObjectIdentifier?
        let interactionPaused: Bool
        let voiceOverEnabled: Bool
    }

    private struct TimerID: Equatable {
        let toast: UUID?
        let lifetime: ObjectIdentifier?
        let deadline: ContinuousClock.Instant?
        let isPaused: Bool
        let isHidden: Bool
        let usesFixedExpiry: Bool
    }

    func body(content: Content) -> some View {
        Group {
            if reservesSpace {
                VStack(spacing: 0) {
                    content
                    presentedToast
                }
            } else {
                content.overlay(alignment: alignment) {
                    presentedToast
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: toast?.id)
        .onChange(of: presentationInput, initial: true) { _, input in
            let lifetime = toast?.lifetime
            if observedLifetime !== lifetime {
                observedLifetime?.setInteractionPaused(false, owner: interactionOwnerID)
                observedLifetime = lifetime
            }
            lifetime?.setVoiceOverEnabled(input.voiceOverEnabled)
            lifetime?.setInteractionPaused(input.interactionPaused, owner: interactionOwnerID)
        }
        .onDisappear {
            observedLifetime?.setInteractionPaused(false, owner: interactionOwnerID)
            observedLifetime = nil
        }
        .task(id: timerID) {
            guard let toast, !toast.lifetime.isPaused, !isHidden else { return }
            do {
                if usesFixedExpiry {
                    try await ContinuousClock().sleep(until: toast.lifetime.deadline)
                } else {
                    try await Task.sleep(for: toast.duration)
                }
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.toast?.id == toast.id,
                  self.toast?.lifetime === toast.lifetime,
                  !isHidden, !toast.lifetime.isPaused,
                  !usesFixedExpiry || toast.lifetime.canExpire() else { return }
            self.toast = nil
            onDismiss(toast)
        }
    }

    @ViewBuilder
    private var presentedToast: some View {
        if !isHidden, let toast {
            toastView(toast)
                .padding(12)
                .padding(.bottom, bottomInset)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: edge).combined(with: .opacity)
                )
                .onHover { isHovering = $0 }
        }
    }

    private var presentationInput: PresentationInput {
        PresentationInput(
            lifetime: toast.map { ObjectIdentifier($0.lifetime) },
            interactionPaused: !isHidden && (isHovering || isActionFocused),
            voiceOverEnabled: voiceOverEnabled
        )
    }

    private var timerID: TimerID {
        TimerID(
            toast: toast?.id,
            lifetime: toast.map { ObjectIdentifier($0.lifetime) },
            deadline: toast?.lifetime.deadline,
            isPaused: toast?.lifetime.isPaused ?? false,
            isHidden: isHidden,
            usesFixedExpiry: usesFixedExpiry
        )
    }

    private func toastView(_ toast: AppToast) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: SnipSnapSpacing.relatedContent) {
                Image(systemName: toast.systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.message)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let detail = toast.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if toast.action != nil {
                    AppPrimaryActionButton(presentation: .floatingGlass) {
                        self.toast = nil
                        onAction(toast)
                    } label: {
                        Text(toast.actionTitle)
                    }
                    .font(.subheadline.weight(.bold))
                    .controlSize(.small)
#if os(iOS)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
#endif
                    .accessibilityIdentifier("toast-action")
                    .accessibilityLabel(toast.actionAccessibilityLabel)
                    .focused($isActionFocused)
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
        .accessibilityLabel([toast.message, toast.detail].compactMap { $0 }.joined(separator: ". "))
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
        bottomInset: CGFloat = 0,
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
                bottomInset: bottomInset,
                onAction: onAction,
                onDismiss: onDismiss
            )
        )
    }

}

enum SnipSnapTheme {
    static let listGlassTintOpacity = 0.8
    static let listSelectionGlassTint = Color.primary.opacity(0.12)
    static let listEditorGlassTint = Color.primary.opacity(0.03)
    static func sendIconColor(tint: Color) -> Color {
        Color.white.mix(with: tint, by: 0.12)
    }

    /// Reserve the monochrome accent for active controls, selection,
    /// and one preferred action in a view.
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
    /// Matches `AccentColor.colorset`; defined in code so extensions without the
    /// asset catalog resolve the same accent.
    static let actionAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.92, alpha: 1)
            : UIColor(white: 0.16, alpha: 1)
    })
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

enum SnipSnapSpacing {
    static let relatedContent: CGFloat = 8
    static let controlContentInset: CGFloat = 10
    static let cardContentInset: CGFloat = 12
    static let paneContentInset: CGFloat = 16
}
