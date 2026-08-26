import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - Shortcut model

struct ShortcutKeyChord: Codable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init(keyCode: Int, modifiers: Int, keyLabel: String) {
        self.init(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(modifiers),
            keyLabel: keyLabel
        )
    }

    init?(event: NSEvent, allowsUnmodifiedSpecialKey: Bool = false) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbonModifiers = Self.carbonModifiers(from: flags)

        let label: String
        switch Int(event.keyCode) {
        case kVK_Space: label = "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: label = "Return"
        case kVK_Tab: label = "Tab"
        case kVK_Delete: label = "Delete"
        case kVK_ForwardDelete: label = "Forward Delete"
        case kVK_Escape: return nil
        case kVK_LeftArrow: label = "←"
        case kVK_RightArrow: label = "→"
        case kVK_UpArrow: label = "↑"
        case kVK_DownArrow: label = "↓"
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  !characters.isEmpty else { return nil }
            label = characters.uppercased()
        }
        if carbonModifiers == 0 {
            let unmodifiedKeys = [
                kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab,
                kVK_Delete, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow,
                kVK_UpArrow, kVK_DownArrow,
            ]
            guard allowsUnmodifiedSpecialKey,
                  unmodifiedKeys.contains(Int(event.keyCode)) else { return nil }
        }
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers,
            keyLabel: label
        )
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    static func == (lhs: ShortcutKeyChord, rhs: ShortcutKeyChord) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    var conflictsWithSystemCommand: Bool {
        let command = UInt32(cmdKey)
        guard modifiers == command else { return false }
        return [
            kVK_ANSI_Comma, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_Q, kVK_ANSI_W,
        ].contains(Int(keyCode))
    }

    var conflictsWithFixedCommand: Bool {
        let key = Int(keyCode)
        let command = UInt32(cmdKey)
        let commandShift = UInt32(cmdKey | shiftKey)
        if conflictsWithSystemCommand { return true }
        if modifiers == command {
            if [kVK_Return, kVK_ANSI_KeypadEnter].contains(key) { return true }
            return [
                kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_F, kVK_ANSI_S,
                kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_Slash,
            ].contains(key)
        }
        if modifiers == commandShift && key == kVK_ANSI_Z { return true }
        if modifiers == UInt32(shiftKey)
            && [kVK_Tab, kVK_UpArrow, kVK_DownArrow].contains(key) {
            return true
        }
        return modifiers == 0 && [
            kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab,
            kVK_Delete, kVK_ForwardDelete, kVK_LeftArrow,
            kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        ].contains(key)
    }

    var supportsAppCommand: Bool {
        switch Int(keyCode) {
        case kVK_Space: keyLabel == "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: keyLabel == "Return"
        case kVK_Tab: keyLabel == "Tab"
        case kVK_Delete: keyLabel == "Delete"
        case kVK_ForwardDelete: keyLabel == "Forward Delete"
        case kVK_Escape: false
        case kVK_LeftArrow: keyLabel == "←"
        case kVK_RightArrow: keyLabel == "→"
        case kVK_UpArrow: keyLabel == "↑"
        case kVK_DownArrow: keyLabel == "↓"
        default:
            keyLabel.count == 1
        }
    }

    var menuKeyEquivalent: String {
        switch Int(keyCode) {
        case kVK_Space: " "
        case kVK_Return, kVK_ANSI_KeypadEnter: "\r"
        case kVK_Tab: "\t"
        case kVK_Delete: String(UnicodeScalar(NSBackspaceCharacter)!)
        case kVK_ForwardDelete: String(UnicodeScalar(NSDeleteCharacter)!)
        case kVK_LeftArrow: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case kVK_RightArrow: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case kVK_UpArrow: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case kVK_DownArrow: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default: keyLabel.lowercased()
        }
    }

    var eventModifierFlags: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
        return result
    }

}

enum ShiftSide: String, Codable, Hashable, Sendable {
    case left
    case right

    var displayName: String {
        switch self {
        case .left: "Left ⇧ ⇧"
        case .right: "Right ⇧ ⇧"
        }
    }
}

enum ShortcutTrigger: Hashable, Sendable {
    case doubleShift(ShiftSide)
    case commandDoubleShift(ShiftSide)
    case keyChord(ShortcutKeyChord)

    static func keyChord(
        keyCode: UInt32,
        modifiers: UInt32,
        keyLabel: String
    ) -> ShortcutTrigger {
        .keyChord(
            ShortcutKeyChord(
                keyCode: keyCode,
                modifiers: modifiers,
                keyLabel: keyLabel
            )
        )
    }

