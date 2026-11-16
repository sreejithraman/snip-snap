import XCTest
import SnipSnapCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import SwiftUI
import Synchronization
@testable import SnipSnap
@testable import SnipSnapPersistence

private final class ShortcutDiagnosticProbe: Sendable {
    private let recorded = Mutex<[AppDiagnosticEvent]>([])
    var recorder: AppDiagnosticRecorder {
        AppDiagnosticRecorder { [self] event in recorded.withLock { $0.append(event) } }
    }
    var events: [AppDiagnosticEvent] { recorded.withLock { $0 } }
}

final class AppCoordinatorTests: StoreBackedTestCase {
    @MainActor
    func testShortcutStartupFailureRecordsItsOperationWithoutTheAlertMessage() {
        let events = ShortcutDiagnosticProbe()
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults(), diagnostics: events.recorder)
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults()),
            makeHotKeyManager: { _ in StubGlobalHotKeyManager(error: GlobalHotKeyError.registration(-9876)) },
            isAccessibilityTrusted: { true }
        )

        coordinator.start()

        XCTAssertNotNil(model.presentedError)
        XCTAssertTrue(events.events.contains {
            $0.operation == "shortcut.register" && $0.errorCode == "shortcut.registrationFailed"
                && $0.outcome == .failed && $0.visibility == .user
        })
        XCTAssertFalse(events.events.map(\.line).joined().contains("-9876"))
    }

    @MainActor
    func testRecordingRejectsUnregisterableChordAndResumesPreviousShortcuts() throws {
        let settings = ShortcutSettings(defaults: defaults())
        let original = StubGlobalHotKeyManager()
        let failedCandidate = StubGlobalHotKeyManager(error: StubHotKeyError.registration)
        let resumed = StubGlobalHotKeyManager()
        var managers = [original, failedCandidate, resumed]
        let coordinator = AppCoordinator(
            model: AppModel(library: try JSONSnipLibrary(fileURL: storeURL()), defaults: defaults()),
            shortcutSettings: settings,
            makeHotKeyManager: { _ in managers.removeFirst() },
            isAccessibilityTrusted: { true }
        )
        coordinator.start()
        let recorder = NSObject()
        ShortcutRecordingState.begin(recorder)
        defer { ShortcutRecordingState.end(recorder) }

        XCTAssertThrowsError(try coordinator.setShortcut(
            .keyChord(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), keyLabel: "K"),
            for: .togglePanel
        ))
        XCTAssertEqual(settings.configuration, .snipSnapDefaults)

        ShortcutRecordingState.end(recorder)

        XCTAssertEqual(resumed.registeredConfigurations, [.snipSnapDefaults])
    }

    @MainActor
    func testRecordingReleasesGlobalKeyChordsAndRestoresThemAfterRecording() throws {
        let suiteName = "Snip SnapShortcutRecordingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ShortcutSettings(defaults: defaults)
        let chord = ShortcutKeyChord(keyCode: kVK_ANSI_K, modifiers: controlKey | optionKey, keyLabel: "K")
        settings.save(try settings.candidate(setting: .keyChord(chord), for: .togglePanel))
        let coordinator = AppCoordinator(
            model: AppModel(library: try JSONSnipLibrary(fileURL: storeURL()), defaults: defaults),
            shortcutSettings: settings,
            isAccessibilityTrusted: { true }
        )
        let button = ShortcutRecorderButton.RecorderButton()
        let window = NSWindow()
        window.contentView = button
        defer { window.contentView = nil }
        var recorded: ShortcutTrigger?
        button.onRecord = {
            recorded = $0
            do {
                try coordinator.setShortcut($0, for: .togglePanel)
            } catch {
                XCTFail("Saving the recorded shortcut failed: \(error)")
            }
            XCTAssertTrue(chordIsAvailable(), "Saving must leave live chords suspended until recording ends")
        }

        func chordIsAvailable() -> Bool {
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(
                chord.keyCode, chord.modifiers,
                EventHotKeyID(signature: 0x54455354, id: 1),
                GetApplicationEventTarget(), 0, &hotKey
            )
            if let hotKey { UnregisterEventHotKey(hotKey) }
            return status == noErr
        }
        guard chordIsAvailable() else {
            throw XCTSkip("The OS could not provide the integration test's chord")
        }
        coordinator.start()
        XCTAssertFalse(chordIsAvailable())

        button.performClick(nil)

        XCTAssertTrue(chordIsAvailable(), "The recorder must receive an already assigned global chord")
        button.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option],
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "k", charactersIgnoringModifiers: "k", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_K)
        )))

        XCTAssertEqual(recorded, .keyChord(chord))
        XCTAssertFalse(chordIsAvailable(), "Global chords must resume after recording")
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testFailedShortcutChangeRestoresThePreviousChord() throws {
        let suiteName = "Snip SnapShortcutRollbackTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let previous = ShortcutKeyChord.globalShortcutTestChord(keyCode: kVK_ANSI_I, keyLabel: "I")
        let occupied = ShortcutKeyChord.globalShortcutTestChord(keyCode: kVK_ANSI_O, keyLabel: "O")
        try requireAvailableChords(previous, occupied)
        let settings = ShortcutSettings(defaults: defaults)
        settings.save(try settings.candidate(setting: .keyChord(previous), for: .togglePanel))
        let coordinator = AppCoordinator(
            model: AppModel(library: try JSONSnipLibrary(fileURL: storeURL()), defaults: defaults),
            shortcutSettings: settings,
            isAccessibilityTrusted: { true }
        )
        coordinator.start()
        XCTAssertFalse(previous.isAvailableToRegister)
        var occupant: EventHotKeyRef? = try XCTUnwrap(occupied.hold())
        defer { releaseHeldChord(&occupant) }

        XCTAssertThrowsError(try coordinator.setShortcut(.keyChord(occupied), for: .togglePanel)) { error in
            guard case GlobalHotKeyError.registration = error else {
                return XCTFail("Expected a registration failure, got \(error)")
            }
        }

        XCTAssertFalse(previous.isAvailableToRegister, "A failed change must restore the previous chord")
        XCTAssertEqual(settings.configuration.togglePanel, .keyChord(previous))
        withExtendedLifetime(coordinator) {}
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
        let dialog = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertFalse(dialog.isOpaque)
        XCTAssertTrue(panel.childWindows?.contains(dialog) == true)
        XCTAssertNil(panel.attachedSheet)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001)
        panel.setFrameOrigin(NSPoint(x: 180, y: 180))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dialog.frame.midX, panel.frame.midX, accuracy: 0.5)
        XCTAssertEqual(dialog.frame.midY, panel.frame.midY, accuracy: 0.5)
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

        XCTAssertTrue(panel.childWindows?.first === dialog)
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
        XCTAssertNil(panel.childWindows?.first)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001)
    }

    @MainActor
    func testFileDropCannotChangeComposerDuringPanelDialog() async throws {
        let defaultsName = "Snip SnapDialogDropTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(
            library: try JSONSnipLibrary(fileURL: storeURL()),
            defaults: defaults
        )
        let settings = ShortcutSettings(defaults: defaults)
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: settings,
            isAccessibilityTrusted: { true }
        )
        let fileDrops = PanelFileDropController()
        let content = ContentView(
            coordinator: coordinator,
            fileDropController: fileDrops,
            dragSessionController: PanelDragSessionController()
        )
        .environmentObject(model)
        .environmentObject(settings)
        let hostingController = NSHostingController(rootView: content)
        let parent = SnipSnapPanel.make(
            contentViewController: hostingController,
            frameAutosaveName: nil
        )
        coordinator.attachPanelWindow(parent)
        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))

        let firstFile = try storeURL().deletingLastPathComponent()
            .appendingPathComponent("first-drop.txt")
        let secondFile = try storeURL().deletingLastPathComponent()
            .appendingPathComponent("blocked-drop.txt")
        try Data().write(to: firstFile)
        try Data().write(to: secondFile)
        fileDrops.fileDrops.send([firstFile])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.composerDraft(for: model.activeListID).attachments, [firstFile])

        coordinator.presentPanelDialog(id: .newList, title: "New list") {} content: {
            Text("Dialog")
        }
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertFalse(parent.canBecomeKey)
        fileDrops.fileDrops.send([secondFile])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.composerDraft(for: model.activeListID).attachments, [firstFile])

        coordinator.dismissPanelDialog(id: .newList)
        XCTAssertTrue(parent.canBecomeKey)
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

        XCTAssertNil(parent.childWindows?.first)

        panelCompletion?(.cancel)
        await Task.yield()

        XCTAssertNotNil(parent.childWindows?.first)
        XCTAssertEqual(parent.childWindows?.first?.isOpaque, false)
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
        XCTAssertNil(parent.childWindows?.first)

        coordinator.togglePanel()

        XCTAssertTrue(parent.isVisible)
        XCTAssertNotNil(parent.childWindows?.first)
        XCTAssertEqual(parent.childWindows?.first?.isOpaque, false)
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
        // Receive native key notifications even when the XCTest host is inactive.
        let parent = SnipSnapPanel(
            contentRect: NSRect(origin: .zero, size: AppWindowDefaults.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        parent.becomesKeyOnlyIfNeeded = false
        coordinator.attachPanelWindow(parent)
        coordinator.presentPanelDialog(id: .backupImport, title: "Import") {} content: {
            Text("Review backup")
        }

        XCTAssertFalse(parent.isVisible)
        XCTAssertNil(parent.childWindows?.first)
        let dialogBecameKey = expectation(
            forNotification: NSWindow.didBecomeKeyNotification,
            object: nil
        ) { notification in
            let window = notification.object as? NSWindow
            return MainActor.assumeIsolated {
                window?.parent === parent
            }
        }

        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }
        await fulfillment(of: [dialogBecameKey], timeout: 2)

        XCTAssertNotNil(parent.childWindows?.first)
        XCTAssertEqual(parent.childWindows?.first?.isOpaque, false)
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
        let newListWindow = try XCTUnwrap(parent.childWindows?.first)

        coordinator.presentPanelDialog(id: .backupImport, title: "Import") {} content: {
            Text("Review backup")
        }

        XCTAssertTrue(parent.childWindows?.first === newListWindow)
        XCTAssertFalse(didDismissNewList)

        coordinator.dismissPanelDialog(id: .newList)
        await Task.yield()

        XCTAssertTrue(didDismissNewList)
        XCTAssertNotNil(parent.childWindows?.first)
        XCTAssertFalse(parent.childWindows?.first === newListWindow)
        coordinator.dismissPanelDialog(id: .backupImport)
    }

    @MainActor
    func testActivePanelDialogKeepsCompletionUndoActionable() async throws {
        let snip = Snip(content: "Undo in dialog", origin: .quickEntry)
        let model = AppModel(library: InMemorySnipLibrary(snips: [snip]), defaults: defaults())
        await model.reload()
        await model.setDoneAfterExternalDropNow(versions: [snip.id: snip.updatedAt])
        let coordinator = AppCoordinator(
            model: model, shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { true }
        )
        let parent = SnipSnapPanel.make(
            contentViewController: NSHostingController(rootView: Text("Panel")),
            frameAutosaveName: nil
        )
        coordinator.attachPanelWindow(parent)
        parent.makeKeyAndOrderFront(nil)
        defer {
            coordinator.dismissPanelDialog(id: .newList)
            parent.orderOut(nil)
        }
        coordinator.presentPanelDialog(id: .newList, title: "New list", onDismiss: {}) {
            Text("Dialog stays open")
        }
        let dialog = try XCTUnwrap(parent.childWindows?.first)
        let root = try XCTUnwrap(dialog.contentView)
        let accessibility = try MountedAccessibility(root: root)
        let undo = try await accessibility.button(identifier: "toast-action")

        XCTAssertTrue(accessibility.press(undo))

        let restorationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.snips.first?.isDone == true, ContinuousClock.now < restorationDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(try XCTUnwrap(model.snips.first).isDone)
        XCTAssertNil(model.toast)
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(parent.childWindows?.first === dialog)
    }

    @MainActor
    func testSnackbarDetailsActionClosesTheSnackbarBeforeOpeningDetails() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        let coordinator = AppCoordinator(
            model: model, shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { true }
        )
        let parent = SnipSnapPanel.make(
            contentViewController: NSHostingController(rootView: Text("Panel")),
            frameAutosaveName: nil
        )
        coordinator.attachPanelWindow(parent)
        parent.makeKeyAndOrderFront(nil)
        defer {
            coordinator.dismissPanelDialog(id: .newList)
            parent.orderOut(nil)
        }
        coordinator.presentPanelDialog(id: .newList, title: "New list", onDismiss: {}) {
            Text("Dialog stays open")
        }
        model.presentError(SnipLibraryError.attachmentCopyFailed, operation: "clipboard.export")
        let failure = try XCTUnwrap(model.latestFailure)
        XCTAssertEqual(model.toast?.action, .showErrorDetails(failure.id))
        let dialog = try XCTUnwrap(parent.childWindows?.first)
        let accessibility = try MountedAccessibility(root: try XCTUnwrap(dialog.contentView))
        let details = try await accessibility.button(identifier: "toast-action")

        XCTAssertTrue(accessibility.press(details))

        XCTAssertNil(model.toast, "The presenter must close the snackbar before its action runs.")
        XCTAssertNil(model.errorDetails)
        let detailsDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.errorDetails == nil, ContinuousClock.now < detailsDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.errorDetails?.id, failure.id)
        XCTAssertEqual(model.dialogFailure?.id, failure.id)
        XCTAssertNil(model.toast)
    }

    @MainActor
    func testMountedErrorDialogResetsCopyConfirmationForAReplacementIncident() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { true }
        )
        let parent = SnipSnapPanel.make(
            contentViewController: NSHostingController(rootView: Text("Panel")),
            frameAutosaveName: nil
        )
        coordinator.attachPanelWindow(parent)
        parent.makeKeyAndOrderFront(nil)
        let pasteboard = NSPasteboard.general
        let originalClipboard = try XCTUnwrap(PasteboardSnapshotStore.snapshot(pasteboard))
        var copiedRevision = originalClipboard.changeCount
        defer {
            coordinator.dismissPanelDialog(id: .error)
            parent.orderOut(nil)
            _ = PasteboardSnapshotStore.restore(
                originalClipboard, to: pasteboard, ifChangeCountIs: copiedRevision
            )
        }

        model.presentError("Private incident A")
        coordinator.updatePresentedError()
        let firstFailure = try XCTUnwrap(model.dialogFailure)
        let errorWindow = try XCTUnwrap(parent.childWindows?.first)
        let mountedController = try XCTUnwrap(errorWindow.contentViewController)
        let root = try XCTUnwrap(errorWindow.contentView)
        let accessibility = try MountedAccessibility(root: root)
        let copyLabel = String(localized: "Copy error details")
        let copiedLabel = String(localized: "Error details copied")
        let firstCopyButton = try await accessibility.button(identifier: "copy-error-details", label: copyLabel)

        XCTContext.runActivity(named: "Copy details for the first incident") { _ in
            XCTAssertTrue(accessibility.press(firstCopyButton))
        }
        _ = try await accessibility.button(identifier: "copy-error-details", label: copiedLabel)
        copiedRevision = pasteboard.changeCount
        let firstReport = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(firstReport.contains(firstFailure.id.uuidString))
        XCTAssertFalse(firstReport.contains("Private incident A"))

        model.presentError("Private incident B")
        coordinator.updatePresentedError()
        let replacement = try XCTUnwrap(model.dialogFailure)

        XCTAssertNotEqual(replacement.id, firstFailure.id)
        XCTAssertTrue(parent.childWindows?.first === errorWindow)
        XCTAssertTrue(errorWindow.contentViewController === mountedController)
        let replacementCopyButton = try await accessibility.button(identifier: "copy-error-details", label: copyLabel)
        XCTAssertEqual(pasteboard.string(forType: .string), firstReport)
        XCTContext.runActivity(named: "Copy details for the replacement incident") { _ in
            XCTAssertTrue(accessibility.press(replacementCopyButton))
        }
        _ = try await accessibility.button(identifier: "copy-error-details", label: copiedLabel)
        copiedRevision = pasteboard.changeCount
        let replacementReport = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(replacementReport.contains(replacement.id.uuidString))
        XCTAssertFalse(replacementReport.contains(firstFailure.id.uuidString))
        XCTAssertFalse(replacementReport.contains("Private incident B"))
    }

    @MainActor
    func testVisiblePanelPresentsUndoFailureWithTheSameMessageAsAnInlineFailure() async throws {
        let defaultsName = "SnipSnapEqualMessageDialogTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let snip = Snip(content: "Recover this completion", origin: .quickEntry)
        let library = InMemorySnipLibrary(snips: [snip])
        let model = AppModel(
            library: library,
            defaults: defaults
        )
        await model.reload()
        await model.setDoneAfterExternalDropNow(versions: [snip.id: snip.updatedAt])
        let undo = try XCTUnwrap(model.toast)
        model.closeSnackbar(undo)
        let settings = ShortcutSettings(defaults: defaults)
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: settings,
            isAccessibilityTrusted: { true }
        )
        let content = ContentView(
            coordinator: coordinator,
            fileDropController: PanelFileDropController(),
            dragSessionController: PanelDragSessionController()
        )
        .environmentObject(model)
        .environmentObject(settings)
        let parent = SnipSnapPanel.make(
            contentViewController: NSHostingController(rootView: content),
            frameAutosaveName: nil
        )
        coordinator.attachPanelWindow(parent)
        parent.makeKeyAndOrderFront(nil)
        defer {
            coordinator.dismissPanelDialog(id: .error)
            parent.orderOut(nil)
        }
        try await Task.sleep(for: .milliseconds(100))
        model.presentError(SnipLibraryError.storeUnavailable, operation: "clipboard.write")
        try await Task.sleep(for: .milliseconds(100))
        let inlineMessage = model.presentedError
        XCTAssertNil(model.dialogFailure)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)

        await library.failNextCheckedRead()
        await model.performToastActionNow(undo)

        XCTAssertEqual(model.presentedError, inlineMessage)
        XCTAssertEqual(model.dialogFailure?.operation, "snip.undo_done")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !coordinator.panelDialogs.isPresented, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        let errorWindow = try XCTUnwrap(parent.childWindows?.first)
        XCTAssertTrue(errorWindow.canBecomeKey)
        XCTAssertNil(errorWindow.attachedSheet)
        XCTAssertTrue(model.canRetryErrorAction)

        model.presentError(SnipLibraryError.storeUnavailable, operation: "clipboard.write")
        let newerFailure = try XCTUnwrap(model.latestFailure)
        let dismissalDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while coordinator.panelDialogs.isPresented, ContinuousClock.now < dismissalDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        let pendingUndo = try XCTUnwrap(model.pendingUndoFailure)
        let renderedPanel = try XCTUnwrap(parent.contentView)
        renderedPanel.layoutSubtreeIfNeeded()
        renderedPanel.displayIfNeeded()
        let bitmap = try XCTUnwrap(renderedPanel.bitmapImageRepForCachingDisplay(in: renderedPanel.bounds))
        renderedPanel.cacheDisplay(in: renderedPanel.bounds, to: bitmap)
        let image = NSImage(size: renderedPanel.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Mac retained Undo recovery in the main panel"
        attachment.lifetime = .keepAlways
        add(attachment)

        await model.retryPendingUndoNow(pendingUndo)

        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == snip.id }).isDone)
        XCTAssertNil(model.pendingUndoFailure)
        XCTAssertEqual(model.latestFailure?.id, newerFailure.id)
    }

    @MainActor
    func testRootErrorUsesAnOwnedGlassDialog() throws {
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
        XCTAssertTrue(errorWindow.canBecomeKey)
        XCTAssertFalse(errorWindow.isOpaque)
        XCTAssertTrue(panel.childWindows?.contains(errorWindow) == true)
        XCTAssertNil(errorWindow.attachedSheet)

        coordinator.togglePanel()

        XCTAssertFalse(panel.isVisible)
        XCTAssertNotNil(model.presentedError)

        coordinator.togglePanel()

        let reopenedErrorWindow = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertFalse(reopenedErrorWindow.isOpaque)
        XCTAssertTrue(panel.childWindows?.contains(reopenedErrorWindow) == true)

        model.dismissPresentedError()
        coordinator.updatePresentedError()

        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertNil(panel.childWindows?.first)
    }

    @MainActor
    func testRootConfirmationsUseOwnedGlassDialogs() throws {
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
            XCTAssertTrue(dialog.canBecomeKey)
            XCTAssertFalse(dialog.isOpaque)
            XCTAssertTrue(panel.childWindows?.contains(dialog) == true)
            XCTAssertNil(dialog.attachedSheet)

            coordinator.dismissPanelDialog(id: id)
            XCTAssertNil(panel.childWindows?.first)
        }
    }

    @MainActor
    func testOpenPanelBlocksParentActionsAndClearsAfterCompletion() async throws {
        let defaultsName = "Snip SnapOpenPanelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        // Exercise native key restoration without requiring app activation
        // permission for the XCTest host.
        let parent = SnipSnapPanel(
            contentRect: NSRect(origin: .zero, size: AppWindowDefaults.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        parent.becomesKeyOnlyIfNeeded = false
        let pickerFocusWindow = NSPanel(
            contentRect: NSRect(x: 20, y: 20, width: 200, height: 100),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pickerFocusWindow.becomesKeyOnlyIfNeeded = false
        defer {
            pickerFocusWindow.orderOut(nil)
            parent.orderOut(nil)
        }
        let importer = StandaloneFileImporter.makePanel()
        var panelCompletion: ((NSApplication.ModalResponse) -> Void)?
        var importedURLs: [URL]?
        var keyTransitions: [String] = []
        let importFinished = expectation(description: "File picker completion handled")
        let model = AppModel(
            library: try JSONSnipLibrary(fileURL: storeURL()),
            defaults: defaults
        )
        model.setAppearance(.light)
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(defaults: defaults),
            isAccessibilityTrusted: { false },
            beginFilePanel: { panel, sheetParent, completion in
                XCTAssertTrue(panel === importer)
                XCTAssertTrue(sheetParent === parent)
                panelCompletion = completion
                pickerFocusWindow.makeKeyAndOrderFront(nil)
            }
        )
        coordinator.attachPanelWindow(parent)

        // Keep opening a hidden parent (and activating the app) out of this
        // picker-focus test, so activation cannot race the simulated picker.
        parent.makeKeyAndOrderFront(nil)
        let pickerBecameKey = expectation(
            forNotification: NSWindow.didBecomeKeyNotification,
            object: pickerFocusWindow
        ) { _ in
            MainActor.assumeIsolated {
                keyTransitions.append("picker")
                return true
            }
        }
        XCTAssertTrue(coordinator.presentOpenPanel(importer) {
            importedURLs = $0
            importFinished.fulfill()
        })
        await fulfillment(of: [pickerBecameKey], timeout: 2)

        // Native key transitions are the contract; desktop focus may move again
        // before XCTest resumes or while AppKit delivers the notification.
        XCTAssertEqual(keyTransitions, ["picker"])
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertFalse(parent.canBecomeKey)
        XCTAssertEqual(parent.alphaValue, 0.45, accuracy: 0.001)
        XCTAssertEqual(importer.appearance?.name, .aqua)
        XCTAssertNil(parent.childWindows?.first)
        XCTAssertFalse(parent.childWindows?.contains(importer) == true)
        XCTAssertFalse(coordinator.presentOpenPanel(NSOpenPanel()) { _ in })

        let parentRegainedKey = expectation(
            forNotification: NSWindow.didBecomeKeyNotification,
            object: parent
        ) { _ in
            MainActor.assumeIsolated {
                keyTransitions.append("parent")
                return true
            }
        }
        pickerFocusWindow.orderOut(nil)
        panelCompletion?(.cancel)
        await fulfillment(of: [parentRegainedKey, importFinished], timeout: 2)

        XCTAssertEqual(keyTransitions, ["picker", "parent"])
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(parent.canBecomeKey)
        XCTAssertEqual(parent.alphaValue, 1, accuracy: 0.001)
        XCTAssertNil(importedURLs)
    }

    @MainActor
    func testSavePanelUsesTheOwnedFilePanelFlow() async throws {
        let defaultsName = "Snip SnapSavePanelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let parent = NSWindow()
        let exporter = NSSavePanel()
        var panelCompletion: ((NSApplication.ModalResponse) -> Void)?
        var exportedURL: URL?
        let model = AppModel(
            library: try JSONSnipLibrary(fileURL: storeURL()),
            defaults: defaults
        )
        model.setAppearance(.dark)
        let coordinator = AppCoordinator(
            model: model,
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
        XCTAssertEqual(parent.alphaValue, 0.45, accuracy: 0.001)
        XCTAssertEqual(exporter.appearance?.name, .darkAqua)

        panelCompletion?(.cancel)
        await Task.yield()

        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertEqual(parent.alphaValue, 1, accuracy: 0.001)
        XCTAssertNil(exportedURL)
    }

    @MainActor
    func testReusingPickerIgnoresCompletionFromPreviousPresentation() async throws {
        let parent = NSWindow()
        defer { parent.orderOut(nil) }
        let picker = NSOpenPanel()
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        let coordinator = AppCoordinator(
            model: AppModel(library: try JSONSnipLibrary(fileURL: storeURL()), defaults: defaults()),
            shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { false },
            beginFilePanel: { _, _, completion in completions.append(completion) }
        )
        coordinator.attachPanelWindow(parent)
        var firstCompletionCount = 0
        var secondCompletionCount = 0
        XCTAssertTrue(coordinator.presentOpenPanel(picker) { _ in
            firstCompletionCount += 1
            XCTAssertTrue(coordinator.presentOpenPanel(picker) { _ in secondCompletionCount += 1 })
        })
        completions[0](.cancel)
        await Task.yield()
        XCTAssertEqual(firstCompletionCount, 1)

        completions[0](.cancel)
        await Task.yield()

        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertEqual(parent.alphaValue, 0.45, accuracy: 0.001)
        XCTAssertEqual(secondCompletionCount, 0)
        completions[1](.cancel)
        await Task.yield()
        XCTAssertEqual(secondCompletionCount, 1)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertEqual(parent.alphaValue, 1, accuracy: 0.001)
    }

    @MainActor
    func testHidingRetiresPickerBeforeCallbacksAndCleansUpReentrantRequests() async throws {
        let parent = SnipSnapPanel(
            contentRect: NSRect(origin: .zero, size: AppWindowDefaults.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        parent.alphaValue = 0.8
        defer { parent.orderOut(nil) }
        let picker = NSOpenPanel()
        var nativeCompletion: ((NSApplication.ModalResponse) -> Void)?
        var events: [String] = []
        var coordinator: AppCoordinator!
        coordinator = AppCoordinator(
            model: AppModel(library: try JSONSnipLibrary(fileURL: storeURL()), defaults: defaults()),
            shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { false },
            beginFilePanel: { _, _, completion in nativeCompletion = completion },
            cancelFilePanel: { _ in
                XCTAssertEqual(parent.alphaValue, 0.8, accuracy: 0.001)
                XCTAssertTrue(parent.canBecomeKey)
                XCTAssertTrue(coordinator.panelDialogs.isPresented)
                XCTAssertFalse(coordinator.presentOpenPanel(NSOpenPanel()) { _ in })
                nativeCompletion?(.cancel)
                coordinator.presentPanelDialog(id: .recovery, title: "During cancel") {
                    events.append("cancel request dismissed")
                } content: { Text("Recovery") }
            }
        )
        coordinator.attachPanelWindow(parent)
        XCTAssertTrue(coordinator.presentOpenPanel(picker) { urls in
            XCTAssertNil(urls)
            events.append("picker completed")
            XCTAssertFalse(coordinator.presentOpenPanel(NSOpenPanel()) { _ in })
            coordinator.presentPanelDialog(id: .newList, title: "During completion") {
                events.append("completion request dismissed")
            } content: { Text("New list") }
        })
        coordinator.presentPanelDialog(id: .backupImport, title: "Already pending") {
            events.append("pending dismissed")
        } content: { Text("Import") }

        coordinator.hidePanel(restoringPreviousApplication: false)
        await Task.yield()

        XCTAssertEqual(events, [
            "picker completed", "pending dismissed", "cancel request dismissed",
            "completion request dismissed"
        ])
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertFalse(parent.isVisible)
        XCTAssertEqual(parent.alphaValue, 0.8, accuracy: 0.001)
        coordinator.togglePanel()
        XCTAssertTrue(parent.isVisible)
        XCTAssertNil(parent.childWindows?.first)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
    }

    @MainActor
    func testHidingDialogsPreservesDismissalOrderAndBlocksCallbackPresentation() throws {
        let parent = NSWindow()
        parent.setContentSize(NSSize(width: 382, height: 500))
        defer { parent.orderOut(nil) }
        let coordinator = AppCoordinator(
            model: AppModel(library: try JSONSnipLibrary(fileURL: storeURL()), defaults: defaults()),
            shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { false },
            beginFilePanel: { _, _, _ in XCTFail("No picker may begin during hide") }
        )
        coordinator.attachPanelWindow(parent)
        parent.makeKeyAndOrderFront(nil)
        var events: [String] = []
        coordinator.presentPanelDialog(id: .newList, title: "Active") {
            events.append("active dismissed")
            XCTAssertFalse(coordinator.presentOpenPanel(NSOpenPanel()) { _ in })
            coordinator.presentPanelDialog(id: .recovery, title: "During active dismissal") {
                events.append("reentrant dismissed")
            } content: { Text("Recovery") }
        } content: { Text("New list") }
        coordinator.presentPanelDialog(id: .backupImport, title: "Pending") {
            XCTAssertNil(parent.childWindows?.first)
            events.append("pending dismissed")
            XCTAssertFalse(coordinator.presentOpenPanel(NSOpenPanel()) { _ in })
            coordinator.togglePanel()
        } content: { Text("Import") }
        coordinator.presentPanelDialog(id: .error, title: "Pending error") {
            XCTFail("Parent hide must leave the model error unacknowledged")
        } content: { Text("Error") }

        coordinator.hidePanel(restoringPreviousApplication: false)

        XCTAssertEqual(events, ["pending dismissed", "active dismissed", "reentrant dismissed"])
        XCTAssertFalse(parent.isVisible)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        coordinator.togglePanel()
        XCTAssertTrue(parent.isVisible)
        XCTAssertNil(parent.childWindows?.first)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
    }

    @MainActor
    func testHidingCoalescesRetryRequestsRaisedByTerminalDismissal() throws {
        let parent = NSWindow()
        parent.setContentSize(NSSize(width: 382, height: 500))
        defer { parent.orderOut(nil) }
        let coordinator = AppCoordinator(
            model: AppModel(library: try JSONSnipLibrary(fileURL: storeURL()), defaults: defaults()),
            shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { false }
        )
        coordinator.attachPanelWindow(parent)
        parent.makeKeyAndOrderFront(nil)
        var cleanupCount = 0
        var originalDismissals: [String] = []
        func requestRetry() {
            coordinator.presentPanelDialog(id: .recovery, title: "Retry") {
                cleanupCount += 1
                // Bound the fixture so the old implementation fails without hanging.
                if cleanupCount < 3 { requestRetry() }
            } content: { Text("Recovery") }
        }
        coordinator.presentPanelDialog(id: .newList, title: "Active") {
            originalDismissals.append("active")
            requestRetry()
        } content: { Text("New list") }
        // The queued request shares the active workflow ID but owns its callback.
        coordinator.presentPanelDialog(id: .newList, title: "Pending") {
            originalDismissals.append("pending")
        } content: { Text("New list") }

        coordinator.hidePanel(restoringPreviousApplication: false)

        XCTAssertEqual(originalDismissals, ["pending", "active"])
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertFalse(parent.isVisible)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        coordinator.togglePanel()
        XCTAssertTrue(parent.isVisible)
        XCTAssertNil(parent.childWindows?.first)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
    }

    @MainActor
    func testHidingTerminalCleanupCannotCascadeThroughFreshDialogIDs() throws {
        let parent = NSWindow()
        parent.setContentSize(NSSize(width: 382, height: 500))
        defer { parent.orderOut(nil) }
        let coordinator = AppCoordinator(
            model: AppModel(library: try JSONSnipLibrary(fileURL: storeURL()), defaults: defaults()),
            shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { false }
        )
        coordinator.attachPanelWindow(parent)
        parent.makeKeyAndOrderFront(nil)
        var cleanupCount = 0
        func requestAnotherListEditor() {
            coordinator.presentPanelDialog(id: .editList(UUID()), title: "Edit list") {
                cleanupCount += 1
                if cleanupCount < 3 { requestAnotherListEditor() }
            } content: { Text("Edit list") }
        }
        coordinator.presentPanelDialog(id: .newList, title: "Active") {
            requestAnotherListEditor()
        } content: { Text("New list") }

        coordinator.hidePanel(restoringPreviousApplication: false)

        XCTAssertEqual(cleanupCount, 1)
        XCTAssertFalse(parent.isVisible)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        coordinator.togglePanel()
        XCTAssertTrue(parent.isVisible)
        XCTAssertNil(parent.childWindows?.first)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
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
        XCTAssertEqual(parent.alphaValue, 1, accuracy: 0.001)
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
        XCTAssertNil(parent.childWindows?.first)
    }

    @MainActor
    func testPendingFormErrorMovesToAnOwnedDialogAfterHideAndReopen() async throws {
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
        XCTAssertNil(panel.childWindows?.first)

        coordinator.togglePanel()

        let errorWindow = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(errorWindow.isOpaque)
        XCTAssertTrue(panel.childWindows?.contains(errorWindow) == true)
        XCTAssertNil(errorWindow.attachedSheet)

        model.dismissPresentedError()
        coordinator.updatePresentedError()
    }

    @MainActor
    func testPendingFormErrorMovesToAnOwnedDialogAfterNormalDismissal() async throws {
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
        XCTAssertFalse(errorWindow.isOpaque)
        XCTAssertTrue(panel.childWindows?.contains(errorWindow) == true)
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
        XCTAssertNil(panel.childWindows?.first)
        XCTAssertFalse(coordinator.panelDialogs.isPresented)
        XCTAssertNotNil(model.presentedError)

        coordinator.togglePanel()

        let errorWindow = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(errorWindow.isOpaque)
        XCTAssertTrue(panel.childWindows?.contains(errorWindow) == true)
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

        XCTAssertTrue(model.placeOnClipboard(.clipboardEntry(entry), feedback: .notify))

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
    func testComposerExpansionOnlyChangesTheAttachedPanelWindow() throws {
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
        let panelFrame = panel.frame
        let editorFrame = editor.frame

        coordinator.updatePanelComposerExpansion(44)

        XCTAssertEqual(panel.frame.height, panelFrame.height + 44)
        XCTAssertEqual(panel.frame.maxY, panelFrame.maxY)
        XCTAssertEqual(editor.frame, editorFrame)
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
    func testToggleFromHiddenClipboardSearchOpensTheActiveListComposer() async throws {
        let model = AppModel(library: try JSONSnipLibrary(fileURL: storeURL()))
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            isAccessibilityTrusted: { true }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        defer { panel.orderOut(nil) }
        let focusRequested = expectation(description: "Composer focus requested")
        let observation = coordinator.panelFocusRequests.sink { request in
            if case .inlineEntry = request { focusRequested.fulfill() }
        }
        defer { observation.cancel() }

        model.showClipboard()
        model.enterSearch()
        model.query = "draft"
        coordinator.togglePanel()

        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(model.isShowingClipboard)
        XCTAssertFalse(model.isSearchExpanded)
        XCTAssertEqual(model.query, "")
        await fulfillment(of: [focusRequested], timeout: 1)
        withExtendedLifetime(coordinator) {}
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

    @MainActor
    func testClipboardShortcutExitsSearchBeforeTogglingClipboard() async throws {
        let model = AppModel(library: try JSONSnipLibrary(fileURL: storeURL()))
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            isAccessibilityTrusted: { true }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        let focusRequested = expectation(description: "Clipboard focus requested")
        let observation = coordinator.panelFocusRequests.sink { request in
            if case .clipboard = request { focusRequested.fulfill() }
        }
        defer { observation.cancel() }

        model.showClipboard()
        model.query = "search"
        model.enterSearch()
        coordinator.toggleClipboard()

        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(model.isShowingClipboard)
        XCTAssertFalse(model.isSearchExpanded)
        XCTAssertEqual(model.query, "")
        await fulfillment(of: [focusRequested], timeout: 1)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testClipboardShortcutReopensHiddenPanelWithoutLosingAnEdit() async throws {
        let snip = Snip(content: "Editing", origin: .quickEntry)
        let model = AppModel(library: InMemorySnipLibrary(snips: [snip]), defaults: defaults())
        await model.waitForInitialLoad()
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            isAccessibilityTrusted: { true }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        defer { panel.orderOut(nil) }
        let opened = await model.beginEditing(snip.id)
        XCTAssertTrue(opened)

        coordinator.toggleClipboard()

        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(model.editingID, snip.id)
        XCTAssertFalse(model.isShowingClipboard)
    }

    @MainActor
    func testSearchShortcutOpensHiddenPanelAndRequestsSearchFocus() async throws {
        let model = AppModel(library: try JSONSnipLibrary(fileURL: storeURL()))
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            isAccessibilityTrusted: { true }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        defer { panel.orderOut(nil) }
        let focusRequested = expectation(description: "Search focus requested")
        let observation = coordinator.panelFocusRequests.sink { request in
            if case .search = request { focusRequested.fulfill() }
        }
        defer { observation.cancel() }

        coordinator.focusPanelSearch()

        XCTAssertTrue(panel.isVisible)
        await fulfillment(of: [focusRequested], timeout: 1)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testLaterClipboardShortcutSupersedesQueuedSearchFocus() async throws {
        let model = AppModel(library: try JSONSnipLibrary(fileURL: storeURL()))
        let coordinator = AppCoordinator(
            model: model,
            shortcutSettings: ShortcutSettings(),
            isAccessibilityTrusted: { true }
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        defer { panel.orderOut(nil) }
        var requests: [PanelFocusRequest] = []
        let clipboardFocusRequested = expectation(description: "Clipboard focus requested")
        let observation = coordinator.panelFocusRequests.sink { request in
            requests.append(request)
            if case .clipboard = request { clipboardFocusRequested.fulfill() }
        }
        defer { observation.cancel() }

        coordinator.focusPanelSearch()
        coordinator.toggleClipboard()

        await fulfillment(of: [clipboardFocusRequested], timeout: 1)
        withExtendedLifetime(coordinator) {}
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(model.isShowingClipboard)
        XCTAssertFalse(model.isSearchExpanded)
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

@MainActor
private struct MountedAccessibility {
    private let root: NSView
    private let window: AXUIElement

    init(root: NSView) throws {
        self.root = root
        let nativeWindow = try XCTUnwrap(root.window)
        let identifier = "mounted-test-window-\(UUID())"
        nativeWindow.setAccessibilityIdentifier(identifier)
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = Self.attribute(kAXWindowsAttribute, of: application) as? [AXUIElement] ?? []
        window = try XCTUnwrap(windows.first {
            Self.attribute(kAXIdentifierAttribute, of: $0) as? String == identifier
        })
    }

    func button(identifier: String, label: String? = nil) async throws -> AXUIElement {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            root.layoutSubtreeIfNeeded()
            if let button = findButton(identifier: identifier, label: label, in: window) {
                return button
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(
            findButton(identifier: identifier, label: label, in: window),
            "Missing mounted accessibility button \(identifier) with label \(label ?? "<any>")"
        )
    }

    func press(_ button: AXUIElement) -> Bool {
        AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private func findButton(
        identifier: String, label: String?, in element: AXUIElement
    ) -> AXUIElement? {
        if Self.attribute(kAXIdentifierAttribute, of: element) as? String == identifier,
           Self.attribute(kAXRoleAttribute, of: element) as? String == kAXButtonRole,
           label == nil || Self.attribute(kAXDescriptionAttribute, of: element) as? String == label {
            return element
        }
        let children = Self.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
        for child in children {
            if let button = findButton(identifier: identifier, label: label, in: child) {
                return button
            }
        }
        return nil
    }

    // The AX client entry point includes SwiftUI virtual nodes omitted by direct AppKit getters.
    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}

@MainActor
extension MountedAccessibility {
    func value(of element: AXUIElement) -> String? {
        (Self.attribute(kAXValueAttribute, of: element) as? String)
            ?? (Self.attribute(kAXValueDescriptionAttribute, of: element) as? String)
    }
}

// MARK: - Shared menu and expandable-text transitions

@MainActor
private func waitForTransition(
    within timeout: Duration = .seconds(10), until condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
private func mountTransitionPanel<Content: View>(_ content: Content) async throws -> SnipSnapPanel {
    let controller = NSHostingController(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity))
    controller.sizingOptions = []
    let panel = SnipSnapPanel.make(contentViewController: controller, frameAutosaveName: nil)
    panel.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(100))
    return panel
}

@MainActor
private final class GlassMenuTransitionProbe: ObservableObject {
    @Published var isPresented = false
    var dismissesWhenMounted = false
    var reopensWhenClosingStarts = false
    var dismissesWhenSourceLosesFocus = false
    private(set) var interactiveValues: [Bool] = []
    private(set) var mounts = 0
    private(set) var unmounts = 0
    private(set) var sourceFocusCalls: [Bool] = []

    var isMounted: Bool { mounts > unmounts }
    var isInteractive: Bool { isMounted && interactiveValues.last == true }
    var everInteractive: Bool { interactiveValues.contains(true) }
    /// The source regains focus exactly when its presentation finishes.
    var finishCount: Int { sourceFocusCalls.filter { $0 }.count }

    func recordMount() {
        mounts += 1
        if dismissesWhenMounted {
            dismissesWhenMounted = false
            isPresented = false
        }
    }

    func recordUnmount() { unmounts += 1 }

    func recordInteractive(_ interactive: Bool) {
        let wasInteractive = interactiveValues.last == true
        interactiveValues.append(interactive)
        if wasInteractive, !interactive, reopensWhenClosingStarts {
            reopensWhenClosingStarts = false
            isPresented = true
        }
    }

    func recordSourceFocus(_ focused: Bool) {
        sourceFocusCalls.append(focused)
        if !focused, dismissesWhenSourceLosesFocus {
            dismissesWhenSourceLosesFocus = false
            isPresented = false
        }
    }
}

private struct GlassMenuTransitionView: View {
    @ObservedObject var probe: GlassMenuTransitionProbe

    var body: some View {
        VStack {
            Spacer()
            Color.clear
                .frame(width: 44, height: 44)
                .glassMenu(
                    isPresented: $probe.isPresented, label: "Transition probe",
                    identifier: "transition-probe-menu",
                    sizeProbe: AnyView(Color.clear.frame(width: 200, height: 120)),
                    sourceFocus: { probe.recordSourceFocus($0) }
                ) { isInteractive in
                    GlassMenuTransitionContent(isInteractive: isInteractive, probe: probe)
                }
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassMenuHost()
    }
}

private struct GlassMenuTransitionContent: View {
    let isInteractive: Bool
    let probe: GlassMenuTransitionProbe

    var body: some View {
        Color.clear
            .frame(width: 200, height: 120)
            .onAppear { probe.recordMount() }
            .onDisappear { probe.recordUnmount() }
            .onChange(of: isInteractive, initial: true) { _, interactive in
                probe.recordInteractive(interactive)
            }
    }
}

private struct TransitionTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class ExpandableTextTransitionProbe: ObservableObject {
    nonisolated static let identifier = "expandable-transition-probe"
    nonisolated static func longText(_ name: String) -> String {
        (1...12).map { "\(name) line \($0) of a long snip" }.joined(separator: "\n")
    }

    @Published var content = SnipTextContent.literal(ExpandableTextTransitionProbe.longText("First"))
    private(set) var activationTimes: [ContinuousClock.Instant] = []
    private var replacements = 0
    var height: CGFloat = 0
    /// What the hosted text reads for Reduce Motion, once the view appears.
    var reducesMotion: Bool?

    var activations: Int { activationTimes.count }

    func activate() -> Bool {
        activationTimes.append(ContinuousClock.now)
        return true
    }

    func replaceContent() -> ContinuousClock.Instant {
        replacements += 1
        let replacedAt = ContinuousClock.now
        content = .literal(Self.longText(["Second", "Third", "Fourth"][(replacements - 1) % 3]))
        return replacedAt
    }
}

private struct ExpandableTextTransitionView: View {
    @ObservedObject var probe: ExpandableTextTransitionProbe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ExpandableSnipText(
            content: probe.content, lineLimit: 2,
            accessibilityIdentifier: ExpandableTextTransitionProbe.identifier,
            onActivate: { _ in probe.activate() }
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.height = $0 }
        .onChange(of: reduceMotion, initial: true) { _, value in probe.reducesMotion = value }
        .frame(width: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

@MainActor
private struct HostedExpandableText {
    struct Interruption {
        let gap: Duration
        let attempt: Int
    }

    /// `.snappy(duration: 0.18)` cannot finish sooner than this after the write that starts it.
    static let animationFloor: Duration = .milliseconds(180)
    private static let interruptionBudget: Duration = .milliseconds(150)
    private static let attempts = 3

    let probe: ExpandableTextTransitionProbe
    let panel: SnipSnapPanel
    let accessibility: MountedAccessibility
    let collapsedHeight: CGFloat

    static func mount() async throws -> HostedExpandableText {
        let probe = ExpandableTextTransitionProbe()
        // CI runners may have Reduce Motion on, which makes the text toggle without animation.
        let panel = try await mountTransitionPanel(
            ExpandableTextTransitionView(probe: probe).environment(\._accessibilityReduceMotion, false)
        )
        _ = await waitForTransition { probe.reducesMotion != nil }
        guard probe.reducesMotion == false else {
            panel.orderOut(nil)
            throw TransitionTestFailure(description:
                "The hosted text reads Reduce Motion as \(String(describing: probe.reducesMotion)), "
                    + "so it would toggle without animation and nothing could be interrupted."
            )
        }
        let accessibility = try MountedAccessibility(root: try XCTUnwrap(panel.contentView))
        _ = try await accessibility.button(identifier: ExpandableTextTransitionProbe.identifier)
        _ = await waitForTransition { probe.height > 0 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(probe.height, 0)
        return HostedExpandableText(
            probe: probe, panel: panel, accessibility: accessibility, collapsedHeight: probe.height
        )
    }

    /// Returns when the text's `onActivate` ran for this press.
    @discardableResult
    func activate() async throws -> ContinuousClock.Instant {
        let previous = probe.activations
        let button = try await accessibility.button(identifier: ExpandableTextTransitionProbe.identifier)
        XCTAssertTrue(accessibility.press(button), "The expandable text should accept an accessibility press.")
        guard await waitForTransition(within: .seconds(2), until: { probe.activations > previous }) else {
            throw TransitionTestFailure(description: "The accessibility press did not reach the text's onActivate.")
        }
        return probe.activationTimes[previous]
    }

    /// Presses the text, then runs `interrupt` a frame or two later. With Reduce Motion pinned off
    /// in the host, the gap check shows `interrupt` acted before a real 0.18 s animation could
    /// finish. Mac renders opening like open and closing like closed, and its row geometry may
    /// report only end values, so nothing here shows the first transition still pending. Proof
    /// that stale completions are ignored comes from the iOS tests, which run the same
    /// `toggleExpansion`/`settleExpansion` code and act on mid-animation heights; these tests
    /// prove ordering and Mac rendering. A slow runner gets another attempt
    /// after the row settles; when no attempt lands in time, this throws.
    func pressAndInterrupt(
        settled: () async throws -> Bool,
        with interrupt: () async throws -> ContinuousClock.Instant
    ) async throws -> Interruption {
        var gaps: [Duration] = []
        for attempt in 1...Self.attempts {
            let pressedAt = try await activate()
            try await Task.sleep(for: .milliseconds(32))
            let gap = try await interrupt() - pressedAt
            if gap < Self.interruptionBudget { return Interruption(gap: gap, attempt: attempt) }
            gaps.append(gap)
            let didSettle = try await waitUntil(settled)
            XCTAssertTrue(didSettle, "The row should settle before the next interruption attempt.")
            try await Task.sleep(for: .milliseconds(300))
        }
        throw TransitionTestFailure(description:
            "No attempt interrupted within \(Self.interruptionBudget) of the press (gaps: \(gaps)); the runner is too slow."
        )
    }

    func value() async throws -> String? {
        let button = try await accessibility.button(identifier: ExpandableTextTransitionProbe.identifier)
        return accessibility.value(of: button)
    }

    func isCollapsed() async throws -> Bool {
        try await value() == "Collapsed" && abs(probe.height - collapsedHeight) <= 1
    }

    func isExpanded() async throws -> Bool {
        try await value() == "Expanded" && probe.height > collapsedHeight * 2
    }

    func waitUntil(_ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

@MainActor
final class SharedTransitionHostTests: XCTestCase {
    private let settleTime: Duration = .milliseconds(500)

    func testGlassMenuOpensInteractiveThenClosesAndFinishesOnce() async throws {
        let probe = GlassMenuTransitionProbe()
        let panel = try await mountTransitionPanel(GlassMenuTransitionView(probe: probe))
        defer { panel.orderOut(nil) }

        probe.isPresented = true
        let opened = await waitForTransition { probe.isInteractive }
        XCTAssertTrue(opened, "The menu should become interactive once it opens.")
        XCTAssertEqual(probe.finishCount, 0)

        probe.isPresented = false
        let closed = await waitForTransition { !probe.isMounted && probe.finishCount > 0 }
        XCTAssertTrue(closed, "The menu should unmount and finish after it closes.")
        try await Task.sleep(for: settleTime)
        XCTAssertFalse(probe.isMounted)
        XCTAssertEqual(probe.interactiveValues.last, false)
        XCTAssertEqual(probe.finishCount, 1)
    }

    func testGlassMenuClosedWhileOpeningNeverBecomesInteractive() async throws {
        let probe = GlassMenuTransitionProbe()
        let panel = try await mountTransitionPanel(GlassMenuTransitionView(probe: probe))
        defer { panel.orderOut(nil) }

        probe.dismissesWhenMounted = true
        probe.isPresented = true
        let closed = await waitForTransition { probe.mounts > 0 && !probe.isMounted && probe.finishCount > 0 }
        XCTAssertTrue(closed, "A menu closed while opening should unmount and finish.")
        try await Task.sleep(for: settleTime)
        XCTAssertFalse(probe.isPresented)
        XCTAssertFalse(probe.isMounted)
        XCTAssertFalse(probe.everInteractive, "A menu closed while opening must not become interactive.")
        XCTAssertEqual(probe.finishCount, 1)
    }

    func testGlassMenuReopenedWhileClosingEndsOpenWithoutFinishing() async throws {
        let probe = GlassMenuTransitionProbe()
        let panel = try await mountTransitionPanel(GlassMenuTransitionView(probe: probe))
        defer { panel.orderOut(nil) }

        probe.isPresented = true
        let opened = await waitForTransition { probe.isInteractive }
        XCTAssertTrue(opened)

        probe.reopensWhenClosingStarts = true
        probe.isPresented = false
        let reopened = await waitForTransition { !probe.reopensWhenClosingStarts && probe.isInteractive }
        XCTAssertTrue(reopened, "A menu reopened while closing should end open and interactive.")
        try await Task.sleep(for: settleTime)
        XCTAssertTrue(probe.isPresented)
        XCTAssertTrue(probe.isInteractive)
        XCTAssertEqual(probe.finishCount, 0, "The interrupted close must not finish the presentation.")
    }

    func testGlassMenuRapidTogglesEndClosed() async throws {
        let probe = GlassMenuTransitionProbe()
        let panel = try await mountTransitionPanel(GlassMenuTransitionView(probe: probe))
        defer { panel.orderOut(nil) }

        for presented in [true, false, true, false] {
            probe.isPresented = presented
            try await Task.sleep(for: .milliseconds(20))
        }
        let closed = await waitForTransition { !probe.isMounted && probe.finishCount > 0 }
        XCTAssertTrue(closed, "The last request was a close, so the menu should end closed.")
        let finishes = probe.finishCount
        try await Task.sleep(for: settleTime)
        XCTAssertFalse(probe.isPresented)
        XCTAssertFalse(probe.isMounted)
        XCTAssertFalse(probe.isInteractive)
        XCTAssertEqual(probe.finishCount, finishes, "Stale completions must not finish again.")
    }

    func testGlassMenuDismissedAsItStartsPresentingStillFinishes() async throws {
        let probe = GlassMenuTransitionProbe()
        let panel = try await mountTransitionPanel(GlassMenuTransitionView(probe: probe))
        defer { panel.orderOut(nil) }

        // The source hands focus away in the same update that claims the host.
        // Dismissing there lands before the surface ever sees the presentation.
        probe.dismissesWhenSourceLosesFocus = true
        probe.isPresented = true
        let finished = await waitForTransition(within: .seconds(5)) { probe.finishCount > 0 }
        XCTAssertTrue(finished, "A dismissed presentation must release the host and return source focus.")
        try await Task.sleep(for: settleTime)
        XCTAssertFalse(probe.isPresented)
        XCTAssertFalse(probe.isMounted)
        XCTAssertFalse(probe.everInteractive)
        XCTAssertEqual(probe.finishCount, 1)
    }

    func testExpandableTextCollapsedDuringExpansionSettlesCollapsed() async throws {
        let text = try await HostedExpandableText.mount()
        defer { text.panel.orderOut(nil) }
        let startsCollapsed = try await text.isCollapsed()
        XCTAssertTrue(startsCollapsed)

        let interruption = try await text.pressAndInterrupt(settled: { try await text.isCollapsed() }) {
            try await text.activate()
        }
        XCTAssertLessThan(interruption.gap, HostedExpandableText.animationFloor, "The collapse must land mid-expansion.")

        let collapsed = try await text.waitUntil { try await text.isCollapsed() }
        XCTAssertTrue(collapsed, "Collapsing mid-expansion should settle collapsed.")
        try await Task.sleep(for: settleTime)
        let staysCollapsed = try await text.isCollapsed()
        XCTAssertTrue(staysCollapsed)
        XCTAssertEqual(text.probe.activations, 2 * interruption.attempt)
    }

    func testExpandableTextExpandedDuringCollapseSettlesExpanded() async throws {
        let text = try await HostedExpandableText.mount()
        defer { text.panel.orderOut(nil) }
        try await text.activate()
        let expanded = try await text.waitUntil { try await text.isExpanded() }
        XCTAssertTrue(expanded)
        try await Task.sleep(for: settleTime)
        let expandedHeight = text.probe.height
        let isAtExpandedHeight: () async throws -> Bool = {
            try await text.isExpanded() && abs(text.probe.height - expandedHeight) <= 1
        }

        let interruption = try await text.pressAndInterrupt(settled: isAtExpandedHeight) {
            try await text.activate()
        }
        XCTAssertLessThan(interruption.gap, HostedExpandableText.animationFloor, "The expansion must land mid-collapse.")

        let reexpanded = try await text.waitUntil(isAtExpandedHeight)
        XCTAssertTrue(reexpanded, "Expanding mid-collapse should settle at the full height.")
        try await Task.sleep(for: settleTime)
        let staysExpanded = try await text.isExpanded()
        XCTAssertTrue(staysExpanded)
        XCTAssertEqual(text.probe.height, expandedHeight, accuracy: 1)
        XCTAssertEqual(text.probe.activations, 1 + 2 * interruption.attempt)
    }

    func testExpandableTextContentChangeDuringExpansionResetsCollapsed() async throws {
        let text = try await HostedExpandableText.mount()
        defer { text.panel.orderOut(nil) }

        let interruption = try await text.pressAndInterrupt(settled: { try await text.isCollapsed() }) {
            text.probe.replaceContent()
        }
        XCTAssertLessThan(interruption.gap, HostedExpandableText.animationFloor, "The new content must land mid-expansion.")

        let collapsed = try await text.waitUntil { try await text.isCollapsed() }
        XCTAssertTrue(collapsed, "New content should reset the text to collapsed.")
        try await Task.sleep(for: settleTime)
        let staysCollapsed = try await text.isCollapsed()
        XCTAssertTrue(staysCollapsed)
        XCTAssertEqual(text.probe.activations, interruption.attempt)
    }
}


extension AppCoordinatorTests {
    @MainActor
    func testMountedComposerSendFinishesWhileEarlierScheduledBackgroundWorkIsHeld() async throws {
        let fixture = try MountedComposerFeedbackFixture.make()
        do {
            try await exerciseMountedOfflineComposer(fixture)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    @MainActor
    private func exerciseMountedOfflineComposer(_ fixture: MountedComposerFeedbackFixture) async throws {
        let model = fixture.model
        let loading = fixture.start { await model.waitForInitialLoad(); return true }
        guard await fixture.ready(loading.finished, "mounted composer initial load") else { return }
        model.saveComposerText("Mounted Send before background release", for: SnipList.inboxID)
        model.flushComposerDrafts()
        await fixture.handler.scheduleSyncAfterLocalChange()
        guard await fixture.ready(fixture.handler.pause.entered, "mounted composer earlier worker") else { return }
        let settings = ShortcutSettings(defaults: fixture.defaults)
        let coordinator = AppCoordinator(model: model, shortcutSettings: settings, isAccessibilityTrusted: { true })
        let content = ContentView(coordinator: coordinator, fileDropController: PanelFileDropController(),
                                  dragSessionController: PanelDragSessionController())
            .environmentObject(model).environmentObject(settings)
        let panel = SnipSnapPanel.make(contentViewController: NSHostingController(rootView: content),
                                       frameAutosaveName: nil)
        fixture.panel = panel
        coordinator.attachPanelWindow(panel)
        let frames = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        fixture.frameContinuation = frames.continuation
        let displayed = MountedComposerFeedbackSignal()
        fixture.frameObservation = NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification, object: panel)
            .sink { _ in displayed.fire(); frames.continuation.yield(()) }
        panel.makeKeyAndOrderFront(nil)
        guard await fixture.ready(displayed, "actual mounted ContentView window update") else { return }
        let accessibility = try MountedAccessibility(root: try XCTUnwrap(panel.contentView))
        let send = try await accessibility.button(identifier: "composer-send", label: String(localized: "Send Snip"))
        XCTAssertEqual(mountedComposerSendEnabled(send), true)
        // Observe real render events. The existing AX lookup keeps its original two-second/20ms contract.
        let completion = fixture.start {
            for await _ in frames.stream {
                guard !Task.isCancelled else { return false }
                guard model.composerDraft(for: SnipList.inboxID) == ComposerDraft(),
                      model.snips.contains(where: { $0.content == "Mounted Send before background release" }) else { continue }
                do {
                    let current = try await accessibility.button(identifier: "composer-send", label: String(localized: "Send Snip"))
                    if self.mountedComposerSendEnabled(current) == false { return true }
                } catch { XCTFail("Mounted composer completion control missing: \(error)"); return false }
            }
            return false
        }
        XCTAssertTrue(accessibility.press(send), "Invoke the real composer-send control")
        let completed = await completion.finished.wait(for: .seconds(2))
        XCTAssertTrue(fixture.handler.pause.isHeld)
        XCTAssertTrue(completed, "Mounted Send must finalize and render disabled before background release")
        guard completed else { return }
        XCTAssertEqual(completion.result, true)
        let submitted = await fixture.handler.localSubmission.wait(for: .seconds(2))
        XCTAssertTrue(submitted, "The mounted Send must actually submit normal scheduling")
        let reader = try SwiftDataSnipLibrary(storeURL: fixture.storeURL)
        let durable = try await reader.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(durable.snips.map(\.content), ["Mounted Send before background release"])
        XCTAssertEqual(durable.snips.map(\.isDone), [false])
        XCTAssertEqual(model.snips.map(\.content), ["Mounted Send before background release"])
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID), ComposerDraft())
        let disabled = try await accessibility.button(identifier: "composer-send", label: String(localized: "Send Snip"))
        XCTAssertEqual(mountedComposerSendEnabled(disabled), false)
        // A fresh draft must re-enable the real control; an empty disabled control alone cannot rule out stuck saving.
        let nextDraftReady = fixture.start {
            for await _ in frames.stream {
                guard !Task.isCancelled else { return false }
                guard model.composerDraft(for: SnipList.inboxID).text == "Next mounted draft remains unsent" else { continue }
                do {
                    let current = try await accessibility.button(identifier: "composer-send", label: String(localized: "Send Snip"))
                    if self.mountedComposerSendEnabled(current) == true { return true }
                } catch { XCTFail("Mounted next-draft control missing: \(error)"); return false }
            }
            return false
        }
        model.saveComposerText("Next mounted draft remains unsent", for: SnipList.inboxID)
        model.flushComposerDrafts()
        let reload = fixture.start { await model.reload(); return true }
        let reloaded = await reload.finished.wait(for: .seconds(2))
        XCTAssertTrue(reloaded, "The local reload that publishes the next draft must not wait for background work")
        let readyForAnotherSend = await nextDraftReady.finished.wait(for: .seconds(2))
        XCTAssertTrue(readyForAnotherSend, "The actual composer must accept another Send before background release")
        XCTAssertEqual(nextDraftReady.result, true)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "Next mounted draft remains unsent")
        XCTAssertNil(model.presentedError)
        let counts = await fixture.handler.counts()
        XCTAssertEqual(counts.schedule, 2)
        XCTAssertEqual(counts.explicit, 0)
        XCTAssertEqual(counts.status, 0)
        XCTAssertTrue(fixture.handler.pause.isHeld, "All rendered/model/durable assertions must precede release")
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    private func mountedComposerSendEnabled(_ element: AXUIElement) -> Bool? {
        var enabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success else { return nil }
        return enabled as? Bool
    }
}

@MainActor
private final class MountedComposerFeedbackFixture {
    let root: URL
    let storeURL: URL
    let suite: String
    let defaults: UserDefaults
    let pasteboard: NSPasteboard
    let handler: MountedComposerFeedbackScheduler
    let model: AppModel
    var panel: SnipSnapPanel?
    var frameObservation: AnyCancellable?
    var frameContinuation: AsyncStream<Void>.Continuation?
    private var work: [MountedComposerFeedbackWork] = []
    private init(root: URL, library: SwiftDataSnipLibrary, defaults: UserDefaults, suite: String) {
        self.root = root
        storeURL = root.appendingPathComponent("snips.store")
        self.defaults = defaults
        self.suite = suite
        pasteboard = NSPasteboard(name: .init("MountedComposerFeedback.\(UUID())"))
        handler = MountedComposerFeedbackScheduler()
        model = AppModel(library: library, defaults: defaults,
            clipboardHistory: ClipboardHistory(pasteboard: pasteboard, defaults: defaults,
                storeURL: root.appendingPathComponent("clipboard.json")), cloudSyncHandler: handler)
    }
    static func make() throws -> MountedComposerFeedbackFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MountedComposerFeedback-\(UUID())")
        let suite = "MountedComposerFeedback.\(UUID())"
        do {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: "clipboardHistoryPaused")
            let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("snips.store"))
            return MountedComposerFeedbackFixture(root: root, library: library, defaults: defaults, suite: suite)
        } catch {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            NSLog("MountedComposerFeedback retained failed setup store root: %@", root.path)
            throw error
        }
    }
    func start(_ operation: @escaping @MainActor () async -> Bool) -> MountedComposerFeedbackWork {
        let operation = MountedComposerFeedbackWork(operation)
        work.append(operation)
        return operation
    }
    func ready(_ signal: MountedComposerFeedbackSignal, _ stage: String) async -> Bool {
        let ready = await signal.wait(for: .seconds(30))
        XCTAssertTrue(ready, "Mounted composer setup/readiness failed: \(stage)")
        return ready
    }
    func cleanUp() async {
        let cleanup = Task { @MainActor in
            handler.pause.release()
            frameContinuation?.finish()
            frameObservation?.cancel()
            work.forEach { $0.task?.cancel() }
            let deadline = ContinuousClock.now + .seconds(30)
            var settled = true
            for operation in work {
                let joined = await operation.finished.wait(for: deadline - ContinuousClock.now)
                XCTAssertTrue(joined, "Mounted composer cleanup could not join an owned observer/caller")
                if joined { await operation.task?.value } else { settled = false }
            }
            let draining = MountedComposerFeedbackWork { await self.model.reload(); return true }
            work.append(draining)
            let drained = await draining.finished.wait(for: deadline - ContinuousClock.now)
            XCTAssertTrue(drained, "Mounted composer cleanup could not drain the model command")
            if drained { await draining.task?.value } else { draining.task?.cancel() }
            let joined = await handler.finish(until: deadline)
            XCTAssertTrue(joined, "Mounted composer cleanup left the scheduled worker active")
            guard settled && drained && joined else {
                NSLog("MountedComposerFeedback retained live ownership and store root: %@", root.path)
                return
            }
            panel?.orderOut(nil)
            panel?.contentViewController = nil
            panel = nil
            work.removeAll()
            frameObservation = nil
            frameContinuation = nil
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            NSLog("MountedComposerFeedback retained store root: %@", root.path)
        }
        await cleanup.value
    }
}


private final class MountedComposerFeedbackSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var isSet: Bool { lock.withLock { fired } }
    func fire() {
        let pending = lock.withLock {
            fired = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume(returning: true) }
    }
    func wait(for timeout: Duration) async -> Bool {
        if isSet { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let id = UUID()
                return await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        let immediate: Bool? = self.lock.withLock {
                            if self.fired { return true }
                            if Task.isCancelled { return false }
                            self.waiters[id] = continuation
                            return nil
                        }
                        if let immediate { continuation.resume(returning: immediate) }
                    }
                } onCancel: {
                    self.lock.withLock { self.waiters.removeValue(forKey: id) }?.resume(returning: false)
                }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch {}
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

private final class MountedComposerFeedbackPause: @unchecked Sendable {
    let entered = MountedComposerFeedbackSignal()
    private let lock = NSLock()
    private var released = false
    private var pending: CheckedContinuation<Void, Never>?
    var isHeld: Bool { entered.isSet && lock.withLock { !released } }
    func suspend() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if released { return true }
                pending = continuation
                return false
            }
            entered.fire()
            if resume { continuation.resume() }
        }
    }
    func release() {
        let continuation = lock.withLock {
            released = true
            let continuation = pending
            pending = nil
            return continuation
        }
        continuation?.resume()
    }
}

private actor MountedComposerFeedbackScheduler: OptionalCloudSyncHandling {
    nonisolated let pause = MountedComposerFeedbackPause()
    nonisolated let localSubmission = MountedComposerFeedbackSignal()
    nonisolated let finished = MountedComposerFeedbackSignal()
    private var worker: Task<Void, Never>?
    private var scheduled = 0
    private var explicit = 0
    private var status = 0
    func scheduleSyncAfterLocalChange() {
        scheduled += 1
        if worker == nil {
            worker = Task { [pause, finished] in
                await pause.suspend()
                finished.fire()
            }
        }
        if scheduled >= 2 { localSubmission.fire() }
    }
    func counts() -> (schedule: Int, explicit: Int, status: Int) { (scheduled, explicit, status) }
    func finish(until deadline: ContinuousClock.Instant) async -> Bool {
        guard let worker else { return true }
        worker.cancel()
        guard await finished.wait(for: deadline - ContinuousClock.now) else { return false }
        await worker.value
        return true
    }
    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
    func syncWhenPossible() async { explicit += 1 }
    func isCloudSyncActive() async throws -> Bool { status += 1; return true }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] { status += 1; return [:] }
    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        throw SnipLibraryError.transferUnsupported
    }
    func clearDownloadedFiles() async throws {}
}

@MainActor
private final class MountedComposerFeedbackWork {
    let finished = MountedComposerFeedbackSignal()
    var result: Bool?
    var task: Task<Void, Never>?
    init(_ operation: @escaping @MainActor () async -> Bool) {
        task = Task { [self] in
            result = await operation()
            finished.fire()
        }
    }
}
