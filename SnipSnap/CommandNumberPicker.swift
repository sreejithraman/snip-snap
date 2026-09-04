import AppKit
import Carbon.HIToolbox
import SwiftUI

enum CommandNumberTarget: Hashable {
    case snip(UUID)
    case clipboardEntry(UUID)
}

enum CommandNumberLayout {
    static let maxCount = 9
    static let revealDelay: Duration = .milliseconds(200)

    static func visibleTargets(
        ordered: [CommandNumberTarget],
        frames: [CommandNumberTarget: CGRect],
        viewport: CGRect
    ) -> [CommandNumberTarget] {
        let intersecting = ordered.filter { target in
            guard let frame = frames[target] else { return false }
            return frame.intersects(viewport)
        }
        if !intersecting.isEmpty {
            return Array(intersecting.prefix(maxCount))
        }
        return Array(ordered.prefix(maxCount))
    }

    static func numbers(
        for targets: [CommandNumberTarget]
    ) -> [CommandNumberTarget: Int] {
        Dictionary(
            uniqueKeysWithValues: targets.prefix(maxCount).enumerated().map { index, target in
                (target, index + 1)
            }
        )
    }

    static func number(from event: NSEvent) -> Int? {
        if let value = number(fromCharacters: event.charactersIgnoringModifiers) {
            return value
        }
        return number(fromKeyCode: event.keyCode)
    }

    static func number(fromCharacters characters: String?) -> Int? {
        guard let characters, characters.count == 1,
              let value = characters.first?.wholeNumberValue,
              (1...maxCount).contains(value) else { return nil }
        return value
    }

    static func number(fromKeyCode keyCode: UInt16) -> Int? {
        switch Int(keyCode) {
        case kVK_ANSI_1, kVK_ANSI_Keypad1: 1
        case kVK_ANSI_2, kVK_ANSI_Keypad2: 2
        case kVK_ANSI_3, kVK_ANSI_Keypad3: 3
        case kVK_ANSI_4, kVK_ANSI_Keypad4: 4
        case kVK_ANSI_5, kVK_ANSI_Keypad5: 5
        case kVK_ANSI_6, kVK_ANSI_Keypad6: 6
        case kVK_ANSI_7, kVK_ANSI_Keypad7: 7
        case kVK_ANSI_8, kVK_ANSI_Keypad8: 8
        case kVK_ANSI_9, kVK_ANSI_Keypad9: 9
        default: nil
        }
    }
}

enum CommandNumberKeyHandling {
    enum Action: Equatable {
        case ignore
        case suppressReveal
        case pick(Int)
    }

    static func action(
        isEnabled: Bool,
        hasPureCommand: Bool,
        commandIsDown: Bool,
        number: Int?
    ) -> Action {
        guard isEnabled else { return .ignore }
        guard hasPureCommand else {
            return commandIsDown ? .suppressReveal : .ignore
        }
        guard let number else { return .suppressReveal }
        return .pick(number)
    }
}

@MainActor
final class CommandNumberPicker: ObservableObject {
    @Published private(set) var isRevealed = false
    @Published private(set) var numbers: [CommandNumberTarget: Int] = [:]

    private var isEnabled = true
    private var commandIsDown = false
    private var suppressUntilCommandUp = false
    private var orderedTargets: [CommandNumberTarget] = []
    private var frames: [CommandNumberTarget: CGRect] = [:]
    private var viewport: CGRect = .zero
    private var visibleTargets: [CommandNumberTarget] = []
    private var revealTask: Task<Void, Never>?
    private var monitor: Any?
    private var pickHandler: ((CommandNumberTarget) -> Void)?
    private let revealDelay: Duration