    var chord: ShortcutKeyChord? {
        guard case .keyChord(let chord) = self else { return nil }
        return chord
    }

    var displayName: String {
        switch self {
        case .doubleShift(let side): side.displayName
        case .commandDoubleShift(let side): "⌘ \(side.displayName)"
        case .keyChord(let chord): chord.displayName
        }
    }
}

extension ShortcutTrigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case chord
        case side
    }

    private enum Kind: String, Codable {
        case doubleShift
        case commandDoubleShift
        case keyChord
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .doubleShift:
            guard !container.contains(.chord) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .chord,
                    in: container,
                    debugDescription: "Double Shift cannot contain a key chord."
                )
            }
            self = .doubleShift(try container.decode(ShiftSide.self, forKey: .side))
        case .commandDoubleShift:
            guard !container.contains(.chord) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .chord,
                    in: container,
                    debugDescription: "Command Double Shift cannot contain a key chord."
                )
            }
            self = .commandDoubleShift(
                try container.decode(ShiftSide.self, forKey: .side)
            )
        case .keyChord:
            guard !container.contains(.side) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .side,
                    in: container,
                    debugDescription: "A key chord cannot contain a Shift side."
                )
            }
            self = .keyChord(try container.decode(ShortcutKeyChord.self, forKey: .chord))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .doubleShift(let side):
            try container.encode(Kind.doubleShift, forKey: .kind)
            try container.encode(side, forKey: .side)
        case .commandDoubleShift(let side):
            try container.encode(Kind.commandDoubleShift, forKey: .kind)
            try container.encode(side, forKey: .side)
        case .keyChord(let chord):
            try container.encode(Kind.keyChord, forKey: .kind)
            try container.encode(chord, forKey: .chord)
        }
    }
}

struct GlobalShortcutConfiguration: Codable, Equatable, Sendable {
    var captureSelection: ShortcutTrigger
    var togglePanel: ShortcutTrigger
    var toggleClipboard: ShortcutTrigger

    init(
        captureSelection: ShortcutTrigger,
        togglePanel: ShortcutTrigger,
        toggleClipboard: ShortcutTrigger = GlobalHotKeyAction.toggleClipboard.defaultTrigger
    ) {
        self.captureSelection = captureSelection
        self.togglePanel = togglePanel
        self.toggleClipboard = toggleClipboard
    }

    static let snipSnapDefaults = GlobalShortcutConfiguration(
        captureSelection: .doubleShift(.left),
        togglePanel: .doubleShift(.right),
        toggleClipboard: GlobalHotKeyAction.toggleClipboard.defaultTrigger
    )

    func trigger(for action: GlobalHotKeyAction) -> ShortcutTrigger {
        switch action {
        case .captureSelection: captureSelection
        case .togglePanel: togglePanel
        case .toggleClipboard: toggleClipboard
        }
    }

    mutating func set(_ trigger: ShortcutTrigger, for action: GlobalHotKeyAction) {
        switch action {
        case .captureSelection: captureSelection = trigger
        case .togglePanel: togglePanel = trigger
        case .toggleClipboard: toggleClipboard = trigger
        }
    }

    var isValid: Bool {
        let triggers = GlobalHotKeyAction.allCases.map(trigger)
        guard Set(triggers).count == triggers.count else {
            return false
        }
        return triggers.allSatisfy { $0.chord?.conflictsWithFixedCommand != true }
    }

    var usesDoubleShift: Bool {
        GlobalHotKeyAction.allCases.contains {
            switch trigger(for: $0) {
            case .doubleShift, .commandDoubleShift: true
            case .keyChord: false
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case captureSelection
        case togglePanel
        // TODO: Remove after the 1.0 migration window.
        case legacyToggleInbox = "toggleInbox"
        case toggleClipboard
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureSelection = try container.decode(ShortcutTrigger.self, forKey: .captureSelection)
        togglePanel = try container.decodeIfPresent(
            ShortcutTrigger.self,
            forKey: .togglePanel
        ) ?? container.decode(ShortcutTrigger.self, forKey: .legacyToggleInbox)
        toggleClipboard = try container.decodeIfPresent(
            ShortcutTrigger.self,
            forKey: .toggleClipboard
        ) ?? GlobalHotKeyAction.toggleClipboard.defaultTrigger
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureSelection, forKey: .captureSelection)
        try container.encode(togglePanel, forKey: .togglePanel)
        try container.encode(toggleClipboard, forKey: .toggleClipboard)
    }
}

enum AppShortcutAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case toggleDone
    case merge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleDone: "Done or Not Done"
        case .merge: "Merge Snips"
        }
    }

    var defaultChord: ShortcutKeyChord {
        switch self {
        case .toggleDone: .init(keyCode: kVK_Space, modifiers: 0, keyLabel: "Space")
        case .merge: .init(keyCode: kVK_ANSI_M, modifiers: cmdKey | shiftKey, keyLabel: "M")
        }
    }
}

