import XCTest
import AppKit
import SnipSnapCore
import Carbon.HIToolbox
@testable import SnipSnap

final class ShortcutTests: StoreBackedTestCase {
    func testShortcutSettingsOnlyExposeSnipSnapSpecificCommands() {
        XCTAssertEqual(GlobalHotKeyAction.allCases, [.captureSelection, .togglePanel, .toggleClipboard])
        XCTAssertEqual(AppShortcutAction.allCases, [.toggleDone, .merge])
        // Saved shortcut settings encode this value.
        XCTAssertEqual(AppShortcutAction.toggleDone.rawValue, "toggleDone")
    }

    func testCompletionCommandsUseSharedDoneLanguage() {
        XCTAssertEqual(SnipCompletionLanguage.stateTitle(isDone: true), "Done")
        XCTAssertEqual(SnipCompletionLanguage.stateTitle(isDone: false), "Not Done")
        XCTAssertEqual(SnipCompletionLanguage.actionTitle(isDone: true), "Not Done")
        XCTAssertEqual(SnipCompletionLanguage.menuActionTitle(isDone: true), "Mark Not Done")
        XCTAssertEqual(SnipCompletionLanguage.menuActionTitle(isDone: false), "Mark Done")
        XCTAssertEqual(SnipCommand.toggleDone.title(allSelectedAreDone: false), "Done")
        XCTAssertEqual(SnipCommand.toggleDone.title(allSelectedAreDone: true), "Not Done")
    }

    func testSharedCatalogCoversEveryListIconAndTheInboxName() {
        XCTAssertEqual(SnipList.inbox.displayName, "Inbox")
        var renamedInbox = SnipList.inbox
        renamedInbox.name = "Desk"
        XCTAssertEqual(renamedInbox.displayName, "Desk")

        let icons = Set(SnipListIconOptions.categories.flatMap(\.icons))
        XCTAssertFalse(icons.isEmpty)
        for icon in icons {
            let key = "icon.\(icon)"
            XCTAssertNotEqual(
                Bundle.main.localizedString(forKey: key, value: nil, table: nil),
                key,
                "Missing catalog entry for \(icon)"
            )
        }
    }

    func testSnipSnapShortcutDefaultsUseLeftAndRightShiftActions() {
        let defaults = GlobalShortcutConfiguration.snipSnapDefaults

        XCTAssertEqual(defaults.captureSelection, .doubleShift(.left))
        XCTAssertEqual(defaults.togglePanel, .doubleShift(.right))
        XCTAssertEqual(defaults.toggleClipboard, .commandDoubleShift(.left))
        XCTAssertEqual(defaults.captureSelection.displayName, "Left ⇧ ⇧")
        XCTAssertEqual(defaults.togglePanel.displayName, "Right ⇧ ⇧")
        XCTAssertEqual(defaults.toggleClipboard.displayName, "⌘ Left ⇧ ⇧")
        XCTAssertTrue(defaults.isValid)
    }

    func testShortcutEncodingPreservesShiftSides() throws {
        let defaults = GlobalShortcutConfiguration.snipSnapDefaults

        let data = try JSONEncoder().encode(defaults)
        let decoded = try JSONDecoder().decode(GlobalShortcutConfiguration.self, from: data)

        XCTAssertEqual(decoded, defaults)
    }

