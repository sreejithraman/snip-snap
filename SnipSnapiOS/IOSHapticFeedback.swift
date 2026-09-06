import SwiftUI

@MainActor
@Observable
final class IOSHapticFeedback {
    enum Kind: Equatable {
        case selection, success, warning, error

        var sensoryFeedback: SensoryFeedback {
            switch self {
            case .selection: .selection
            case .success: .success
            case .warning: .warning
            case .error: .error
            }
        }
    }

    struct Event: Equatable {
        let id = UUID()
        let kind: Kind
    }

    static let preferenceKey = "snip-haptics-enabled"
    private let defaults: UserDefaults
    private let storedPreferenceKey: String
    private var interactionID = UUID()
    private(set) var event: Event?

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: storedPreferenceKey)
            if !isEnabled { invalidatePendingFeedback() }
        }
    }

    var isActive = false {
        didSet {
            if !isActive { invalidatePendingFeedback() }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
#if DEBUG
        if let store = ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_STORE"] {
            storedPreferenceKey = "\(Self.preferenceKey)-\(store)"
        } else {
            storedPreferenceKey = Self.preferenceKey
        }
#else
        storedPreferenceKey = Self.preferenceKey
#endif
        isEnabled = defaults.object(forKey: storedPreferenceKey) as? Bool ?? true
    }

    func beginInteraction() -> UUID? {
        guard isEnabled, isActive, !Task.isCancelled else { return nil }
        interactionID = UUID()
        return interactionID
    }

    func emit(_ kind: Kind, for interaction: UUID?) {
        guard let interaction, interaction == interactionID,
              isEnabled, isActive, !Task.isCancelled else { return }
        event = Event(kind: kind)
    }

    // Leaving a flow must not let its pending work produce a late haptic.
    func invalidatePendingFeedback() {
        interactionID = UUID()
    }
}

struct IOSHapticFeedbackModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let feedback: IOSHapticFeedback

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: feedback.event) { _, event in
                guard feedback.isEnabled, feedback.isActive, scenePhase == .active else { return nil }
                return event?.kind.sensoryFeedback
            }
            .onAppear { feedback.isActive = scenePhase == .active }
            .onChange(of: scenePhase) { _, phase in
                feedback.isActive = phase == .active
            }
            .onDisappear { feedback.isActive = false }
    }
}
