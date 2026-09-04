import XCTest
import SnipSnapCore
import Carbon.HIToolbox
@testable import SnipSnap

final class ShortcutTests: StoreBackedTestCase {
    func testShortcutSettingsOnlyExposeSnipSnapSpecificCommands() {
        XCTAssertEqual(
            GlobalHotKeyAction.allCases.map(\.title),
            ["Capture Selection", "Open or Hide Snip Snap", "Open or Hide Clipboard"]
        )
        XCTAssertEqual(AppShortcutAction.allCases.map(\.title), [
            "Done or Not Done",
            "Merge Snips",
        ])
        XCTAssertEqual(AppShortcutAction.toggleDone.rawValue, "toggleDone")
    }

    func testCompletionCommandsUseSharedDoneLanguage() {
        XCTAssertEqual(SnipCompletionLanguage.done, "Done")
        XCTAssertEqual(SnipCompletionLanguage.notDone, "Not Done")
        XCTAssertEqual(SnipCompletionLanguage.stateTitle(isDone: true), "Done")
        XCTAssertEqual(SnipCompletionLanguage.stateTitle(isDone: false), "Not Done")
        XCTAssertEqual(SnipCommand.toggleDone.title(allSelectedAreDone: false), "Done")
        XCTAssertEqual(SnipCommand.toggleDone.title(allSelectedAreDone: true), "Not Done")
        XCTAssertEqual(AppShortcutAction.toggleDone.title, "Done or Not Done")
    }

    func testSharedCatalogCoversEveryListIconAndTheInboxName() {
        XCTAssertEqual(SnipList.inbox.displayName, String(localized: "Inbox"))

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
        XCTAssertEqual(defaults.toggleClipboard, .commandDoubleShift(.right))
        XCTAssertEqual(defaults.captureSelection.displayName, "Left ⇧ ⇧")
        XCTAssertEqual(defaults.togglePanel.displayName, "Right ⇧ ⇧")
        XCTAssertEqual(defaults.toggleClipboard.displayName, "⌘ Right ⇧ ⇧")
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
        let plain = DoubleShiftGesture(side: .right, modifier: .none)
        let command = DoubleShiftGesture(side: .right, modifier: .command)
        var router = DoubleShiftRouter(gestures: [plain, command])

        XCTAssertFalse(router.shiftChanged(gesture: command, isDown: true, timestamp: 1.00))
        XCTAssertFalse(router.shiftChanged(gesture: command, isDown: false, timestamp: 1.08))
        XCTAssertFalse(router.shiftChanged(gesture: plain, isDown: true, timestamp: 1.20))

        XCTAssertFalse(router.shiftChanged(gesture: command, isDown: true, timestamp: 2.00))
        XCTAssertFalse(router.shiftChanged(gesture: command, isDown: false, timestamp: 2.08))
        XCTAssertTrue(router.shiftChanged(gesture: command, isDown: true, timestamp: 2.20))
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
