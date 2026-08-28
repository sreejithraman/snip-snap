import XCTest
import SnipSnapCore
import AppKit
import Carbon.HIToolbox
@testable import SnipSnap
@testable import SnipSnapPersistence

final class AppCoordinatorTests: StoreBackedTestCase {
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
    func testDoubleShiftStartExplainsAccessibilityBeforeRequestingIt() throws {
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
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: settings,
            makeHotKeyManager: { _ in manager },
            isAccessibilityTrusted: { false },
            requestAccessibilityTrust: {
                requestCount += 1
            }
        )
        coordinator.attachPanelWindow(panel)

        coordinator.start()

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(manager.registeredConfigurations, [.snipSnapDefaults])
        XCTAssertTrue(model.isAccessibilityAccessExplanationPresented)
        XCTAssertTrue(panel.isVisible)
        XCTAssertNil(model.presentedError)

        coordinator.requestAccessibilityAccess()

        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(model.isAccessibilityAccessExplanationPresented)
    }

    @MainActor
    func testStartExplainsAccessibilityWithoutDoubleShiftShortcuts() throws {
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
            isAccessibilityTrusted: { false }
        )

        coordinator.start()

        XCTAssertTrue(model.isAccessibilityAccessExplanationPresented)
    }

    @MainActor
    func testTrustedStartDoesNotExplainOrRequestAccessibility() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)
        var requestCount = 0
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            makeHotKeyManager: { _ in StubGlobalHotKeyManager() },
            isAccessibilityTrusted: { true },
            requestAccessibilityTrust: { requestCount += 1 }
        )

        coordinator.start()

        XCTAssertFalse(model.isAccessibilityAccessExplanationPresented)
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testCaptureExplainsMissingAccessibilityWithoutRequestingIt() throws {
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

        XCTAssertTrue(model.isAccessibilityAccessExplanationPresented)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(requestCount, 0)
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

    func testToggleHidesOnlyWhenVisibleOnActiveSpace() {
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