    func testOldGlobalShortcutSettingsGainTheClipboardDefault() throws {
        let oldSettings = Data(
            """
            {
              "captureSelection": {"kind": "doubleShift", "side": "left"},
              "togglePanel": {"kind": "doubleShift", "side": "right"}
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(
            GlobalShortcutConfiguration.self,
            from: oldSettings
        )

        XCTAssertEqual(decoded, .snipSnapDefaults)
    }

    @MainActor
    func testClipboardShortcutCanBeReassignedAndRestored() throws {
        let suiteName = "Snip SnapClipboardShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ShortcutSettings(defaults: defaults)
        let custom = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "K"
        )

        for trigger in [custom, .commandDoubleShift(.right)] {
            settings.save(try settings.candidate(setting: trigger, for: .toggleClipboard))
            XCTAssertEqual(
                ShortcutSettings(defaults: defaults).configuration.toggleClipboard,
                trigger
            )
        }

        settings.save(try settings.candidate(
            setting: GlobalHotKeyAction.toggleClipboard.defaultTrigger,
            for: .toggleClipboard
        ))
        XCTAssertEqual(
            ShortcutSettings(defaults: defaults).configuration.toggleClipboard,
            .commandDoubleShift(.left)
        )
    }

    @MainActor
    func testNewClipboardDefaultPreservesPriorAssignments() throws {
        let suiteName = "Snip SnapPriorShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var global = GlobalShortcutConfiguration.snipSnapDefaults
        global.captureSelection = .commandDoubleShift(.left)
        global.toggleClipboard = .commandDoubleShift(.right)
        var app = AppShortcutConfiguration.snipSnapDefaults
        app.set(.init(keyCode: kVK_ANSI_L, modifiers: cmdKey | shiftKey, keyLabel: "L"), for: .toggleDone)
        let globalData = try JSONEncoder().encode(global)
        let appData = try JSONEncoder().encode(app)
        defaults.set(globalData, forKey: "globalShortcutConfiguration")
        defaults.set(appData, forKey: "appShortcutConfiguration")

        let settings = ShortcutSettings(defaults: defaults)
        XCTAssertEqual(settings.configuration, global)
        XCTAssertEqual(settings.appConfiguration, app)
        XCTAssertEqual(defaults.data(forKey: "globalShortcutConfiguration"), globalData)
        XCTAssertEqual(defaults.data(forKey: "appShortcutConfiguration"), appData)
        XCTAssertThrowsError(try settings.candidate(
            setting: GlobalHotKeyAction.toggleClipboard.defaultTrigger,
            for: .toggleClipboard
        )) { error in
            XCTAssertEqual(error as? ShortcutSettingsError, .duplicate)
        }
    }

    func testDoubleShiftDetectorRequiresTwoCleanTaps() {
        var detector = DoubleShiftDetector()

        XCTAssertFalse(detector.shiftChanged(isDown: true, timestamp: 1.00))
        XCTAssertFalse(detector.shiftChanged(isDown: false, timestamp: 1.08))
        XCTAssertTrue(detector.shiftChanged(isDown: true, timestamp: 1.22))

        detector.cancel()
        XCTAssertFalse(detector.shiftChanged(isDown: true, timestamp: 2.00))
        XCTAssertFalse(detector.shiftChanged(isDown: false, timestamp: 2.08))
        detector.cancel()
        XCTAssertFalse(detector.shiftChanged(isDown: true, timestamp: 2.18))

        detector.cancel()
        XCTAssertFalse(detector.shiftChanged(isDown: true, timestamp: 3.00))
        detector.cancel()
        XCTAssertFalse(detector.shiftChanged(isDown: false, timestamp: 3.05))
        XCTAssertFalse(detector.shiftChanged(isDown: true, timestamp: 3.15))

        detector.cancel()
        XCTAssertFalse(detector.shiftChanged(isDown: true, timestamp: 4.00))
        XCTAssertFalse(detector.shiftChanged(isDown: false, timestamp: 4.08))
        XCTAssertFalse(detector.shiftChanged(isDown: true, timestamp: 4.50))
    }

    func testDoubleShiftMonitorSeesKeyReleaseBetweenShiftTaps() {
        XCTAssertTrue(DoubleShiftRouter.eventMask.isSuperset(of: [.flagsChanged, .keyDown, .keyUp]))
    }

    @MainActor
    func testMouseInteractionsCancelDoubleShiftBeforeItCanRunAnAction() throws {
        var actions: [GlobalHotKeyAction] = []
        let manager = GlobalHotKeyManager { actions.append($0) }
        try manager.register(configuration: .snipSnapDefaults)
        defer { manager.unregister() }
        let pointerTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged, .scrollWheel
        ]
        for (index, type) in pointerTypes.enumerated() {
            actions.removeAll()
            let start = Double(index * 2)
            manager.receiveForDoubleShift(keyEvent(
                type: .flagsChanged, flags: .shift, timestamp: start, keyCode: UInt16(kVK_Shift)
            ))
            let cgEvent = try XCTUnwrap(CGEvent(source: nil))
            cgEvent.type = type
            let pointer = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            let mask = NSEvent.EventTypeMask(rawValue: UInt64(1) << pointer.type.rawValue)
            if DoubleShiftRouter.eventMask.contains(mask) {
                manager.receiveForDoubleShift(pointer)
            }
            manager.receiveForDoubleShift(keyEvent(
                type: .flagsChanged, flags: [], timestamp: start + 0.08, keyCode: UInt16(kVK_Shift)
            ))
            manager.receiveForDoubleShift(keyEvent(
                type: .flagsChanged, flags: .shift, timestamp: start + 0.20, keyCode: UInt16(kVK_Shift)
            ))

            XCTAssertTrue(actions.isEmpty, "Mouse interaction \(type) must cancel the pending tap")

            manager.receiveForDoubleShift(keyEvent(
                type: .flagsChanged, flags: [], timestamp: start + 0.28, keyCode: UInt16(kVK_Shift)
            ))
            manager.receiveForDoubleShift(keyEvent(
                type: .flagsChanged, flags: .shift, timestamp: start + 0.40, keyCode: UInt16(kVK_Shift)
            ))
            XCTAssertEqual(actions, [.captureSelection], "Two clean taps should still work after \(type)")
        }
    }

    @MainActor
    func testRecorderCapturesCommandDoubleRightShiftForClipboard() {
        let button = ShortcutRecorderButton.RecorderButton()
        button.allowsDoubleShift = true
        var recorded: ShortcutTrigger?
        button.onRecord = { recorded = $0 }
        button.performClick(nil)

        for (flags, time) in [
            (NSEvent.ModifierFlags([.command, .shift]), 1.00),
            ([.command], 1.08),
            ([.command, .shift], 1.20),
        ] {
            button.flagsChanged(with: keyEvent(
                type: .flagsChanged,
                flags: flags,
                timestamp: time,
                keyCode: UInt16(kVK_RightShift)
            ))
        }

        XCTAssertEqual(recorded, .commandDoubleShift(.right))
    }

    @MainActor
    func testRecordingExistingShiftShortcutDoesNotRunItsGlobalAction() throws {
        var actions: [GlobalHotKeyAction] = []
        let manager = GlobalHotKeyManager { actions.append($0) }
        try manager.register(configuration: .snipSnapDefaults)
        defer { manager.unregister() }

        let button = ShortcutRecorderButton.RecorderButton()
        button.allowsDoubleShift = true
        var recorded: ShortcutTrigger?
        button.onRecord = { recorded = $0 }
        button.performClick(nil)

        for (flags, time) in [
            (NSEvent.ModifierFlags([.command, .shift]), 1.00),
            ([.command], 1.08),
            ([.command, .shift], 1.20),
        ] {
            let event = keyEvent(
                type: .flagsChanged,
                flags: flags,
                timestamp: time,
                keyCode: UInt16(kVK_Shift)
            )
            manager.receiveForDoubleShift(event)
            button.flagsChanged(with: event)
        }

        XCTAssertEqual(recorded, .commandDoubleShift(.left))
        XCTAssertTrue(actions.isEmpty)

        for (flags, time) in [
            (NSEvent.ModifierFlags([.command, .shift]), 2.00),
            ([.command], 2.08),
            ([.command, .shift], 2.20),
        ] {
            manager.receiveForDoubleShift(keyEvent(
                type: .flagsChanged,
                flags: flags,
                timestamp: time,
                keyCode: UInt16(kVK_Shift)
            ))
        }
        XCTAssertEqual(actions, [.toggleClipboard])
    }

    @MainActor
    func testLeavingShortcutSettingsRestoresGlobalShortcuts() throws {
        var actions: [GlobalHotKeyAction] = []
        let manager = GlobalHotKeyManager { actions.append($0) }
        try manager.register(configuration: .snipSnapDefaults)
        defer { manager.unregister() }

        let button = ShortcutRecorderButton.RecorderButton()
        button.allowsDoubleShift = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = button
        button.performClick(nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

        for (flags, time) in [
            (NSEvent.ModifierFlags([.command, .shift]), 1.00),
            ([.command], 1.08),
            ([.command, .shift], 1.20),
        ] {
            manager.receiveForDoubleShift(keyEvent(
                type: .flagsChanged,
                flags: flags,
                timestamp: time,
                keyCode: UInt16(kVK_Shift)
            ))
        }
        XCTAssertEqual(actions, [.toggleClipboard])
    }

    @MainActor
    func testRegisteringAgainReplacesThePreviousShortcuts() throws {
        let first = ShortcutKeyChord.globalShortcutTestChord(keyCode: kVK_ANSI_J, keyLabel: "J")
        let second = ShortcutKeyChord.globalShortcutTestChord(keyCode: kVK_ANSI_L, keyLabel: "L")
        try requireAvailableChords(first, second)
        let manager = GlobalHotKeyManager { _ in }
        defer { manager.unregister() }
        var configuration = GlobalShortcutConfiguration.snipSnapDefaults

        configuration.set(.keyChord(first), for: .togglePanel)
        try manager.register(configuration: configuration)
        configuration.set(.keyChord(second), for: .togglePanel)
        try manager.register(configuration: configuration)

        XCTAssertTrue(first.isAvailableToRegister, "Registering again must release the previous chords")
        XCTAssertFalse(second.isAvailableToRegister)
        manager.unregister()
        XCTAssertTrue(second.isAvailableToRegister)
    }

    @MainActor
    func testFailedRegistrationReleasesTheShortcutsItAlreadyTook() throws {
        let taken = ShortcutKeyChord.globalShortcutTestChord(keyCode: kVK_ANSI_U, keyLabel: "U")
        let occupied = ShortcutKeyChord.globalShortcutTestChord(keyCode: kVK_ANSI_Y, keyLabel: "Y")
        try requireAvailableChords(taken, occupied)
        let manager = GlobalHotKeyManager { _ in }
        defer { manager.unregister() }
        var configuration = GlobalShortcutConfiguration.snipSnapDefaults
        configuration.set(.keyChord(taken), for: .togglePanel)
        configuration.set(.keyChord(occupied), for: .toggleClipboard)
        var occupant: EventHotKeyRef? = try XCTUnwrap(occupied.hold())
        defer { releaseHeldChord(&occupant) }

        XCTAssertThrowsError(try manager.register(configuration: configuration))
        XCTAssertTrue(taken.isAvailableToRegister, "A failed registration must release chords it already took")

        releaseHeldChord(&occupant)
        try manager.register(configuration: configuration)
        XCTAssertFalse(taken.isAvailableToRegister)
        XCTAssertFalse(occupied.isAvailableToRegister)

        manager.unregister()
        XCTAssertTrue(taken.isAvailableToRegister)
        XCTAssertTrue(occupied.isAvailableToRegister)
    }

    @MainActor
    func testRegisteredKeyChordRunsItsActionUnlessRecording() throws {
        let chord = ShortcutKeyChord.globalShortcutTestChord(keyCode: kVK_ANSI_P, keyLabel: "P")
        try requireAvailableChords(chord)
        var actions: [GlobalHotKeyAction] = []
        let manager = GlobalHotKeyManager { actions.append($0) }
        var configuration = GlobalShortcutConfiguration.snipSnapDefaults
        configuration.set(.keyChord(chord), for: .togglePanel)
        try manager.register(configuration: configuration)
        defer { manager.unregister() }

        XCTAssertEqual(try sendHotKeyPressed(.togglePanel), OSStatus(noErr))
        XCTAssertEqual(actions, [.togglePanel])

        let recorder = NSObject()
        ShortcutRecordingState.begin(recorder)
        defer { ShortcutRecordingState.end(recorder) }
        XCTAssertEqual(try sendHotKeyPressed(.togglePanel), OSStatus(noErr))
        XCTAssertEqual(actions, [.togglePanel], "Recording must suspend global key chords")
        ShortcutRecordingState.end(recorder)
    }

    func testKeyReleaseBetweenShiftTapsCancelsDoubleShift() {
        let left = DoubleShiftGesture(side: .left, modifier: .none)
        var router = DoubleShiftRouter(gestures: [left])

        XCTAssertNil(router.receive(keyEvent(
            type: .flagsChanged,
            flags: .shift,
            timestamp: 0.00,
            keyCode: UInt16(kVK_Shift)
        )))
        XCTAssertNil(router.receive(keyEvent(
            type: .flagsChanged,
            flags: [],
            timestamp: 0.08,
            keyCode: UInt16(kVK_Shift)
        )))
        XCTAssertEqual(router.receive(keyEvent(
            type: .flagsChanged,
            flags: .shift,
            timestamp: 0.20,
            keyCode: UInt16(kVK_Shift)
        )), left)
        XCTAssertNil(router.receive(keyEvent(
            type: .flagsChanged,
            flags: [],
            timestamp: 0.28,
            keyCode: UInt16(kVK_Shift)
        )))

        XCTAssertNil(router.receive(keyEvent(
            type: .flagsChanged,
            flags: .shift,
            timestamp: 1.00,
            keyCode: UInt16(kVK_Shift)
        )))
        XCTAssertNil(router.receive(keyEvent(
            type: .flagsChanged,
            flags: [],
            timestamp: 1.08,
            keyCode: UInt16(kVK_Shift)
        )))
        XCTAssertNil(router.receive(keyEvent(
            type: .keyUp,
            flags: [],
            timestamp: 1.12,
            keyCode: UInt16(kVK_ANSI_A)
        )))
        XCTAssertNil(router.receive(keyEvent(
            type: .flagsChanged,
            flags: .shift,
            timestamp: 1.20,
            keyCode: UInt16(kVK_Shift)
        )))
    }

    func testDoubleShiftRouterKeepsLeftAndRightGesturesSeparate() {
        let left = DoubleShiftGesture(side: .left, modifier: .none)
        let right = DoubleShiftGesture(side: .right, modifier: .none)
        var router = DoubleShiftRouter(gestures: [left, right])

        XCTAssertFalse(router.shiftChanged(
            gesture: left,
            isDown: true,
            timestamp: 1.00
        ))
        XCTAssertFalse(router.shiftChanged(
            gesture: left,
            isDown: false,
            timestamp: 1.08
        ))
        XCTAssertFalse(router.shiftChanged(
            gesture: right,
            isDown: true,
            timestamp: 1.16
        ))
        XCTAssertFalse(router.shiftChanged(
            gesture: right,
            isDown: false,
            timestamp: 1.24
        ))
        XCTAssertFalse(router.shiftChanged(
            gesture: left,
            isDown: true,
            timestamp: 1.32
        ))

        router.cancel()
        XCTAssertFalse(router.shiftChanged(
            gesture: right,
            isDown: true,
            timestamp: 2.00
        ))
        XCTAssertFalse(router.shiftChanged(
            gesture: right,
            isDown: false,
            timestamp: 2.08
        ))
        XCTAssertTrue(router.shiftChanged(
            gesture: right,
            isDown: true,
            timestamp: 2.20
        ))
    }

    func testDoubleShiftRouterKeepsPlainAndCommandGesturesSeparate() {
        let plain = DoubleShiftGesture(side: .left, modifier: .none)
        let command = DoubleShiftGesture(side: .left, modifier: .command)
        var router = DoubleShiftRouter(gestures: [plain, command])

        XCTAssertFalse(router.shiftChanged(gesture: command, isDown: true, timestamp: 1.00))
        XCTAssertFalse(router.shiftChanged(gesture: command, isDown: false, timestamp: 1.08))
        XCTAssertFalse(router.shiftChanged(gesture: plain, isDown: true, timestamp: 1.20))

        XCTAssertFalse(router.shiftChanged(gesture: command, isDown: true, timestamp: 2.00))
        XCTAssertFalse(router.shiftChanged(gesture: command, isDown: false, timestamp: 2.08))
        XCTAssertTrue(router.shiftChanged(gesture: command, isDown: true, timestamp: 2.20))
    }

    @MainActor
    func testGlobalShortcutsRejectShiftOnlyLettersWithoutRestrictingAppShortcuts() throws {
        let suiteName = "Snip SnapTypingShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ShortcutSettings(defaults: defaults)
        for (keyCode, label) in [(kVK_ANSI_A, "A"), (kVK_ANSI_K, "K"), (kVK_ANSI_Z, "Z")] {
            let chord = ShortcutKeyChord(keyCode: keyCode, modifiers: shiftKey, keyLabel: label)

            XCTAssertThrowsError(try settings.candidate(setting: .keyChord(chord), for: .togglePanel)) {
                XCTAssertEqual($0 as? ShortcutSettingsError, .typingShortcut)
            }
            XCTAssertNoThrow(try settings.candidate(setting: chord, for: .toggleDone))
            for modifiers in [controlKey | shiftKey, optionKey | shiftKey] {
                let safeChord = ShortcutKeyChord(keyCode: keyCode, modifiers: modifiers, keyLabel: label)
                XCTAssertNoThrow(try settings.candidate(setting: .keyChord(safeChord), for: .togglePanel))
            }
        }
        XCTAssertNoThrow(try settings.candidate(
            setting: .keyChord(.init(keyCode: kVK_ANSI_K, modifiers: cmdKey | shiftKey, keyLabel: "K")),
            for: .togglePanel
        ))
    }

    @MainActor
    func testGlobalShortcutsRejectLettersRecordedOnNonANSIKeyPositions() throws {
        let suiteName = "Snip SnapKeyboardLayoutShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for (keyCode, letter) in [(kVK_ANSI_LeftBracket, "Ü"), (kVK_ANSI_Semicolon, "M")] {
            let settings = ShortcutSettings(defaults: defaults)
            let chord = ShortcutKeyChord(keyCode: keyCode, modifiers: shiftKey, keyLabel: letter)
            XCTAssertThrowsError(try settings.candidate(setting: .keyChord(chord), for: .togglePanel)) {
                XCTAssertEqual($0 as? ShortcutSettingsError, .typingShortcut)
            }
            var saved = GlobalShortcutConfiguration.snipSnapDefaults
            saved.togglePanel = .keyChord(chord)
            defaults.set(try JSONEncoder().encode(saved), forKey: "globalShortcutConfiguration")

            XCTAssertEqual(ShortcutSettings(defaults: defaults).configuration, .snipSnapDefaults)
        }
        let settings = ShortcutSettings(defaults: defaults)
        for chord in [
            ShortcutKeyChord(keyCode: kVK_F1, modifiers: shiftKey, keyLabel: "F1"),
            ShortcutKeyChord(keyCode: kVK_Space, modifiers: shiftKey, keyLabel: "Space")
        ] {
            XCTAssertNoThrow(try settings.candidate(setting: .keyChord(chord), for: .togglePanel))
        }
    }

    @MainActor
    func testUnsafeSavedBindingRepairPreservesOccupiedDefaults() throws {
        let suiteName = "Snip SnapOccupiedShortcutRepairTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let safePanel = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), keyLabel: "K"
        )
        let stored = GlobalShortcutConfiguration(
            captureSelection: .commandDoubleShift(.left),
            togglePanel: safePanel,
            toggleClipboard: .keyChord(.init(keyCode: kVK_ANSI_A, modifiers: shiftKey, keyLabel: "A"))
        )
        defaults.set(try JSONEncoder().encode(stored), forKey: "globalShortcutConfiguration")
        let settings = ShortcutSettings(defaults: defaults)

        XCTAssertEqual(settings.configuration.captureSelection, .commandDoubleShift(.left))
        XCTAssertEqual(settings.configuration.togglePanel, safePanel)
        XCTAssertEqual(settings.configuration.toggleClipboard, .commandDoubleShift(.right))
        XCTAssertTrue(settings.configuration.isValid)
        XCTAssertEqual(ShortcutSettings(defaults: defaults).configuration, settings.configuration)
    }

    @MainActor
    func testSavedShiftOnlyLettersAreRepairedWithoutLosingOtherCustomShortcuts() throws {
        let suiteName = "Snip SnapTypingShortcutRepairTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let safeCapture = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), keyLabel: "K"
        )
        let safeClipboard = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey), keyLabel: "L"
        )
        let stored = GlobalShortcutConfiguration(
            captureSelection: safeCapture,
            togglePanel: .keyChord(.init(keyCode: kVK_ANSI_A, modifiers: shiftKey, keyLabel: "A")),
            toggleClipboard: safeClipboard
        )
        defaults.set(try JSONEncoder().encode(stored), forKey: "globalShortcutConfiguration")
        let settings = ShortcutSettings(defaults: defaults)

        XCTAssertEqual(settings.configuration.captureSelection, safeCapture)
        XCTAssertEqual(settings.configuration.togglePanel, GlobalHotKeyAction.togglePanel.defaultTrigger)
        XCTAssertEqual(settings.configuration.toggleClipboard, safeClipboard)
        XCTAssertEqual(ShortcutSettings(defaults: defaults).configuration, settings.configuration)
    }

    @MainActor
    func testShortcutSettingsPersistAndRejectDuplicates() throws {
        let suiteName = "Snip SnapShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ShortcutSettings(defaults: defaults)
        let custom = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "K"
        )

        let changed = try settings.candidate(setting: custom, for: .togglePanel)
        settings.save(changed)
        XCTAssertEqual(ShortcutSettings(defaults: defaults).configuration.togglePanel, custom)

        XCTAssertThrowsError(
            try settings.candidate(setting: custom, for: .captureSelection)
        ) { error in
            XCTAssertEqual(error as? ShortcutSettingsError, .duplicate)
        }

        let samePhysicalShortcut = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "Different label"
        )
        XCTAssertThrowsError(
            try settings.candidate(setting: samePhysicalShortcut, for: .captureSelection)
        ) { error in
            XCTAssertEqual(error as? ShortcutSettingsError, .duplicate)
        }

        let merge = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: UInt32(cmdKey | shiftKey),
            keyLabel: "M"
        )
        XCTAssertThrowsError(
            try settings.candidate(setting: merge, for: .captureSelection)
        ) { error in
            XCTAssertEqual(error as? ShortcutSettingsError, .defaultForAnotherAction)
        }

        let detachedEditorSave = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(cmdKey),
            keyLabel: "S"
        )
        XCTAssertThrowsError(
            try settings.candidate(setting: detachedEditorSave, for: .captureSelection)
        ) { error in
            XCTAssertEqual(error as? ShortcutSettingsError, .reserved)
        }

        let keyboardShortcuts = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_Slash),
            modifiers: UInt32(cmdKey),
            keyLabel: "/"
        )
        XCTAssertThrowsError(
            try settings.candidate(setting: keyboardShortcuts, for: .captureSelection)
        ) { error in
            XCTAssertEqual(error as? ShortcutSettingsError, .reserved)
        }

        let otherCustom = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_J),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "J"
        )
        settings.save(try settings.candidate(setting: otherCustom, for: .captureSelection))
        XCTAssertThrowsError(
            try settings.candidate(
                setting: GlobalHotKeyAction.captureSelection.defaultTrigger,
                for: .togglePanel
            )
        ) { error in
            XCTAssertEqual(error as? ShortcutSettingsError, .defaultForAnotherAction)
        }
    }

    @MainActor
    func testAppShortcutsPersistResetAndRejectConflicts() throws {
        let suiteName = "Snip SnapAppShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ShortcutSettings(defaults: defaults)
        let custom = ShortcutKeyChord(
            keyCode: kVK_ANSI_L,
            modifiers: cmdKey | shiftKey,
            keyLabel: "L"
        )

        settings.save(try settings.candidate(setting: custom, for: .toggleDone))
        XCTAssertEqual(
            ShortcutSettings(defaults: defaults).chord(for: .toggleDone),
            custom
        )

        XCTAssertThrowsError(
            try settings.candidate(setting: custom, for: .merge)
        ) { error in
            XCTAssertEqual(error as? ShortcutSettingsError, .duplicate)
        }

        let fixedSave = ShortcutKeyChord(
            keyCode: kVK_ANSI_S,
            modifiers: cmdKey,
            keyLabel: "S"
        )
        XCTAssertThrowsError(
            try settings.candidate(setting: fixedSave, for: .merge)
        ) { error in
            XCTAssertEqual(error as? ShortcutSettingsError, .reserved)
        }

        let fixedWindowEditor = ShortcutKeyChord(
            keyCode: kVK_Return,
            modifiers: cmdKey,
            keyLabel: "Return"
        )
        XCTAssertThrowsError(
            try settings.candidate(setting: fixedWindowEditor, for: .merge)
        ) { error in
            XCTAssertEqual(error as? ShortcutSettingsError, .reserved)
        }

        for chord in [
            ShortcutKeyChord(keyCode: kVK_UpArrow, modifiers: shiftKey, keyLabel: "↑"),
            ShortcutKeyChord(keyCode: kVK_DownArrow, modifiers: shiftKey, keyLabel: "↓"),
            ShortcutKeyChord(keyCode: kVK_Tab, modifiers: 0, keyLabel: "Tab"),
            ShortcutKeyChord(keyCode: kVK_Tab, modifiers: shiftKey, keyLabel: "Tab"),
        ] {
            XCTAssertThrowsError(
                try settings.candidate(setting: chord, for: .merge)
            ) { error in
                XCTAssertEqual(error as? ShortcutSettingsError, .reserved)
            }
        }

        let modifiedForwardDelete = ShortcutKeyChord(
            keyCode: kVK_ForwardDelete,
            modifiers: optionKey,
            keyLabel: "Forward Delete"
        )
        XCTAssertNoThrow(
            try settings.candidate(setting: modifiedForwardDelete, for: .merge)
        )
        let mergeCustom = ShortcutKeyChord(
            keyCode: kVK_ANSI_K,
            modifiers: cmdKey | shiftKey,
            keyLabel: "K"
        )
        settings.save(try settings.candidate(setting: mergeCustom, for: .merge))
        XCTAssertThrowsError(
            try settings.candidate(
                setting: AppShortcutAction.merge.defaultChord,
                for: .toggleDone
            )
        ) { error in
            XCTAssertEqual(error as? ShortcutSettingsError, .defaultForAnotherAction)
        }

        try settings.reset(.toggleDone)
        XCTAssertEqual(
            settings.chord(for: .toggleDone),
            AppShortcutAction.toggleDone.defaultChord
        )
    }

    @MainActor
    func testSavedAppShortcutsFillNewActionsAndRepairOnlyTheBadGroup() throws {
        let suiteName = "Snip SnapShortcutRepairTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let customGlobal = GlobalShortcutConfiguration(
            captureSelection: .keyChord(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: UInt32(controlKey | optionKey),
                keyLabel: "K"
            ),
            togglePanel: .doubleShift(.right)
        )
        defaults.set(
            try JSONEncoder().encode(customGlobal),
            forKey: "globalShortcutConfiguration"
        )
        let partialApp = AppShortcutConfiguration(bindings: [
            .toggleDone: .init(
                keyCode: kVK_ANSI_L,
                modifiers: cmdKey | shiftKey,
                keyLabel: "L"
            ),
        ])
        defaults.set(
            try JSONEncoder().encode(partialApp),
            forKey: "appShortcutConfiguration"
        )

        var settings = ShortcutSettings(defaults: defaults)
        XCTAssertEqual(settings.configuration, customGlobal)
        XCTAssertEqual(settings.chord(for: .toggleDone), partialApp.chord(for: .toggleDone))
        XCTAssertEqual(settings.chord(for: .merge), AppShortcutAction.merge.defaultChord)

        let invalidApp = AppShortcutConfiguration(bindings: [
            .toggleDone: .init(keyCode: kVK_ANSI_L, modifiers: cmdKey, keyLabel: "L"),
            .merge: .init(keyCode: kVK_ANSI_L, modifiers: cmdKey, keyLabel: "L"),
        ])
        defaults.set(
            try JSONEncoder().encode(invalidApp),
            forKey: "appShortcutConfiguration"
        )
        settings = ShortcutSettings(defaults: defaults)
        XCTAssertEqual(settings.configuration, customGlobal)
        XCTAssertEqual(settings.appConfiguration, .snipSnapDefaults)
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppShortcutConfiguration.self,
                from: try XCTUnwrap(defaults.data(forKey: "appShortcutConfiguration"))
            ),
            .snipSnapDefaults
        )

        let collidingChord = ShortcutKeyChord(
            keyCode: kVK_ANSI_L,
            modifiers: cmdKey | shiftKey,
            keyLabel: "L"
        )
        let crossGroupGlobal = GlobalShortcutConfiguration(
            captureSelection: .keyChord(collidingChord),
            togglePanel: .doubleShift(.right)
        )
        let preservedMerge = ShortcutKeyChord(
            keyCode: kVK_ANSI_K,
            modifiers: cmdKey | shiftKey,
            keyLabel: "K"
        )
        let crossGroupApp = AppShortcutConfiguration(bindings: [
            .toggleDone: collidingChord,
            .merge: preservedMerge,
        ])
        defaults.set(
            try JSONEncoder().encode(crossGroupGlobal),
            forKey: "globalShortcutConfiguration"
        )
        defaults.set(
            try JSONEncoder().encode(crossGroupApp),
            forKey: "appShortcutConfiguration"
        )
        settings = ShortcutSettings(defaults: defaults)
        XCTAssertEqual(settings.configuration, crossGroupGlobal)
        XCTAssertEqual(settings.chord(for: .toggleDone), .init(
            keyCode: kVK_Space,
            modifiers: 0,
            keyLabel: "Space"
        ))
        XCTAssertEqual(settings.chord(for: .merge), preservedMerge)

        let defaultClaimingGlobal = GlobalShortcutConfiguration(
            captureSelection: .keyChord(AppShortcutAction.merge.defaultChord),
            togglePanel: .doubleShift(.right)
        )
        let validCustomApp = AppShortcutConfiguration(bindings: [
            .toggleDone: collidingChord,
            .merge: preservedMerge,
        ])
        defaults.set(
            try JSONEncoder().encode(defaultClaimingGlobal),
            forKey: "globalShortcutConfiguration"
        )
        defaults.set(
            try JSONEncoder().encode(validCustomApp),
            forKey: "appShortcutConfiguration"
        )
        settings = ShortcutSettings(defaults: defaults)
        XCTAssertEqual(settings.configuration.captureSelection, .doubleShift(.left))
        XCTAssertEqual(settings.configuration.togglePanel, .doubleShift(.right))
        XCTAssertEqual(settings.appConfiguration, validCustomApp)
    }

    @MainActor
    func testShortcutSettingsRejectInvalidSavedTriggerState() throws {
        let suiteName = "Snip SnapShortcutDecodeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(
                """
                {
                  "captureSelection": {"kind": "doubleShift"},
                  "togglePanel": {"kind": "doubleShift", "side": "right"}
                }
                """.utf8
            ),
            forKey: "globalShortcutConfiguration"
        )

        XCTAssertEqual(
            ShortcutSettings(defaults: defaults).configuration,
            .snipSnapDefaults
        )

        let duplicateActions = GlobalShortcutConfiguration(
            captureSelection: .doubleShift(.left),
            togglePanel: .doubleShift(.left)
        )
        defaults.set(
            try JSONEncoder().encode(duplicateActions),
            forKey: "globalShortcutConfiguration"
        )
        XCTAssertEqual(
            ShortcutSettings(defaults: defaults).configuration,
            .snipSnapDefaults
        )
    }

}

private func keyEvent(
    type: NSEvent.EventType,
    flags: NSEvent.ModifierFlags,
    timestamp: TimeInterval,
    keyCode: UInt16
) -> NSEvent {
    NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: flags,
        timestamp: timestamp,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    )!
}

extension ShortcutKeyChord {
    static func globalShortcutTestChord(keyCode: Int, keyLabel: String) -> ShortcutKeyChord {
        ShortcutKeyChord(keyCode: keyCode, modifiers: controlKey | optionKey | cmdKey, keyLabel: keyLabel)
    }

    var isAvailableToRegister: Bool {
        var reference = hold()
        defer { releaseHeldChord(&reference) }
        return reference != nil
    }

    func hold() -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers,
            EventHotKeyID(signature: 0x54455354, id: 1),
            GetApplicationEventTarget(), 0, &reference
        )
        return status == noErr ? reference : nil
    }
}

func requireAvailableChords(_ chords: ShortcutKeyChord...) throws {
    guard chords.allSatisfy(\.isAvailableToRegister) else {
        throw XCTSkip("The OS could not provide the integration test's chords")
    }
}

func releaseHeldChord(_ reference: inout EventHotKeyRef?) {
    if let reference { UnregisterEventHotKey(reference) }
    reference = nil
}

func sendHotKeyPressed(_ action: GlobalHotKeyAction) throws -> OSStatus {
    var created: EventRef?
    let creation = CreateEvent(
        nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
        GetCurrentEventTime(), EventAttributes(kEventAttributeNone), &created
    )
    XCTAssertEqual(creation, OSStatus(noErr))
    let event = try XCTUnwrap(created)
    defer { ReleaseEvent(event) }
    var identifier = EventHotKeyID(signature: OSType(0x53504F4C), id: action.rawValue)
    let parameter = SetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        MemoryLayout<EventHotKeyID>.size, &identifier
    )
    XCTAssertEqual(parameter, OSStatus(noErr))
    return SendEventToEventTarget(event, GetApplicationEventTarget())
}