    init(revealDelay: Duration = CommandNumberLayout.revealDelay) {
        self.revealDelay = revealDelay
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            hide()
        }
    }

    func setOrderedTargets(_ targets: [CommandNumberTarget]) {
        orderedTargets = targets
        frames = frames.filter { targets.contains($0.key) }
        refreshVisibleTargets()
    }

    func setViewport(_ frame: CGRect) {
        guard viewport != frame else { return }
        viewport = frame
        refreshVisibleTargets()
    }

    func setRowFrame(_ target: CommandNumberTarget, frame: CGRect?) {
        if frames[target] == frame { return }
        frames[target] = frame
        refreshVisibleTargets()
    }

    func displayedNumber(for target: CommandNumberTarget) -> Int? {
        numbers[target]
    }

    func target(forNumber number: Int) -> CommandNumberTarget? {
        let index = number - 1
        guard visibleTargets.indices.contains(index) else { return nil }
        return visibleTargets[index]
    }

    func pick(_ target: CommandNumberTarget) {
        pickHandler?(target)
    }

    func pickDisplayedNumber(_ number: Int) {
        guard let target = target(forNumber: number) else { return }
        pick(target)
    }

    func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let hasPureCommand = press.modifiers.contains(.command)
            && !press.modifiers.contains(.shift)
            && !press.modifiers.contains(.option)
            && !press.modifiers.contains(.control)
        switch CommandNumberKeyHandling.action(
            isEnabled: isEnabled,
            hasPureCommand: hasPureCommand,
            commandIsDown: press.modifiers.contains(.command),
            number: press.characters.first.flatMap(\.wholeNumberValue)
        ) {
        case .ignore:
            return .ignored
        case .suppressReveal:
            noteNonDigitCommandKey()
            return .ignored
        case .pick(let number):
            guard target(forNumber: number) != nil else { return .ignored }
            pickDisplayedNumber(number)
            return .handled
        }
    }

    func noteNonDigitCommandKey() {
        guard commandIsDown else { return }
        suppressUntilCommandUp = true
        hide()
    }

    func handleCommand(isDown: Bool) {
        if !isDown {
            commandIsDown = false
            suppressUntilCommandUp = false
            hide()
            return
        }
        commandIsDown = true
        guard isEnabled, !suppressUntilCommandUp else { return }
        scheduleReveal()
    }

    func startMonitoring(onPick: @escaping (CommandNumberTarget) -> Void) {
        pickHandler = onPick
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            let consume = MainActor.assumeIsolated {
                self?.handle(event) ?? false
            }
            return consume ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        pickHandler = nil
        hide()
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.window is SnipSnapPanel else { return false }
        if event.type == .flagsChanged {
            handleCommand(isDown: Self.isPureCommand(event.modifierFlags))
            return false
        }
        guard event.type == .keyDown else { return false }
        return handleKeyDown(event)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch CommandNumberKeyHandling.action(
            isEnabled: isEnabled,
            hasPureCommand: Self.isPureCommand(event.modifierFlags),
            commandIsDown: event.modifierFlags.contains(.command),
            number: CommandNumberLayout.number(from: event)
        ) {
        case .ignore:
            return false
        case .suppressReveal:
            noteNonDigitCommandKey()
            return false
        case .pick(let number):
            pickDisplayedNumber(number)
            return true
        }
    }

    private func scheduleReveal() {
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if revealDelay > .zero {
                try? await Task.sleep(for: revealDelay)
            }
            guard !Task.isCancelled, commandIsDown, isEnabled, !suppressUntilCommandUp else {
                return
            }
            isRevealed = true
            publishNumbers()
        }
    }

    private func hide() {
        revealTask?.cancel()
        revealTask = nil
        guard isRevealed || !numbers.isEmpty else { return }
        isRevealed = false
        numbers = [:]
    }

    private func refreshVisibleTargets() {
        visibleTargets = CommandNumberLayout.visibleTargets(
            ordered: orderedTargets,
            frames: frames,
            viewport: viewport
        )
        if isRevealed {
            publishNumbers()
        }
    }

    private func publishNumbers() {
        numbers = CommandNumberLayout.numbers(for: visibleTargets)
    }

    private static func isPureCommand(_ flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .shift, .option, .control])
        return relevant == .command
    }

}

struct CommandNumberBadge: View {
    let number: Int

    var body: some View {
        Text(String(number))
            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(SnipSnapColors.textPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(
                    cornerRadius: PanelCardLeadingMetrics.cornerRadius,
                    style: .continuous
                )
                .fill(SnipSnapColors.compactActionFill)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: PanelCardLeadingMetrics.cornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(SnipSnapColors.contentCardEdge, lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }
}
