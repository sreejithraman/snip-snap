import XCTest
import AppKit
import Carbon.HIToolbox
@testable import SnipSnap

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
    func testDoubleShiftStartRequestsAccessibilityAndExplainsTheNeed() throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let model = AppModel(repository: repository)
        let suiteName = "Snip SnapShortcutTrustTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ShortcutSettings(defaults: defaults)
        let manager = StubGlobalHotKeyManager()
        var requestCount = 0
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: settings,
            makeHotKeyManager: { _ in manager },
            requestAccessibilityTrust: {
                requestCount += 1
                return false
            }
        )

        coordinator.start()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(manager.registeredConfigurations, [.snipSnapDefaults])
        XCTAssertTrue(model.presentedError?.contains("Accessibility") == true)
    }

    @MainActor
    func testCoordinatorKeepsTheExactInboxWindow() throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let model = AppModel(repository: repository)
        let settings = ShortcutSettings()
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: settings,
            requestAccessibilityTrust: { true }
        )
        let inbox = NSWindow()
        let editor = NSWindow()

        coordinator.attachInboxWindow(inbox)

        XCTAssertTrue(coordinator.isInboxWindow(inbox))
        XCTAssertFalse(coordinator.isInboxWindow(editor))
    }

    @MainActor
    func testComposerExpansionGrowsPanelDownwardAndPreservesBaseHeight() throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let coordinator = AppCoordinator(
            model: AppModel(repository: repository),
            shortcutSettings: ShortcutSettings(),
            requestAccessibilityTrust: { true }
        )
        let panel = SnipSnapPanel.make(contentViewController: NSViewController())
        panel.setFrameOrigin(NSPoint(x: 300, y: 300))
        coordinator.attachInboxWindow(panel)
        let baseline = panel.frame

        coordinator.updateInboxComposerExpansion(44)

        XCTAssertEqual(panel.frame.height, baseline.height + 44)
        XCTAssertEqual(panel.frame.maxY, baseline.maxY)
        XCTAssertEqual(panel.frame.height - 44, baseline.height)

        coordinator.updateInboxComposerExpansion(0)

        XCTAssertEqual(panel.frame, baseline)
    }

    @MainActor
    func testToggleHidesAVisibleInboxOnActiveSpace() throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let coordinator = AppCoordinator(
            model: AppModel(repository: repository),
            shortcutSettings: ShortcutSettings(),
            requestAccessibilityTrust: { true }
        )
        let inbox = NSWindow()
        coordinator.attachInboxWindow(inbox)
        inbox.orderFront(nil)
        XCTAssertTrue(inbox.isVisible)

        coordinator.toggleInbox()

        XCTAssertFalse(inbox.isVisible)
    }

    @MainActor
    func testClipboardShortcutOpensClipboardThenHidesIt() throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let model = AppModel(repository: repository)
        model.query = "old search"
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            requestAccessibilityTrust: { true }
        )
        let inbox = NSWindow()
        coordinator.attachInboxWindow(inbox)

        coordinator.toggleClipboard()

        XCTAssertTrue(model.isShowingClipboard)
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(inbox.isVisible)

        coordinator.toggleClipboard()

        XCTAssertFalse(inbox.isVisible)
    }

    func testToggleHidesOnlyWhenVisibleOnActiveSpace() {
        XCTAssertTrue(
            AppCoordinator.shouldHideInbox(
                isVisible: true,
                isMiniaturized: false,
                isOnActiveSpace: true
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldHideInbox(
                isVisible: true,
                isMiniaturized: false,
                isOnActiveSpace: false
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldHideInbox(
                isVisible: false,
                isMiniaturized: false,
                isOnActiveSpace: true
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldHideInbox(
                isVisible: true,
                isMiniaturized: true,
                isOnActiveSpace: true
            )
        )
    }

    @MainActor
    func testCoordinatorSendsSearchFocusRequest() throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let model = AppModel(repository: repository)
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            requestAccessibilityTrust: { true }
        )
        var receivedSearchRequest = false
        let subscription = coordinator.inboxFocusRequests.sink { request in
            if case .search = request {
                receivedSearchRequest = true
            }
        }

        coordinator.focusInboxSearch()

        XCTAssertTrue(receivedSearchRequest)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testFailedShortcutInstallReleasesPartialManagerBeforeRollback() throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let model = AppModel(repository: repository)
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
            requestAccessibilityTrust: { true }
        )
        coordinator.start()
        let custom = ShortcutTrigger.keyChord(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "K"
        )

        XCTAssertThrowsError(try coordinator.setShortcut(custom, for: .toggleInbox))
        XCTAssertEqual(original.unregisterCount, 1)
        XCTAssertEqual(failedReplacement.unregisterCount, 1)
        XCTAssertEqual(rollback.registeredConfigurations, [.snipSnapDefaults])
        XCTAssertEqual(settings.configuration, .snipSnapDefaults)
    }
}
