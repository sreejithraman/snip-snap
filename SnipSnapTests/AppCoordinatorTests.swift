import XCTest
import SnipSnapCore
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
@testable import SnipSnap
@testable import SnipSnapPersistence

final class AppCoordinatorTests: StoreBackedTestCase {
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
        let dialog = try XCTUnwrap(panel.attachedSheet)
        XCTAssertFalse(dialog.isOpaque)
        XCTAssertTrue(dialog.sheetParent === panel)
        XCTAssertTrue(
            AppCoordinator.shouldRestorePreviousApplication(
                panelIsKey: false,
                dialogIsKey: true
            )
        )
        XCTAssertTrue(
            AppCoordinator.shouldRestorePreviousApplication(
                panelIsKey: false,
                dialogIsKey: false,
                filePanelIsKey: true
            )
        )

        model.presentError("Dialog save failed")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(panel.attachedSheet === dialog)
        XCTAssertNotNil(dialog.attachedSheet)
        model.dismissPresentedError()
        try await Task.sleep(for: .milliseconds(100))

        coordinator.toggleClipboard()

        XCTAssertFalse(model.isShowingClipboard)
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(panel.attachedSheet === dialog)

        coordinator.captureSelection()

        XCTAssertFalse(coordinator.accessibilityPermissions.isRepairPresented)
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(panel.attachedSheet === dialog)

        coordinator.focusPanelSearch()

        XCTAssertEqual(focusRequestCount, 0)
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(panel.attachedSheet === dialog)

        coordinator.togglePanel()

