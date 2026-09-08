import SwiftUI
import UIKit

@MainActor
@Observable
final class IOSHapticFeedback {
    // Outcomes retain their source; meanings define the shared tactile policy.
    enum Kind: Equatable, CaseIterable {
        case selection, snap, saved, copied, markedDone, reopened, deleted, restored, moved, merged, warning, error

        var meaning: Meaning {
            switch self {
            case .selection: .selectionChanged
            case .snap: .gestureCommitted
            case .saved, .copied, .markedDone, .reopened, .deleted, .restored, .moved: .actionCompleted
            case .merged: .significantSuccess
            case .warning: .warning
            case .error: .error
            }
        }
    }

    enum Meaning: Equatable {
        case selectionChanged, gestureCommitted, actionCompleted, significantSuccess, warning, error
    }

    struct Event: Equatable {
        let id = UUID()
        let kinds: [Kind]

        // A compound result gets one system response; failures take precedence.
        var kind: Kind {
            if kinds.contains(.error) { return .error }
            if kinds.contains(.warning) { return .warning }
            return kinds.last ?? .selection
        }
    }

    static let preferenceKey = "snip-haptics-enabled"
    private let player: any IOSHapticPlaying
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

    init(defaults: UserDefaults = .standard, player: any IOSHapticPlaying = IOSSystemHapticPlayer()) {
        self.player = player
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
        emit([kind], for: interaction)
    }

    func emit(_ kinds: [Kind], for interaction: UUID?) {
        guard !kinds.isEmpty, let interaction, interaction == interactionID,
              isEnabled, isActive, !Task.isCancelled else { return }
        let result = Event(kinds: kinds)
        player.play(result.kind.meaning)
        event = result
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
            .onAppear { feedback.isActive = scenePhase == .active }
            .onChange(of: scenePhase) { _, phase in
                feedback.isActive = phase == .active
            }
            .onDisappear { feedback.isActive = false }
    }
}

// Actions report outcomes; this adapter makes one direct system feedback call.
@MainActor
protocol IOSHapticPlaying {
    func play(_ meaning: IOSHapticFeedback.Meaning)
}

@MainActor
final class IOSSystemHapticPlayer: IOSHapticPlaying {
    private let selection = UISelectionFeedbackGenerator()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    func play(_ meaning: IOSHapticFeedback.Meaning) {
        switch meaning {
        case .selectionChanged: selection.selectionChanged()
        case .gestureCommitted: medium.impactOccurred()
        case .actionCompleted: light.impactOccurred()
        case .significantSuccess: notification.notificationOccurred(.success)
        case .warning: notification.notificationOccurred(.warning)
        case .error: notification.notificationOccurred(.error)
        }
    }
}
