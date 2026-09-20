import XCTest
import SnipSnapCore
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
@testable import SnipSnap
@testable import SnipSnapPersistence

final class AppCoordinatorTests: StoreBackedTestCase {
    func testDialogOriginStaysInsideTheVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let dialogSize = NSSize(width: 560, height: 520)

        XCTAssertEqual(
            AppCoordinator.centeredDialogOrigin(
                size: dialogSize,
                over: NSRect(x: -100, y: -100, width: 382, height: 500),
                within: visibleFrame
            ),
            NSPoint(x: 0, y: 0)
        )
        XCTAssertEqual(
            AppCoordinator.centeredDialogOrigin(
                size: dialogSize,
                over: NSRect(x: 900, y: 700, width: 382, height: 500),
                within: visibleFrame
            ),
            NSPoint(x: 440, y: 280)
        )
    }

    func testPendingErrorsWaitForAUsablePanel() {
        XCTAssertTrue(AppCoordinator.shouldPresentPendingError(
            isVisible: true,
            isMiniaturized: false,
            isOnActiveSpace: true
        ))
        XCTAssertFalse(AppCoordinator.shouldPresentPendingError(
            isVisible: false,
            isMiniaturized: false,
            isOnActiveSpace: true
        ))
        XCTAssertFalse(AppCoordinator.shouldPresentPendingError(
            isVisible: true,
            isMiniaturized: true,
            isOnActiveSpace: true
        ))
        XCTAssertFalse(AppCoordinator.shouldPresentPendingError(
            isVisible: true,
            isMiniaturized: false,
            isOnActiveSpace: false
        ))
    }

    @MainActor
    func testGlobalPanelActionsKeepDialogOwnershipAndHideWithoutReopeningParent() async throws {
        let defaultsName = "Snip SnapPanelDialogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            library: try JSONSnipLibrary(fileURL: storeURL()),
            defaults: defaults
        )
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false }
        )
        let panel = NSWindow()
        panel.setContentSize(NSSize(width: 382, height: 500))
        coordinator.attachPanelWindow(panel)
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        var didDismiss = false
        var focusRequestCount = 0
        let focusRequest = coordinator.panelFocusRequests.sink { _ in
            focusRequestCount += 1
        }
        defer { focusRequest.cancel() }

        coordinator.presentPanelDialog(id: .newList, title: "Test") {
            didDismiss = true
        } content: {
            Text("Dialog").padding()
        }

        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.childWindows?.count, 1)
        XCTAssertEqual(panel.childWindows?.first?.isOpaque, true)
        let dialog = try XCTUnwrap(panel.childWindows?.first)
        let inputShield = try XCTUnwrap(
            panel.contentView?.subviews.last as? PanelDialogInputShieldView
        )
        let click = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        XCTAssertEqual(inputShield.frame, panel.contentView?.bounds)
        XCTAssertTrue(inputShield.hitTest(NSPoint(x: 1, y: 1)) === inputShield)
        XCTAssertTrue(inputShield.acceptsFirstMouse(for: click))
        XCTAssertNotNil(inputShield.activateDialog)
        XCTAssertTrue(
            AppCoordinator.shouldRestorePreviousApplication(
                panelIsKey: false,
                dialogIsKey: true
            )
        )

        model.presentError("Dialog save failed")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(panel.attachedSheet)
        XCTAssertNotNil(dialog.attachedSheet)
        model.dismissPresentedError()
        try await Task.sleep(for: .milliseconds(100))

        coordinator.toggleClipboard()

        XCTAssertFalse(model.isShowingClipboard)
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(panel.childWindows?.first === dialog)

        coordinator.captureSelection()

        XCTAssertFalse(coordinator.accessibilityPermissions.isRepairPresented)
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(panel.childWindows?.first === dialog)

        coordinator.focusPanelSearch()

        XCTAssertEqual(focusRequestCount, 0)
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(panel.childWindows?.first === dialog)

        coordinator.togglePanel()

        XCTAssertTrue(didDismiss)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
        XCTAssertFalse(inputShield.isDescendant(of: panel.contentView ?? NSView()))
    }

    @MainActor
    func testRootErrorUsesAnOpaqueChildInsteadOfAParentSheet() throws {
        let defaultsName = "Snip SnapPanelErrorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            library: try JSONSnipLibrary(fileURL: storeURL()),
            defaults: defaults
        )
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }

        model.presentError("A root action failed")
        coordinator.updatePresentedError()

        let errorWindow = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(errorWindow.isOpaque)
        XCTAssertNil(panel.attachedSheet)
        XCTAssertNil(errorWindow.attachedSheet)

        coordinator.togglePanel()

        XCTAssertFalse(panel.isVisible)
        XCTAssertNotNil(model.presentedError)

        coordinator.togglePanel()

        let reopenedErrorWindow = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertTrue(reopenedErrorWindow.isOpaque)
        XCTAssertNil(reopenedErrorWindow.attachedSheet)

        model.dismissPresentedError()
        coordinator.updatePresentedError()

        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
    }

    @MainActor
    func testRootConfirmationsUseOpaqueChildrenInsteadOfParentSheets() throws {
        let defaultsName = "Snip SnapPanelConfirmationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            library: try JSONSnipLibrary(fileURL: storeURL()),
            defaults: defaults
        )
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }

        let dialogIDs: [PanelDialogID] = [
            .backupImport,
            .clearClipboardHistory,
            .deleteList(UUID())
        ]
        for id in dialogIDs {
            coordinator.presentPanelDialog(id: id, title: "Test") {} content: {
                PanelConfirmationDialog(
                    title: "Confirm",
                    message: "Check this action.",
                    confirmTitle: "Continue",
                    onConfirm: {},
                    onCancel: {}
                )
            }

            let dialog = try XCTUnwrap(panel.childWindows?.first)
            XCTAssertTrue(dialog.isOpaque)
            XCTAssertNil(panel.attachedSheet)
            XCTAssertNil(dialog.attachedSheet)

            coordinator.dismissPanelDialog(id: id)
            XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
        }
    }

    @MainActor
    func testAttachmentImporterIsAStandalonePanel() {
        let parent = NSWindow()
        let importer = StandaloneFileImporter.makePanel()
        defer { importer.orderOut(nil) }

        importer.orderFront(nil)

        XCTAssertNil(parent.attachedSheet)
        XCTAssertNil(importer.sheetParent)
        XCTAssertFalse(parent.childWindows?.contains(importer) == true)
    }

    @MainActor
    func testAccessibilityRepairDismissesBeforeOpeningSettings() throws {
        let defaultsName = "Snip SnapAccessibilityDialogOrderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AccessibilityPermissionController.didRequestAccessDefaultsKey)
        var openedSettings = false
        var coordinator: AppCoordinator!
        let model = AppModel(
            library: try JSONSnipLibrary(fileURL: storeURL()),
            defaults: defaults
        )
        coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false },
            requestAccessibilityTrust: {},
            openAccessibilitySettings: {
                XCTAssertFalse(coordinator.panelDialogs.isPresented)
                openedSettings = true
            },
            accessibilitySetupDefaults: defaults
        )
        let parent = NSWindow()
        coordinator.attachPanelWindow(parent)
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }
        coordinator.presentPanelDialog(id: .accessibility, title: "Test") {} content: {
            Text("Repair")
        }

        coordinator.dismissPanelDialog(id: .accessibility, restoringParent: false)
        coordinator.accessibilityPermissions.performPrimaryAction()

        XCTAssertTrue(openedSettings)
        XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
    }

    @MainActor
    func testPendingFormErrorMovesToAnOpaqueChildAfterHideAndReopen() async throws {
        let defaultsName = "Snip SnapPendingPanelErrorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            library: try JSONSnipLibrary(fileURL: storeURL()),
            defaults: defaults
        )
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }

        coordinator.presentPanelDialog(id: .newList, title: "Test") {} content: {
            Text("Dialog").padding()
        }
        let formWindow = try XCTUnwrap(panel.childWindows?.first)
        model.presentError("Dialog save failed")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(formWindow.attachedSheet)

        coordinator.togglePanel()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(panel.isVisible)
        XCTAssertNotNil(model.presentedError)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)

        coordinator.togglePanel()

        let errorWindow = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(errorWindow.isOpaque)
        XCTAssertNil(panel.attachedSheet)
        XCTAssertNil(errorWindow.attachedSheet)

        model.dismissPresentedError()
        coordinator.updatePresentedError()
    }

    @MainActor
    func testPendingFormErrorMovesToAnOpaqueChildAfterNormalDismissal() async throws {
        let defaultsName = "Snip SnapDismissedFormErrorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            library: try JSONSnipLibrary(fileURL: storeURL()),
            defaults: defaults
        )
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }

        coordinator.presentPanelDialog(id: .newList, title: "Test") {} content: {
            Text("Dialog").padding()
        }
        XCTAssertNotNil(panel.childWindows?.first)
        model.presentError("Dialog save failed")

        coordinator.dismissPanelDialog(id: .newList)
        try await Task.sleep(for: .milliseconds(100))

        let errorWindow = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertTrue(errorWindow.isOpaque)
        XCTAssertNil(panel.attachedSheet)
        XCTAssertNil(errorWindow.attachedSheet)
        XCTAssertNotNil(model.presentedError)

        model.dismissPresentedError()
        coordinator.updatePresentedError()
    }

    @MainActor
    func testErrorWaitsForTheUserToOpenAHiddenPanel() throws {
        let defaultsName = "Snip SnapHiddenPanelErrorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            library: try JSONSnipLibrary(fileURL: storeURL()),
            defaults: defaults
        )
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        panel.orderOut(nil)
        defer { panel.orderOut(nil) }

        model.presentError("A hidden action failed")
        coordinator.updatePresentedError()

        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertNotNil(model.presentedError)

        coordinator.togglePanel()

        let errorWindow = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(errorWindow.isOpaque)
        XCTAssertNil(panel.attachedSheet)
        XCTAssertNil(errorWindow.attachedSheet)

        model.dismissPresentedError()
        coordinator.updatePresentedError()
    }

    @MainActor
    func testCopyClipboardEntryRestoresContentWithoutClosingThePanel() throws {
        let pasteboard = NSPasteboard(
            name: .init("world.sree.snipsnap.coordinator-copy-tests.\(UUID().uuidString)")
        )
        let defaultsName = "Snip SnapCoordinatorCopyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let history = ClipboardHistory(
            pasteboard: pasteboard,
            defaults: defaults,
            storeURL: try storeURL().deletingLastPathComponent().appendingPathComponent("clipboard.json")
        )
        let model = AppModel(
            library: try JSONSnipLibrary(fileURL: storeURL()),
            defaults: defaults,
            clipboardHistory: history
        )
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { true }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        let entry = ClipboardEntry(
            sourceApplication: "Tests",
            items: [
                ClipboardPayloadItem(
                    representations: [
                        ClipboardRepresentation(
                            type: NSPasteboard.PasteboardType.string.rawValue,
                            data: Data("Copied from history".utf8)
                        )
                    ]
                )
            ]
        )

        XCTAssertTrue(coordinator.copyClipboardEntry(entry))

        XCTAssertEqual(pasteboard.string(forType: .string), "Copied from history")
        XCTAssertTrue(panel.isVisible)
        XCTAssertNil(model.presentedError)
    }

    func testSelectionAttachmentStagingReportsWriteFailure() throws {
        let baseFile = try storeURL().deletingLastPathComponent()
            .appendingPathComponent("not-a-folder")
        try Data("file".utf8).write(to: baseFile)

        let result = AppCoordinator.writeTemporaryAttachments(
            [.init(fileName: "Selection.png", data: Data([1, 2, 3]))],
            requestID: UUID(),
            baseDirectory: baseFile
        )

        guard case .failure(let error) = result else {
            return XCTFail("Staging under a file must fail.")
        }
        XCTAssertEqual(error, .writeFailed)
    }

    func testSelectionAttachmentStagingSanitizesPathSeparators() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip SnapAttachmentNames-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: baseDirectory) }

        let result = AppCoordinator.writeTemporaryAttachments(
            [.init(fileName: "Image 1/2:3.png", data: Data([1, 2, 3]))],
            requestID: UUID(),
            baseDirectory: baseDirectory
        )

        guard case .success(let staged) = result,
              let url = staged.urls.first else {
            return XCTFail("A source title with path separators must still stage.")
        }
        XCTAssertEqual(url.lastPathComponent, "1-Image 1-2-3.png")
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
    }

    @MainActor
    func testStartShowsAccessibilitySetupCardBeforeRequestingIt() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)
        let suiteName = "Snip SnapShortcutTrustTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ShortcutSettings(defaults: defaults)
        let manager = StubGlobalHotKeyManager()
        let panel = NSWindow()
        defer { panel.orderOut(nil) }
        var requestCount = 0
        var openSettingsCount = 0
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: settings,
            makeHotKeyManager: { _ in manager },
            isAccessibilityTrusted: { false },
            requestAccessibilityTrust: {
                requestCount += 1
            },
            openAccessibilitySettings: {
                openSettingsCount += 1
            },
            accessibilitySetupDefaults: defaults
        )
        coordinator.attachPanelWindow(panel)

        coordinator.start()

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(manager.registeredConfigurations, [.snipSnapDefaults])
        XCTAssertTrue(coordinator.accessibilityPermissions.isSetupCardVisible)
        XCTAssertFalse(coordinator.accessibilityPermissions.hasRequestedAccess)
        XCTAssertEqual(
            coordinator.accessibilityPermissions.menuActionTitle,
            "Allow Accessibility Access…"
        )
        XCTAssertTrue(panel.isVisible)
        XCTAssertNil(model.presentedError)

        coordinator.accessibilityPermissions.performPrimaryAction()

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(coordinator.accessibilityPermissions.isSetupCardVisible)
        XCTAssertTrue(coordinator.accessibilityPermissions.hasRequestedAccess)
        XCTAssertEqual(
            defaults.bool(forKey: AccessibilityPermissionController.didHandleSetupDefaultsKey),
            true
        )
        XCTAssertEqual(
            coordinator.accessibilityPermissions.menuActionTitle,
            "Open Accessibility Settings…"
        )

        coordinator.accessibilityPermissions.performMenuAction()

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(openSettingsCount, 1)
    }

    @MainActor
    func testStartOffersAccessibilitySetupWithoutDoubleShiftShortcuts() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)
        let suiteName = "Snip SnapShortcutTrustTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ShortcutSettings(defaults: defaults)
        settings.save(
            GlobalShortcutConfiguration(
                captureSelection: .keyChord(
                    keyCode: UInt32(kVK_ANSI_J),
                    modifiers: UInt32(controlKey | optionKey),
                    keyLabel: "J"
                ),
                togglePanel: .keyChord(
                    keyCode: UInt32(kVK_ANSI_K),
                    modifiers: UInt32(controlKey | optionKey),
                    keyLabel: "K"
                ),
                toggleClipboard: .keyChord(
                    keyCode: UInt32(kVK_ANSI_L),
                    modifiers: UInt32(controlKey | optionKey),
                    keyLabel: "L"
                )
            )
        )
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: settings,
            makeHotKeyManager: { _ in StubGlobalHotKeyManager() },
            isAccessibilityTrusted: { false },
            accessibilitySetupDefaults: defaults
        )

        coordinator.start()

        XCTAssertTrue(coordinator.accessibilityPermissions.isSetupCardVisible)
    }

    @MainActor
    func testRepairActionRequestsAccessAgainForCurrentUntrustedApp() throws {
        let suiteName = "Snip SnapAccessibilityRepairTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            true,
            forKey: AccessibilityPermissionController.didRequestAccessDefaultsKey
        )
        var requestCount = 0
        var openSettingsCount = 0
        let controller = AccessibilityPermissionController(
            defaults: defaults,
            isTrusted: { false },
            requestTrust: { requestCount += 1 },
            openSettings: { openSettingsCount += 1 }
        )

        controller.performPrimaryAction()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(openSettingsCount, 1)
    }

    @MainActor
    func testTrustedStartDoesNotOfferOrRequestAccessibility() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)
        var requestCount = 0
        var openSettingsCount = 0
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            makeHotKeyManager: { _ in StubGlobalHotKeyManager() },
            isAccessibilityTrusted: { true },
            requestAccessibilityTrust: { requestCount += 1 },
            openAccessibilitySettings: { openSettingsCount += 1 }
        )

        coordinator.start()

        XCTAssertFalse(coordinator.accessibilityPermissions.isSetupCardVisible)
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(coordinator.accessibilityPermissions.menuActionTitle)

        coordinator.accessibilityPermissions.performMenuAction()

        XCTAssertEqual(openSettingsCount, 1)
    }

    @MainActor
    func testCapturePresentsAccessibilityRepairWithoutRequestingIt() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)
        let panel = NSWindow()
        defer { panel.orderOut(nil) }
        var requestCount = 0
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            isAccessibilityTrusted: { false },
            requestAccessibilityTrust: { requestCount += 1 }
        )
        coordinator.attachPanelWindow(panel)

        coordinator.captureSelection()

        XCTAssertTrue(coordinator.accessibilityPermissions.isRepairPresented)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testDeferredAccessibilitySetupStaysQuietOnNextStart() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)
        let suiteName = "Snip SnapDeferredAccessibilityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            true,
            forKey: AccessibilityPermissionController.didHandleSetupDefaultsKey
        )
        let panel = NSWindow()
        defer { panel.orderOut(nil) }
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults),
            makeHotKeyManager: { _ in StubGlobalHotKeyManager() },
            isAccessibilityTrusted: { false },
            accessibilitySetupDefaults: defaults
        )
        coordinator.attachPanelWindow(panel)

        coordinator.start()

        XCTAssertFalse(coordinator.accessibilityPermissions.isSetupCardVisible)
        XCTAssertFalse(panel.isVisible)

        coordinator.captureSelection()

        XCTAssertTrue(coordinator.accessibilityPermissions.isRepairPresented)
        XCTAssertTrue(panel.isVisible)
    }

    @MainActor
    func testGrantRefreshRestartsShortcutsAndHidesPermissionUI() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)
        let suiteName = "Snip SnapAccessibilityGrantTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = StubGlobalHotKeyManager()
        var isTrusted = false
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults),
            makeHotKeyManager: { _ in manager },
            isAccessibilityTrusted: { isTrusted },
            accessibilitySetupDefaults: defaults
        )

        coordinator.start()
        coordinator.accessibilityPermissions.presentRepair()
        XCTAssertNotNil(coordinator.accessibilityPermissions.menuActionTitle)
        isTrusted = true

        coordinator.accessibilityPermissions.refresh()

        XCTAssertTrue(coordinator.accessibilityPermissions.isGranted)
        XCTAssertFalse(coordinator.accessibilityPermissions.isSetupCardVisible)
        XCTAssertFalse(coordinator.accessibilityPermissions.isRepairPresented)
        XCTAssertNil(coordinator.accessibilityPermissions.menuActionTitle)
        XCTAssertEqual(
            manager.registeredConfigurations,
            [.snipSnapDefaults, .snipSnapDefaults]
        )
        XCTAssertEqual(manager.unregisterCount, 1)
    }

    @MainActor
    func testRevokedAccessRestoresTheSettingsActionWhenTheAppBecomesActive() async throws {
        let suiteName = "Snip SnapAccessibilityRevokedTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AccessibilityPermissionController.didRequestAccessDefaultsKey)
        let notificationCenter = NotificationCenter()
        var isTrusted = true
        let refreshAfterRevocation = expectation(description: "Refresh after access is revoked")
        let controller = AccessibilityPermissionController(
            defaults: defaults,
            notificationCenter: notificationCenter,
            isTrusted: {
                if !isTrusted {
                    refreshAfterRevocation.fulfill()
                }
                return isTrusted
            },
            requestTrust: {},
            openSettings: {}
        )
        controller.start()
        XCTAssertNil(controller.menuActionTitle)

        isTrusted = false
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [refreshAfterRevocation], timeout: 1)

        XCTAssertEqual(controller.menuActionTitle, "Open Accessibility Settings…")
    }

    @MainActor
    func testCoordinatorKeepsTheExactPanelWindow() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)
        let settings = ShortcutSettings()
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: settings,
            isAccessibilityTrusted: { true }
        )
        let panel = NSWindow()
        let editor = NSWindow()

        coordinator.attachPanelWindow(panel)

        XCTAssertTrue(coordinator.isPanelWindow(panel))
        XCTAssertFalse(coordinator.isPanelWindow(editor))
    }

    @MainActor
    func testComposerExpansionGrowsPanelDownwardAndPreservesBaseHeight() throws {
        let autosaveName = NSWindow.FrameAutosaveName("AppCoordinatorTests-\(UUID().uuidString)")
        defer { NSWindow.removeFrame(usingName: autosaveName) }
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let coordinator = AppCoordinator(
            model: AppModel(library: repository),
            shortcutSettings: ShortcutSettings(),
            isAccessibilityTrusted: { true }
        )
        let panel = SnipSnapPanel.make(
            contentViewController: NSViewController(),
            frameAutosaveName: nil
        )
        panel.setFrameOrigin(NSPoint(x: 300, y: 300))
        coordinator.attachPanelWindow(panel)
        let baseline = panel.frame

        coordinator.updatePanelComposerExpansion(44)

        XCTAssertEqual(panel.frame.height, baseline.height + 44)
        XCTAssertEqual(panel.frame.maxY, baseline.maxY)
        XCTAssertEqual(panel.frame.height - 44, baseline.height)

        coordinator.savePanelWindowFrame(using: autosaveName)

        XCTAssertEqual(panel.frame, baseline)
        let restoredPanel = SnipSnapPanel.make(
            contentViewController: NSViewController(),
            frameAutosaveName: autosaveName
        )
        XCTAssertEqual(restoredPanel.frame, baseline)
    }

    @MainActor
    func testComposerExpansionDoesNotRepeatDuringReentrantWindowLayout() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let coordinator = AppCoordinator(
            model: AppModel(library: repository),
            shortcutSettings: ShortcutSettings(),
            isAccessibilityTrusted: { true }
        )
        let panel = ReentrantLayoutWindow(
            contentRect: NSRect(origin: .zero, size: AppWindowDefaults.defaultSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        coordinator.attachPanelWindow(panel)
        let baseline = panel.frame
        panel.onFirstFrameChange = {
            coordinator.updatePanelComposerExpansion(44)
        }

        coordinator.updatePanelComposerExpansion(44)

        XCTAssertEqual(panel.frame.height, baseline.height + 44)
        XCTAssertEqual(panel.frameChangeCount, 1)
    }

    @MainActor
    func testToggleHidesAVisiblePanelOnActiveSpace() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let coordinator = AppCoordinator(
            model: AppModel(library: repository),
            shortcutSettings: ShortcutSettings(),
            isAccessibilityTrusted: { true }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        panel.orderFront(nil)
        XCTAssertTrue(panel.isVisible)

        coordinator.togglePanel()

        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testClipboardShortcutOpensClipboardThenHidesIt() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)
        model.query = "old search"
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            isAccessibilityTrusted: { true }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)

        coordinator.toggleClipboard()

        XCTAssertTrue(model.isShowingClipboard)
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(panel.isVisible)

        coordinator.toggleClipboard()

        XCTAssertFalse(panel.isVisible)
    }

    func testToggleHidesWhenVisibleOnActiveSpaceOrDialogIsPresented() {
        XCTAssertTrue(
            AppCoordinator.shouldHidePanel(
                isVisible: true,
                isMiniaturized: false,
                isOnActiveSpace: true
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldHidePanel(
                isVisible: true,
                isMiniaturized: false,
                isOnActiveSpace: false
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldHidePanel(
                isVisible: false,
                isMiniaturized: false,
                isOnActiveSpace: true
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldHidePanel(
                isVisible: true,
                isMiniaturized: true,
                isOnActiveSpace: true
            )
        )
        XCTAssertTrue(
            AppCoordinator.shouldHidePanel(
                isDialogPresented: true,
                isVisible: true,
                isMiniaturized: false,
                isOnActiveSpace: false
            )
        )
    }

    @MainActor
    func testCoordinatorSendsSearchFocusRequest() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            isAccessibilityTrusted: { true }
        )
        var receivedSearchRequest = false
        let subscription = coordinator.panelFocusRequests.sink { request in
            if case .search = request {
                receivedSearchRequest = true
            }
        }

        coordinator.focusPanelSearch()

        XCTAssertTrue(receivedSearchRequest)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testFailedShortcutInstallReleasesPartialManagerBeforeRollback() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)
        let suiteName = "Snip SnapShortcutRollbackTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ShortcutSettings(defaults: defaults)
        let original = StubGlobalHotKeyManager()
        let failedReplacement = StubGlobalHotKeyManager(error: StubHotKeyError.registration)
        let rollback = StubGlobalHotKeyManager()
        var managers = [original, failedReplacement, rollback]
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: settings,
            makeHotKeyManager: { _ in managers.removeFirst() },
            isAccessibilityTrusted: { true }
        )
        coordinator.start()
        let custom = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "K"
        )

        XCTAssertThrowsError(try coordinator.setShortcut(custom, for: .togglePanel))
        XCTAssertEqual(original.unregisterCount, 1)
        XCTAssertEqual(failedReplacement.unregisterCount, 1)
        XCTAssertEqual(rollback.registeredConfigurations, [.snipSnapDefaults])
        XCTAssertEqual(settings.configuration, .snipSnapDefaults)
    }
}

@MainActor
private final class ReentrantLayoutWindow: NSWindow {
    var onFirstFrameChange: (() -> Void)?
    private(set) var frameChangeCount = 0

    override func setFrame(
        _ frameRect: NSRect,
        display flag: Bool,
        animate animateFlag: Bool
    ) {
        frameChangeCount += 1
        super.setFrame(frameRect, display: flag, animate: animateFlag)
        guard frameChangeCount == 1 else { return }
        onFirstFrameChange?()
    }
}