        XCTAssertTrue(didDismiss)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.attachedSheet)
    }

    @MainActor
    func testBackupImporterUsesTheOwnedStandalonePanelPath() {
        let panel = BackupImportOpenPanel.makePanel()

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.allowedContentTypes.contains(.folder))
        XCTAssertTrue(panel.allowedContentTypes.contains(.json))
    }

    @MainActor
    func testDialogRequestedDuringOpenPanelAppearsAfterPickerCloses() async throws {
        let defaultsName = "Snip SnapDeferredDialogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        var panelCompletion: ((NSApplication.ModalResponse) -> Void)?
        let coordinator = AppCoordinator(
            model: AppModel(
                library: try JSONSnipLibrary(fileURL: storeURL()),
                defaults: defaults
            ),
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false },
            beginFilePanel: { _, _, completion in panelCompletion = completion }
        )
        let parent = NSWindow()
        coordinator.attachPanelWindow(parent)
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }
        let importer = StandaloneFileImporter.makePanel()
        coordinator.presentOpenPanel(importer) { _ in }
        coordinator.presentPanelDialog(id: .backupImport, title: "Import") {} content: {
            Text("Review backup")
        }

        XCTAssertNil(parent.attachedSheet)

        panelCompletion?(.cancel)
        await Task.yield()

        XCTAssertNotNil(parent.attachedSheet)
        XCTAssertEqual(parent.attachedSheet?.isOpaque, false)
        coordinator.dismissPanelDialog(id: .backupImport)
    }

    @MainActor
    func testDialogRequestedWhileParentIsHiddenWaitsForReopen() throws {
        let defaultsName = "Snip SnapHiddenDialogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let coordinator = AppCoordinator(
            model: AppModel(
                library: try JSONSnipLibrary(fileURL: storeURL()),
                defaults: defaults
            ),
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false }
        )
        let parent = NSWindow()
        coordinator.attachPanelWindow(parent)

        coordinator.presentPanelDialog(id: .backupImport, title: "Import") {} content: {
            Text("Review backup")
        }

        XCTAssertFalse(parent.isVisible)
        XCTAssertNil(parent.attachedSheet)

        coordinator.togglePanel()

        XCTAssertTrue(parent.isVisible)
        XCTAssertNotNil(parent.attachedSheet)
        XCTAssertEqual(parent.attachedSheet?.isOpaque, false)
        coordinator.dismissPanelDialog(id: .backupImport)
    }

    @MainActor
    func testQueuedDialogRetriesWhenAppKitMakesParentUsable() async throws {
        let defaultsName = "Snip SnapUsabilityDialogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let coordinator = AppCoordinator(
            model: AppModel(
                library: try JSONSnipLibrary(fileURL: storeURL()),
                defaults: defaults
            ),
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false }
        )
        let parent = NSWindow()
        coordinator.attachPanelWindow(parent)
        coordinator.presentPanelDialog(id: .backupImport, title: "Import") {} content: {
            Text("Review backup")
        }

        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(parent.attachedSheet)
        XCTAssertEqual(parent.attachedSheet?.isOpaque, false)
        coordinator.dismissPanelDialog(id: .backupImport)
    }

    @MainActor
    func testNewDialogWaitsForActiveDialogToClose() async throws {
        let defaultsName = "Snip SnapQueuedDialogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let coordinator = AppCoordinator(
            model: AppModel(
                library: try JSONSnipLibrary(fileURL: storeURL()),
                defaults: defaults
            ),
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false }
        )
        let parent = NSWindow()
        coordinator.attachPanelWindow(parent)
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }
        var didDismissNewList = false
        coordinator.presentPanelDialog(id: .newList, title: "New list") {
            didDismissNewList = true
        } content: {
            Text("New list form")
        }
        let newListWindow = try XCTUnwrap(parent.attachedSheet)

        coordinator.presentPanelDialog(id: .backupImport, title: "Import") {} content: {
            Text("Review backup")
        }

        XCTAssertTrue(parent.attachedSheet === newListWindow)
        XCTAssertFalse(didDismissNewList)

        coordinator.dismissPanelDialog(id: .newList)
        await Task.yield()

        XCTAssertTrue(didDismissNewList)
        XCTAssertNotNil(parent.attachedSheet)
        XCTAssertFalse(parent.attachedSheet === newListWindow)
        coordinator.dismissPanelDialog(id: .backupImport)
    }

    @MainActor
    func testRootErrorUsesAGlassSheetAttachedToThePanel() throws {
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

        let errorWindow = try XCTUnwrap(panel.attachedSheet)
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(errorWindow.canBecomeKey)
        XCTAssertFalse(errorWindow.isOpaque)
        XCTAssertTrue(errorWindow.sheetParent === panel)
        XCTAssertNil(errorWindow.attachedSheet)

        coordinator.togglePanel()

        XCTAssertFalse(panel.isVisible)
        XCTAssertNotNil(model.presentedError)

        coordinator.togglePanel()

        let reopenedErrorWindow = try XCTUnwrap(panel.attachedSheet)
        XCTAssertFalse(reopenedErrorWindow.isOpaque)
        XCTAssertTrue(reopenedErrorWindow.sheetParent === panel)

        model.dismissPresentedError()
        coordinator.updatePresentedError()

        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertNil(panel.attachedSheet)
    }

    @MainActor
    func testRootConfirmationsUseGlassSheetsAttachedToThePanel() throws {
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

            let dialog = try XCTUnwrap(panel.attachedSheet)
            XCTAssertTrue(dialog.canBecomeKey)
            XCTAssertFalse(dialog.isOpaque)
            XCTAssertTrue(dialog.sheetParent === panel)
            XCTAssertNil(dialog.attachedSheet)

            coordinator.dismissPanelDialog(id: id)
            XCTAssertNil(panel.attachedSheet)
        }
    }

    @MainActor
    func testOpenPanelBlocksParentActionsAndClearsAfterCompletion() async throws {
        let defaultsName = "Snip SnapOpenPanelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let parent = NSWindow()
        let importer = StandaloneFileImporter.makePanel()
        var panelCompletion: ((NSApplication.ModalResponse) -> Void)?
        var importedURLs: [URL]?
        let coordinator = AppCoordinator(
            model: AppModel(
                library: try JSONSnipLibrary(fileURL: storeURL()),
                defaults: defaults
            ),
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false },
            beginFilePanel: { panel, sheetParent, completion in
                XCTAssertTrue(panel === importer)
                XCTAssertTrue(sheetParent === parent)
                panelCompletion = completion
            }
        )
        coordinator.attachPanelWindow(parent)

        XCTAssertTrue(coordinator.presentOpenPanel(importer) { importedURLs = $0 })

        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        // The injected presenter captures the request without asking AppKit to show it.
        XCTAssertNil(parent.attachedSheet)
        XCTAssertFalse(parent.childWindows?.contains(importer) == true)
        XCTAssertFalse(coordinator.presentOpenPanel(NSOpenPanel()) { _ in })

        panelCompletion?(.cancel)
        await Task.yield()

        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertNil(importedURLs)
    }

    @MainActor
    func testSavePanelUsesTheAttachedFilePanelFlow() async throws {
        let defaultsName = "Snip SnapSavePanelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let parent = NSWindow()
        let exporter = NSSavePanel()
        var panelCompletion: ((NSApplication.ModalResponse) -> Void)?
        var exportedURL: URL?
        let coordinator = AppCoordinator(
            model: AppModel(
                library: try JSONSnipLibrary(fileURL: storeURL()),
                defaults: defaults
            ),
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false },
            beginFilePanel: { panel, sheetParent, completion in
                XCTAssertTrue(panel === exporter)
                XCTAssertTrue(sheetParent === parent)
                XCTAssertTrue(parent.isVisible)
                panelCompletion = completion
            }
        )
        coordinator.attachPanelWindow(parent)
        defer { parent.orderOut(nil) }

        XCTAssertTrue(coordinator.presentSavePanel(exporter) { exportedURL = $0 })
        XCTAssertTrue(coordinator.panelDialogs.isPresented)

        panelCompletion?(.cancel)
        await Task.yield()

        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertNil(exportedURL)
    }

    @MainActor
    func testHidingPanelCancelsOwnedOpenPanel() throws {
        let defaultsName = "Snip SnapOpenPanelHideTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let parent = NSWindow()
        let importer = StandaloneFileImporter.makePanel()
        var didCancel = false
        var didComplete = false
        let coordinator = AppCoordinator(
            model: AppModel(
                library: try JSONSnipLibrary(fileURL: storeURL()),
                defaults: defaults
            ),
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false },
            beginFilePanel: { _, _, _ in },
            cancelFilePanel: { panel in
                XCTAssertTrue(panel === importer)
                didCancel = true
            }
        )
        coordinator.attachPanelWindow(parent)
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }
        coordinator.presentOpenPanel(importer) { urls in
            XCTAssertNil(urls)
            didComplete = true
        }

        coordinator.hidePanel(restoringPreviousApplication: false)

        XCTAssertTrue(didCancel)
        XCTAssertTrue(didComplete)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertFalse(parent.isVisible)
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
        XCTAssertNil(parent.attachedSheet)
    }

    @MainActor
    func testPendingFormErrorMovesToAPanelSheetAfterHideAndReopen() async throws {
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
        let formWindow = try XCTUnwrap(panel.attachedSheet)
        model.presentError("Dialog save failed")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(formWindow.attachedSheet)

        coordinator.togglePanel()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(panel.isVisible)
        XCTAssertNotNil(model.presentedError)
        XCTAssertNil(panel.attachedSheet)

        coordinator.togglePanel()

        let errorWindow = try XCTUnwrap(panel.attachedSheet)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(errorWindow.isOpaque)
        XCTAssertTrue(errorWindow.sheetParent === panel)
        XCTAssertNil(errorWindow.attachedSheet)

        model.dismissPresentedError()
        coordinator.updatePresentedError()
    }

    @MainActor
    func testPendingFormErrorMovesToAPanelSheetAfterNormalDismissal() async throws {
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
        XCTAssertNotNil(panel.attachedSheet)
        model.presentError("Dialog save failed")

        coordinator.dismissPanelDialog(id: .newList)
        try await Task.sleep(for: .milliseconds(100))

        let errorWindow = try XCTUnwrap(panel.attachedSheet)
        XCTAssertFalse(errorWindow.isOpaque)
        XCTAssertTrue(errorWindow.sheetParent === panel)
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
        XCTAssertNil(panel.attachedSheet)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertNotNil(model.presentedError)

        coordinator.togglePanel()

        let errorWindow = try XCTUnwrap(panel.attachedSheet)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(errorWindow.isOpaque)
        XCTAssertTrue(errorWindow.sheetParent === panel)
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
