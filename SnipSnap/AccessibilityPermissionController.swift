import AppKit
import Combine
import Foundation

enum AccessibilitySetupCardState {
    case initial
    case needsRepair

    static let repairInstructions = "In System Settings, turn on Snip Snap under Privacy & Security › Accessibility. If it is missing, use the Add button."

    var presentation: AccessibilitySetupCardPresentation {
        switch self {
        case .initial:
            AccessibilitySetupCardPresentation(
                title: "Finish Setting Up Selection Capture",
                message: "Allow Accessibility so Snip Snap can detect Shift shortcuts and capture selected content in other apps.",
                primaryActionTitle: "Allow Access",
                showsRepairInstructions: false
            )
        case .needsRepair:
            AccessibilitySetupCardPresentation(
                title: "Accessibility Is Still Off",
                message: Self.repairInstructions,
                primaryActionTitle: "Open System Settings",
                showsRepairInstructions: true
            )
        }
    }
}

struct AccessibilitySetupCardPresentation {
    let title: String
    let message: String
    let primaryActionTitle: String
    let showsRepairInstructions: Bool
}

@MainActor
final class AccessibilityPermissionController: ObservableObject {
    static let didHandleSetupDefaultsKey = "didHandleAccessibilitySetup"
    static let didRequestAccessDefaultsKey = "didRequestAccessibilityAccess"

    @Published private(set) var isGranted: Bool
    @Published private(set) var isSetupCardVisible: Bool
    @Published private(set) var hasRequestedAccess: Bool
    @Published var isRepairPresented = false

    var onBecameGranted: (() -> Void)?

    var setupCardState: AccessibilitySetupCardState {
        hasRequestedAccess ? .needsRepair : .initial
    }

    var menuActionTitle: String {
        if isGranted {
            return "Accessibility Settings…"
        }

        switch setupCardState {
        case .initial:
            return "Allow Accessibility Access…"
        case .needsRepair:
            return "Open Accessibility Settings…"
        }
    }

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let isTrusted: () -> Bool
    private let requestTrust: () -> Void
    private let openSettingsAction: () -> Void
    private nonisolated(unsafe) var applicationDidBecomeActiveObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        isTrusted: @escaping () -> Bool,
        requestTrust: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.isTrusted = isTrusted
        self.requestTrust = requestTrust
        self.openSettingsAction = openSettings

        let granted = isTrusted()
        isGranted = granted
        hasRequestedAccess = defaults.bool(forKey: Self.didRequestAccessDefaultsKey)
        isSetupCardVisible = !granted
            && !defaults.bool(forKey: Self.didHandleSetupDefaultsKey)
    }

    func start() {
        refresh()
        guard applicationDidBecomeActiveObserver == nil else { return }
        applicationDidBecomeActiveObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    @discardableResult
    func refresh() -> Bool {
        let wasGranted = isGranted
        isGranted = isTrusted()
        if isGranted {
            isSetupCardVisible = false
            isRepairPresented = false
        }
        if !wasGranted && isGranted {
            onBecameGranted?()
        }
        return isGranted
    }

    func requestAccess() {
        markSetupHandledAndRequested()
        isSetupCardVisible = true
        isRepairPresented = false
        requestTrust()
    }

    func openSettings() {
        markSetupHandledAndRequested()
        isRepairPresented = false
        openSettingsAction()
    }

    func deferSetup() {
        defaults.set(true, forKey: Self.didHandleSetupDefaultsKey)
        isSetupCardVisible = false
    }

    func presentRepair() {
        isRepairPresented = true
    }

    func performPrimaryAction() {
        switch setupCardState {
        case .initial:
            requestAccess()
        case .needsRepair:
            openSettings()
        }
    }

    func performMenuAction() {
        if isGranted {
            openSettings()
        } else {
            performPrimaryAction()
        }
    }

    private func markSetupHandledAndRequested() {
        defaults.set(true, forKey: Self.didHandleSetupDefaultsKey)
        defaults.set(true, forKey: Self.didRequestAccessDefaultsKey)
        hasRequestedAccess = true
    }

    deinit {
        if let applicationDidBecomeActiveObserver {
            notificationCenter.removeObserver(applicationDidBecomeActiveObserver)
        }
    }

}