struct AppShortcutConfiguration: Codable, Equatable, Sendable {
    private var bindings: [AppShortcutAction: ShortcutKeyChord]

    static let snipSnapDefaults = AppShortcutConfiguration(
        bindings: Dictionary(uniqueKeysWithValues: AppShortcutAction.allCases.map {
            ($0, $0.defaultChord)
        })
    )

    init(bindings: [AppShortcutAction: ShortcutKeyChord]) {
        self.bindings = bindings
    }

    func chord(for action: AppShortcutAction) -> ShortcutKeyChord {
        bindings[action] ?? action.defaultChord
    }

    mutating func set(_ chord: ShortcutKeyChord, for action: AppShortcutAction) {
        bindings[action] = chord
    }

    var fillingMissingDefaults: AppShortcutConfiguration {
        var result = self
        for action in AppShortcutAction.allCases where result.bindings[action] == nil {
            result.bindings[action] = action.defaultChord
        }
        return result
    }

    var isValid: Bool {
        let chords = AppShortcutAction.allCases.map(chord)
        guard Set(chords).count == chords.count,
              chords.allSatisfy({ !$0.conflictsWithFixedCommand && $0.supportsAppCommand })
        else { return false }
        return !AppShortcutAction.allCases.contains { action in
            AppShortcutAction.allCases.contains { otherAction in
                otherAction != action && chord(for: action) == otherAction.defaultChord
            }
        }
    }
}

enum ShortcutSettingsError: Error, Equatable, LocalizedError {
    case duplicate
    case defaultForAnotherAction
    case reserved

    var errorDescription: String? {
        switch self {
        case .duplicate: "Another action already uses that shortcut."
        case .defaultForAnotherAction: "That shortcut is another action's default."
        case .reserved: "macOS or a fixed Snip Snap command uses that shortcut."
        }
    }
}

@MainActor
final class ShortcutSettings: ObservableObject {
    private static let globalStorageKey = "globalShortcutConfiguration"
    private static let appStorageKey = "appShortcutConfiguration"

    @Published private(set) var configuration: GlobalShortcutConfiguration
    @Published private(set) var appConfiguration: AppShortcutConfiguration
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedGlobalData = defaults.data(forKey: Self.globalStorageKey)
        let storedAppData = defaults.data(forKey: Self.appStorageKey)
        let decodedGlobal = storedGlobalData
            .flatMap { try? JSONDecoder().decode(GlobalShortcutConfiguration.self, from: $0) }
        let decodedApp = storedAppData
            .flatMap { try? JSONDecoder().decode(AppShortcutConfiguration.self, from: $0) }
        let validDecodedGlobal = decodedGlobal.flatMap { $0.isValid ? $0 : nil }
        var resolvedGlobal = validDecodedGlobal ?? .snipSnapDefaults
        var resolvedApp = (decodedApp ?? .snipSnapDefaults).fillingMissingDefaults
        if !resolvedApp.isValid {
            resolvedApp = .snipSnapDefaults
        }

        if !Self.isValid(global: resolvedGlobal, app: resolvedApp) {
            let globalChords = Set(GlobalHotKeyAction.allCases.compactMap {
                resolvedGlobal.trigger(for: $0).chord
            })
            for action in AppShortcutAction.allCases
            where globalChords.contains(resolvedApp.chord(for: action)) {
                resolvedApp.set(action.defaultChord, for: action)
            }
        }
        if !Self.isValid(global: resolvedGlobal, app: resolvedApp) {
            let appChords = Set(AppShortcutAction.allCases.map(resolvedApp.chord))
                .union(AppShortcutAction.allCases.map(\.defaultChord))
            for action in GlobalHotKeyAction.allCases
            where resolvedGlobal.trigger(for: action).chord.map(appChords.contains) == true {
                resolvedGlobal.set(action.defaultTrigger, for: action)
            }
        }
        if !Self.isValid(global: resolvedGlobal, app: resolvedApp) {
            resolvedGlobal = .snipSnapDefaults
            resolvedApp = .snipSnapDefaults
        }

        configuration = resolvedGlobal
        appConfiguration = resolvedApp

        if storedGlobalData != nil, decodedGlobal != resolvedGlobal,
           let data = try? JSONEncoder().encode(resolvedGlobal) {
            defaults.set(data, forKey: Self.globalStorageKey)
        }
        if storedAppData != nil, decodedApp != resolvedApp,
           let data = try? JSONEncoder().encode(resolvedApp) {
            defaults.set(data, forKey: Self.appStorageKey)
        }
    }

    func candidate(
        setting trigger: ShortcutTrigger,
        for action: GlobalHotKeyAction
    ) throws -> GlobalShortcutConfiguration {
        if trigger.chord?.conflictsWithFixedCommand == true {
            throw ShortcutSettingsError.reserved
        }
        for otherAction in GlobalHotKeyAction.allCases where otherAction != action {
            if otherAction.defaultTrigger == trigger {
                throw ShortcutSettingsError.defaultForAnotherAction
            }
            if configuration.trigger(for: otherAction) == trigger {
                throw ShortcutSettingsError.duplicate
            }
        }
        if let chord = trigger.chord,
           AppShortcutAction.allCases.contains(where: { $0.defaultChord == chord }) {
            throw ShortcutSettingsError.defaultForAnotherAction
        }
        if let chord = trigger.chord,
           AppShortcutAction.allCases.contains(where: { appConfiguration.chord(for: $0) == chord }) {
            throw ShortcutSettingsError.duplicate
        }
        var candidate = configuration
        candidate.set(trigger, for: action)
        return candidate
    }

    func candidate(
        setting chord: ShortcutKeyChord,
        for action: AppShortcutAction
    ) throws -> AppShortcutConfiguration {
        if chord.conflictsWithFixedCommand || !chord.supportsAppCommand {
            throw ShortcutSettingsError.reserved
        }
        for otherAction in AppShortcutAction.allCases where otherAction != action {
            if otherAction.defaultChord == chord {
                throw ShortcutSettingsError.defaultForAnotherAction
            }
            if appConfiguration.chord(for: otherAction) == chord {
                throw ShortcutSettingsError.duplicate
            }
        }
        if GlobalHotKeyAction.allCases.contains(where: {
            configuration.trigger(for: $0).chord == chord
        }) {
            throw ShortcutSettingsError.duplicate
        }
        var candidate = appConfiguration
        candidate.set(chord, for: action)
        return candidate
    }

    func save(_ configuration: GlobalShortcutConfiguration) {
        self.configuration = configuration
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.globalStorageKey)
        }
    }

    func save(_ configuration: AppShortcutConfiguration) {
        appConfiguration = configuration
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.appStorageKey)
        }
    }

    func chord(for action: AppShortcutAction) -> ShortcutKeyChord {
        appConfiguration.chord(for: action)
    }

    func reset(_ action: AppShortcutAction) throws {
        save(try candidate(setting: action.defaultChord, for: action))
    }

    private static func isValid(
        global: GlobalShortcutConfiguration,
        app: AppShortcutConfiguration
    ) -> Bool {
        guard global.isValid, app.isValid else { return false }
        let globalChords = Set(GlobalHotKeyAction.allCases.compactMap {
            global.trigger(for: $0).chord
        })
        let appChords = Set(AppShortcutAction.allCases.map(app.chord))
        let appDefaults = Set(AppShortcutAction.allCases.map(\.defaultChord))
        guard globalChords.isDisjoint(with: appChords),
              globalChords.isDisjoint(with: appDefaults)
        else { return false }
        return !GlobalHotKeyAction.allCases.contains { action in
            GlobalHotKeyAction.allCases.contains { otherAction in
                otherAction != action
                    && global.trigger(for: action) == otherAction.defaultTrigger
            }
        }
    }
}

enum GlobalHotKeyAction: UInt32, CaseIterable, Identifiable {
    case captureSelection = 1
    case togglePanel = 2
    case toggleClipboard = 3

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .captureSelection: "Capture Selection"
        case .togglePanel: "Open or Hide Snip Snap"
        case .toggleClipboard: "Open or Hide Clipboard"
        }
    }

    var defaultTrigger: ShortcutTrigger {
        switch self {
        case .captureSelection: .doubleShift(.left)
        case .togglePanel: .doubleShift(.right)
        case .toggleClipboard: .commandDoubleShift(.right)
        }
    }
}

enum GlobalHotKeyError: Error, LocalizedError {
    case eventHandler(OSStatus)
    case registration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandler:
            "Snip Snap could not start keyboard shortcut handling."
        case .registration:
            "macOS could not register that shortcut. Another app may already use it."
        }
    }
}
