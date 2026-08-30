import XCTest

@MainActor
final class SnipSnapiOSUITests: XCTestCase {
    private func launchApp(
        storeName: String = "ui-\(UUID().uuidString)",
        withAttachments: Bool = false,
        withRecovery: Bool = false,
        withSyncedContent: Bool = false,
        withSyncEnable: Bool = false,
        withLimitAttachments: Bool = false,
        withEncryptedReset: Bool = false,
        accountNotice: Bool = false,
        withCopyShareFixtures: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SNIP_SNAP_UI_TESTING"] = "1"
        app.launchEnvironment["SNIP_SNAP_UI_TEST_STORE"] = storeName
        if withAttachments { app.launchEnvironment["SNIP_SNAP_UI_TEST_ATTACHMENTS"] = "1" }
        if withRecovery { app.launchEnvironment["SNIP_SNAP_UI_TEST_RECOVERY"] = "1" }
        if withSyncedContent {
            app.launchEnvironment["SNIP_SNAP_UI_TEST_SYNC_SETTINGS"] = "1"
        }
        if withSyncEnable { app.launchEnvironment["SNIP_SNAP_UI_TEST_SYNC_ENABLE"] = "1" }
        if withLimitAttachments {
            app.launchEnvironment["SNIP_SNAP_UI_TEST_LIMIT_ATTACHMENTS"] = "1"
        }
        if withEncryptedReset {
            app.launchEnvironment["SNIP_SNAP_UI_TEST_ENCRYPTED_RESET"] = "1"
        }
        if accountNotice {
            app.launchEnvironment["SNIP_SNAP_UI_TEST_ACCOUNT_NOTICE"] = "signedOut"
        }
        if withCopyShareFixtures {
            app.launchEnvironment["SNIP_SNAP_UI_TEST_COPY_SHARE"] = "1"
        }
        app.launch()
        return app
    }

    func testExplicitEnableKeepsLocalContentAndTurnsSyncOn() {
        continueAfterFailure = false
        let app = launchApp(withSyncEnable: true)
        app.buttons["new-snip"].tap()
        let editor = app.textViews["snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("Keep while enabling sync")
        app.buttons["save-snip"].tap()
        let localSnip = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Keep while enabling sync")
        ).firstMatch
        XCTAssertTrue(localSnip.waitForExistence(timeout: 3))
        let settings = app.buttons["settings"]
        for _ in 0..<3 where !settings.waitForExistence(timeout: 1) {
            if app.buttons["Show Sidebar"].exists {
                app.buttons["Show Sidebar"].tap()
            } else if app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        XCTAssertTrue(app.staticTexts["Local Only"].waitForExistence(timeout: 3))
        app.buttons["enable-icloud-sync"].tap()
        XCTAssertTrue(app.staticTexts["iCloud Sync On"].waitForExistence(timeout: 8))
        app.buttons["Done"].tap()
        if app.buttons["list-Inbox"].waitForExistence(timeout: 2) {
            app.buttons["list-Inbox"].tap()
        }
        XCTAssertTrue(localSnip.waitForExistence(timeout: 3))
    }

    func testSyncEnableReportsEveryAttachmentAboveTheSnipSnapLimit() {
        continueAfterFailure = false
        let app = launchApp(withSyncEnable: true, withLimitAttachments: true)
        XCTAssertTrue(app.staticTexts["Attachment fixture"].waitForExistence(timeout: 8))
        let settings = app.buttons["settings"]
        for _ in 0..<3 where !settings.waitForExistence(timeout: 1) {
            if app.buttons["Show Sidebar"].exists {
                app.buttons["Show Sidebar"].tap()
            } else if app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        app.buttons["enable-icloud-sync"].tap()

        XCTAssertTrue(app.staticTexts["Sync Needs Attention"].waitForExistence(timeout: 8))
        let firstDetail = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "over-limit-a.bin")
        ).firstMatch
        let secondDetail = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "over-limit-b.bin")
        ).firstMatch
        XCTAssertTrue(firstDetail.waitForExistence(timeout: 3))
        XCTAssertTrue(secondDetail.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["enable-icloud-sync"].exists)
        XCTAssertFalse(app.staticTexts["iCloud Sync On"].exists)
    }

    func testDeleteSyncedContentExplainsAndConfirmsReset() {
        continueAfterFailure = false
        let app = launchApp(withSyncedContent: true)
        app.buttons["new-snip"].tap()
        let editor = app.textViews["snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("Visible before cloud reset")
        app.buttons["save-snip"].tap()
        let priorSnip = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Visible before cloud reset")
        ).firstMatch
        XCTAssertTrue(priorSnip.waitForExistence(timeout: 3))
        let settings = app.buttons["settings"]
        for _ in 0..<3 where !settings.waitForExistence(timeout: 1) {
            let showSidebar = app.buttons["Show Sidebar"]
            if showSidebar.exists {
                showSidebar.tap()
            } else if app.buttons["BackButton"].exists {
                app.buttons["BackButton"].tap()
            } else if app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        XCTAssertTrue(app.staticTexts["iCloud Sync On"].waitForExistence(timeout: 3))
        app.buttons["delete-synced-content"].tap()
        XCTAssertTrue(app.alerts["Delete Synced Content?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Delete Synced Content"].tap()

        XCTAssertTrue(app.staticTexts["Synced Content Deleted"].waitForExistence(timeout: 3))
        let controlRecordNote = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "control record remains")
        ).firstMatch
        XCTAssertTrue(controlRecordNote.exists)
        XCTAssertFalse(app.buttons["delete-synced-content"].exists)
        app.buttons["Done"].tap()
        XCTAssertFalse(priorSnip.waitForExistence(timeout: 3))
    }

    func testEncryptedDataResetOffersAllThreeSafeChoices() {
        continueAfterFailure = false
        let app = launchApp(withSyncedContent: true, withEncryptedReset: true)
        let settings = app.buttons["settings"]
        for _ in 0..<3 where !settings.waitForExistence(timeout: 1) {
            if app.buttons["Show Sidebar"].exists {
                app.buttons["Show Sidebar"].tap()
            } else if app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        XCTAssertTrue(app.staticTexts["iCloud Encrypted Data Was Reset"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["encrypted-reset-restore"].exists)
        XCTAssertTrue(app.buttons["encrypted-reset-start-empty"].exists)
        XCTAssertTrue(app.buttons["encrypted-reset-keep-off"].exists)

        app.buttons["encrypted-reset-start-empty"].tap()
        XCTAssertTrue(app.staticTexts["iCloud Sync On"].waitForExistence(timeout: 5))
    }

    func testReviewsRecoveredSnipAndListEdits() {
        continueAfterFailure = false
        let app = launchApp(withRecovery: true)
        let attention = app.buttons["needs-attention"]
        if !attention.waitForExistence(timeout: 1) {
            let showSidebar = app.buttons["Show Sidebar"]
            if showSidebar.exists {
                showSidebar.tap()
            } else if app.buttons["BackButton"].exists {
                app.buttons["BackButton"].tap()
            } else {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
        XCTAssertTrue(attention.waitForExistence(timeout: 5))
        attention.tap()

        let recoveredSnip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Recovered text from this device")
        ).firstMatch
        XCTAssertTrue(recoveredSnip.waitForExistence(timeout: 3))
        recoveredSnip.tap()
        XCTAssertTrue(app.navigationBars["Recovered Snip"].waitForExistence(timeout: 3))
        app.buttons["Use Recovered"].tap()

        XCTAssertTrue(app.navigationBars["Needs Attention"].waitForExistence(timeout: 3))
        let recoveredList = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Recovered Notes")
        ).firstMatch
        XCTAssertTrue(recoveredList.waitForExistence(timeout: 3))
        recoveredList.tap()
        XCTAssertTrue(app.navigationBars["Recovered List Edit"].waitForExistence(timeout: 3))
        app.buttons["Use Recovered"].tap()
        XCTAssertTrue(app.navigationBars["Needs Attention"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertFalse(attention.waitForExistence(timeout: 2))
    }

    func testSignedOutNoticeOffersBothSafeChoicesWithoutAnAlert() {
        continueAfterFailure = false
        let app = launchApp(accountNotice: true)

        let notice = app.staticTexts["apple-account-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["keep-account-cache"].exists)
        XCTAssertTrue(app.buttons["remove-account-cache"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)

        app.buttons["keep-account-cache"].tap()
        XCTAssertFalse(notice.waitForExistence(timeout: 1))
    }

    func testCopiesTextOnlySnip() {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        openCopyShareFixture(matching: "Copy text fixture", in: app)
        chooseDetailAction("copy-snip", in: app)

        XCTAssertEqual(copyStatus(in: app).label, "Copied")
    }

    func testCopiesFileOnlySnipAttachments() {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        openCopyShareFixture(matching: "notes.txt", in: app)
        chooseDetailAction("copy-attachments-snip", in: app)

        XCTAssertEqual(copyStatus(in: app).label, "Copied Attachments")
    }

    func testCopiesMixedSnipText() {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        openCopyShareFixture(matching: "Copy mixed fixture", in: app)
        chooseDetailAction("copy-text-snip", in: app)

        XCTAssertEqual(copyStatus(in: app).label, "Copied Text")
    }

    func testSharesMultipleSelectedSnips() {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)
        returnToCollection(in: app)
        XCTAssertTrue(
            collectionRow(named: "Copy text fixture", in: app).waitForExistence(timeout: 5)
        )
        enterSelection(in: app)
        row(named: "Copy text fixture", in: app).tap()
        row(named: "Copy mixed fixture", in: app).tap()
        app.buttons["selection-actions"].tap()
        let share = app.buttons["share-selection"]
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        share.tap()

        XCTAssertTrue(activityView(in: app).waitForExistence(timeout: 5))
    }

    func testShareExtensionImportsExactlyOnceWhileMainAppIsOpen() {
        assertShareExtensionImportsExactlyOnce(mainAppState: .open)
    }

    func testShareExtensionImportsExactlyOnceWhileMainAppIsClosed() {
        assertShareExtensionImportsExactlyOnce(mainAppState: .closed)
    }

    func testShareExtensionDefersExactlyOnceWhileMainStoreIsUnavailable() {
        assertShareExtensionImportsExactlyOnce(mainAppState: .unavailable)
    }

    func testUnavailableAttachmentOffersOnlyCopyTextOrCancel() {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        openCopyShareFixture(matching: "Copy unavailable fixture", in: app)
        chooseDetailAction("copy-snip", in: app)
        XCTAssertTrue(app.alerts["Some Files Are Unavailable"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Copy Text Only"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        app.buttons["Copy Text Only"].tap()
        XCTAssertEqual(copyStatus(in: app).label, "Copied Text")
    }

    func testCreatesAndEditsTextSnip() {
        continueAfterFailure = false
        let app = launchApp()
        app.buttons["new-snip"].tap()
        let editor = app.textViews["snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("A useful thought")
        app.buttons["save-snip"].tap()

        let savedText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "A useful thought")
        ).firstMatch
        XCTAssertTrue(savedText.waitForExistence(timeout: 3))

        let snipRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "A useful thought")
        ).firstMatch
        if snipRow.waitForExistence(timeout: 1) {
            snipRow.tap()
        } else {
            XCTAssertTrue(app.navigationBars["Snip"].waitForExistence(timeout: 3))
        }
        app.buttons["edit-snip"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText(" updated")
        app.buttons["save-snip"].tap()

        let updatedText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "updated")
        ).firstMatch
        XCTAssertTrue(updatedText.waitForExistence(timeout: 3))
    }

    func testLibraryActionsExposeUndoRedoAndBackupImport() {
        continueAfterFailure = false
        let app = launchApp()
        var actions = app.buttons["library-actions"]
        if !actions.waitForExistence(timeout: 1) {
            let showSidebar = app.buttons["Show Sidebar"]
            if showSidebar.exists {
                showSidebar.tap()
            } else if app.buttons["BackButton"].exists {
                app.buttons["BackButton"].tap()
            } else {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }

        if !actions.waitForExistence(timeout: 1) {
            let more = app.buttons["More"]
            XCTAssertTrue(more.waitForExistence(timeout: 3))
            more.tap()
            actions = app.buttons["Library Actions"]
        }

        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Redo"].exists)
        XCTAssertTrue(app.buttons["Import Backup…"].exists)
    }

    func testCreatesListMovesSnipAndDeletesIt() {
        continueAfterFailure = false
        let app = launchApp()
        let newList = app.buttons["new-list"]
        if !newList.waitForExistence(timeout: 1) {
            let showSidebar = app.buttons["Show Sidebar"]
            if showSidebar.exists {
                showSidebar.tap()
            } else {
                app.buttons["BackButton"].tap()
            }
        }
        XCTAssertTrue(newList.waitForExistence(timeout: 3))
        newList.tap()
        let name = app.textFields["list-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Work")
        app.buttons["save-list"].tap()

        let workList = app.buttons["list-Work"]
        if workList.waitForExistence(timeout: 1) {
            workList.tap()
        } else {
            XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        }
        let newSnip = app.buttons["new-snip"]
        if !newSnip.isHittable {
            let hideSidebar = app.navigationBars["Lists"].buttons["Hide Sidebar"].firstMatch
            XCTAssertTrue(hideSidebar.waitForExistence(timeout: 3))
            hideSidebar.tap()
        }
        XCTAssertTrue(newSnip.waitForExistence(timeout: 3))
        newSnip.tap()
        let editor = app.textViews["snip-text"]
        editor.tap()
        editor.typeText("Move this")
        app.buttons["save-snip"].tap()

        let moveRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Move this")
        ).firstMatch
        if moveRow.waitForExistence(timeout: 1) {
            moveRow.tap()
        } else {
            XCTAssertTrue(app.navigationBars["Snip"].waitForExistence(timeout: 3))
        }
        app.buttons["move-snip"].tap()
        app.buttons["move-to-Inbox"].tap()
        let inboxValue = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Inbox")
        ).firstMatch
        XCTAssertTrue(inboxValue.waitForExistence(timeout: 3))
        app.buttons["delete-snip-detail"].tap()
        let emptyDetail = app.staticTexts["Choose a Snip"]
        if !emptyDetail.waitForExistence(timeout: 1) {
            XCTAssertTrue(app.staticTexts["No Snips"].waitForExistence(timeout: 3))
        }
    }

    func testLocalAttachmentsPreviewRemoveAndSurviveRelaunch() {
        continueAfterFailure = false
        let storeName = "attachments-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName, withAttachments: true)

        openAttachmentFixture(in: app)
        let imagePreview = app.buttons["attachment-preview-sample.png"]
        XCTAssertTrue(imagePreview.waitForExistence(timeout: 5))
        let textPreview = app.buttons["attachment-preview-notes.txt"]
        XCTAssertTrue(textPreview.waitForExistence(timeout: 3))
        imagePreview.tap()
        let preview = app.otherElements["QLPreviewControllerView"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        dismissQuickLook(preview, in: app)
        XCTAssertFalse(preview.waitForExistence(timeout: 3))

        app.buttons["edit-snip"].tap()
        let imageRow = app.buttons["attachment-row-sample.png"]
        XCTAssertTrue(imageRow.waitForExistence(timeout: 3))
        let removeAttachment = app.buttons["remove-attachment-sample.png"]
        XCTAssertTrue(removeAttachment.waitForExistence(timeout: 3))
        removeAttachment.tap()
        app.buttons["save-snip"].tap()
        XCTAssertTrue(textPreview.waitForExistence(timeout: 3))

        app.terminate()
        app = launchApp(storeName: storeName, withAttachments: true)
        openAttachmentFixture(in: app)
        XCTAssertTrue(app.buttons["attachment-preview-notes.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["attachment-preview-sample.png"].exists)
    }

    func testNativePickerAddReplacePreviewAndSaveWhenFixturesAreSeeded() throws {
        guard ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_PICKER_FIXTURES"] == "1"
        else {
            throw XCTSkip("Seed attachment-one.txt and attachment-two.txt in local Files to run.")
        }
        continueAfterFailure = false
        let app = launchApp(storeName: "picker-manual-\(UUID().uuidString)")
        app.buttons["new-snip"].tap()
        let editor = app.textViews["snip-text"]
        editor.tap()
        editor.typeText("Picker flow")

        app.buttons["add-attachments"].tap()
        pickFile(named: "attachment-one.txt", in: app, confirmsSelection: true)
        let added = app.buttons["attachment-row-attachment-one.txt"]
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        added.tap()
        let preview = app.otherElements["QLPreviewControllerView"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        dismissQuickLook(preview, in: app)
        XCTAssertFalse(preview.waitForExistence(timeout: 3))

        app.buttons["replace-attachment-attachment-one.txt"].tap()
        pickFile(named: "attachment-two.txt", in: app, confirmsSelection: false)
        XCTAssertTrue(
            app.buttons["attachment-row-attachment-two.txt"].waitForExistence(timeout: 5)
        )
        app.buttons["save-snip"].tap()
        XCTAssertTrue(
            app.buttons["attachment-preview-attachment-two.txt"].waitForExistence(timeout: 5)
        )
    }

    private func pickFile(named fileName: String, in app: XCUIApplication, confirmsSelection: Bool) {
        let url = URL(fileURLWithPath: fileName)
        let fileLabel = "\(url.deletingPathExtension().lastPathComponent), \(url.pathExtension)"
        var file = app.cells.matching(
            NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", fileName, fileLabel)
        ).firstMatch
        if !file.waitForExistence(timeout: 1) {
            let tabletLocalStorage = app.cells["DOC.sidebar.item.On My iPad"]
            if tabletLocalStorage.exists {
                tabletLocalStorage.tap()
            } else if !app.staticTexts["On My iPhone"].exists {
                app.tabBars.buttons["Browse"].firstMatch.tap()
            }
            file = app.cells.matching(
                NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", fileName, fileLabel)
            ).firstMatch
        }
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        if confirmsSelection {
            let open = app.buttons["Open"]
            XCTAssertTrue(open.waitForExistence(timeout: 3))
            open.tap()
        }
    }

    private func dismissQuickLook(_ preview: XCUIElement, in app: XCUIApplication) {
        let candidates = [
            app.buttons["Done"],
            app.buttons["Close"],
            app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"],
        ]
        if let visibleButton = candidates.first(where: { $0.waitForExistence(timeout: 1) }) {
            visibleButton.tap()
            return
        }

        preview.tap()
        if let visibleButton = candidates.first(where: { $0.waitForExistence(timeout: 2) }) {
            visibleButton.tap()
            return
        }

        preview.swipeDown()
        XCTAssertFalse(preview.waitForExistence(timeout: 2))
    }

    private func openAttachmentFixture(in app: XCUIApplication) {
        let fixtureRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Attachment fixture")
        ).firstMatch
        if fixtureRow.waitForExistence(timeout: 5) {
            fixtureRow.tap()
        } else {
            XCTAssertTrue(app.navigationBars["Snip"].waitForExistence(timeout: 3))
        }
    }

    private func openCopyShareFixture(matching text: String, in app: XCUIApplication) {
        if app.navigationBars["Snip"].exists, app.buttons["BackButton"].exists {
            app.buttons["BackButton"].tap()
        }
        let fixture = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", text)
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5))
        fixture.tap()
        XCTAssertTrue(app.buttons["copy-share-snip"].waitForExistence(timeout: 5))
    }

    private func chooseDetailAction(_ identifier: String, in app: XCUIApplication) {
        app.buttons["copy-share-snip"].tap()
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        action.tap()
    }

    private func copyStatus(in app: XCUIApplication) -> XCUIElement {
        let status = app.staticTexts["copy-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        return status
    }

    private func activityView(in app: XCUIApplication) -> XCUIElement {
        app.otherElements["ActivityListView"]
    }

    private enum ShareProcessMainAppState: Equatable {
        case open
        case closed
        case unavailable
    }

    private func assertShareExtensionImportsExactlyOnce(
        mainAppState: ShareProcessMainAppState
    ) {
        continueAfterFailure = false
        let token = "snipsnap-share-process-\(UUID().uuidString)"
        var app = launchShareProcessApp(
            token: token,
            storeUnavailable: mainAppState == .unavailable
        )
        XCTAssertTrue(app.staticTexts["share-process-count"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["share-process-count"].label, "0")
        if mainAppState == .closed {
            app.terminate()
        }

        let safari = shareURLFromSafari(token: token)
        let shareText = safari.textViews["share-text"]
        XCTAssertTrue(shareText.waitForExistence(timeout: 8))
        let loadedText = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", token),
            object: shareText
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loadedText], timeout: 8), .completed)
        assertShareExtensionReportedLocalSave(in: safari)

        if mainAppState == .unavailable {
            app.terminate()
            app = launchShareProcessApp(token: token, repairStore: true)
        } else {
            app.activate()
        }
        assertShareProcessCount(1, in: app)

        safari.activate()
        app.activate()
        assertShareProcessCount(1, in: app)
    }

    private func launchShareProcessApp(
        token: String,
        storeUnavailable: Bool = false,
        repairStore: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SNIP_SNAP_UI_TEST_SHARE_EXTENSION_PROCESS"] = "1"
        app.launchEnvironment["SNIP_SNAP_UI_TEST_SHARE_TOKEN"] = token
        if storeUnavailable {
            app.launchEnvironment["SNIP_SNAP_UI_TEST_SHARE_STORE_UNAVAILABLE"] = "1"
        }
        if repairStore {
            app.launchEnvironment["SNIP_SNAP_UI_TEST_SHARE_STORE_REPAIR"] = "1"
        }
        app.launch()
        return app
    }

    private func shareURLFromSafari(token: String) -> XCUIApplication {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let fixtureURL = "http://127.0.0.1:58493/"
        safari.launch()
        if safari.buttons["Continue"].waitForExistence(timeout: 1) {
            safari.buttons["Continue"].tap()
        }
        var address = safari.textFields["Address"].firstMatch
        if !address.waitForExistence(timeout: 3) {
            safari.buttons["Address"].tap()
            address = safari.textFields.firstMatch
        }
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap()
        var focusedAddress = safari.textFields.matching(
            NSPredicate(format: "hasKeyboardFocus == true")
        ).firstMatch
        XCTAssertTrue(focusedAddress.waitForExistence(timeout: 3))
        focusedAddress.typeKey("a", modifierFlags: .command)
        focusedAddress = safari.textFields.matching(
            NSPredicate(format: "hasKeyboardFocus == true")
        ).firstMatch
        XCTAssertTrue(focusedAddress.waitForExistence(timeout: 3))
        focusedAddress.typeText("\(fixtureURL)#\(token)")
        let currentAddress = safari.textFields.matching(
            NSPredicate(format: "value CONTAINS %@", token)
        ).firstMatch
        XCTAssertTrue(currentAddress.waitForExistence(timeout: 5))
        let go = safari.keyboards.buttons["Go"]
        XCTAssertTrue(go.waitForExistence(timeout: 3))
        go.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(safari.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(safari.staticTexts["Snip Snap Share Fixture"].waitForExistence(timeout: 10))
        if safari.buttons["Close"].exists {
            safari.buttons["Close"].tap()
        }
        var share = safari.buttons["Share"]
        if !share.waitForExistence(timeout: 1) {
            safari.buttons["More"].tap()
            share = safari.buttons["Share"]
        }
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        let activity = safari.cells["Snip Snap"]
        XCTAssertTrue(activity.waitForExistence(timeout: 8))
        activity.tap()
        return safari
    }

    private func assertShareExtensionReportedLocalSave(in safari: XCUIApplication) {
        let save = safari.buttons["share-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        XCTAssertTrue(
            save.waitForNonExistence(timeout: 8),
            "The extension did not report a completed local save to its host."
        )
        XCTAssertFalse(safari.otherElements["share-error"].exists)
    }

    private func assertShareProcessCount(_ expected: Int, in app: XCUIApplication) {
        let count = app.staticTexts["share-process-count"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", String(expected)),
            object: count
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    func testSearchDoneFilterAndUndo() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Alpha plan", in: app)
        returnToCollection(in: app)
        createSnip("Beta note", in: app)
        returnToCollection(in: app)

        let search = app.searchFields["Search Snips"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Alpha")
        XCTAssertTrue(row(named: "Alpha plan", in: app).exists)
        XCTAssertFalse(collectionRow(named: "Beta note", in: app).exists)
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        } else {
            search.typeText("\n")
        }
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3))
        if app.buttons["Close"].waitForExistence(timeout: 1) {
            app.buttons["Close"].tap()
        }
        XCTAssertTrue(app.buttons["workflow-options"].waitForExistence(timeout: 3))

        let alpha = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Alpha plan")
        ).firstMatch
        alpha.swipeRight()
        if app.buttons["mark-done"].exists {
            app.buttons["mark-done"].tap()
        }
        let becameDone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Done"),
            object: alpha
        )
        XCTAssertEqual(XCTWaiter.wait(for: [becameDone], timeout: 3), .completed)
        app.buttons["workflow-options"].tap()
        app.buttons["filter-done"].tap()
        XCTAssertTrue(collectionRow(named: "Alpha plan", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(collectionRow(named: "Beta note", in: app).exists)

        app.buttons["undo-change"].tap()
        XCTAssertTrue(collectionRow(named: "Alpha plan", in: app).waitForNonExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["No done snips"].exists || app.staticTexts["No Results"].exists
        )
    }

    func testSelectsManyMovesThemAndChangesManualOrder() {
        continueAfterFailure = false
        let app = launchApp()
        createList("Work", in: app)
        returnToLists(in: app)
        app.buttons["list-Inbox"].tap()
        createSnip("One", in: app)
        returnToCollection(in: app)
        createSnip("Two", in: app)
        returnToCollection(in: app)

        enterSelection(in: app)
        row(named: "One", in: app).tap()
        row(named: "Two", in: app).tap()
        app.buttons["selection-actions"].tap()
        app.buttons["move-selection"].tap()
        app.buttons["move-selection-to-Work"].tap()

        returnToLists(in: app)
        app.buttons["list-Work"].tap()
        XCTAssertTrue(app.staticTexts["One"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Two"].waitForExistence(timeout: 3))
        app.buttons["workflow-options"].tap()
        app.buttons["sort-manual"].tap()
        enterSelection(in: app)
        row(named: "One", in: app).tap()
        app.buttons["selection-actions"].tap()
        app.buttons["move-selection-up"].tap()

        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label MATCHES %@", "(One|Two).*"))
                .element(boundBy: 0).label.components(separatedBy: ",").first,
            "One"
        )
    }

    func testChangingListsEndsSelection() {
        continueAfterFailure = false
        let app = launchApp()
        createList("Work", in: app)
        returnToLists(in: app)
        app.buttons["list-Inbox"].tap()
        createSnip("Selected note", in: app)
        returnToCollection(in: app)

        enterSelection(in: app)
        row(named: "Selected note", in: app).tap()
        XCTAssertTrue(app.buttons["selection-actions"].waitForExistence(timeout: 3))

        if !app.buttons["list-Work"].exists { returnToLists(in: app) }
        app.buttons["list-Work"].tap()
        XCTAssertTrue(app.buttons["selection-actions"].waitForNonExistence(timeout: 3))
    }

    private func createSnip(_ text: String, in app: XCUIApplication) {
        app.buttons["new-snip"].tap()
        let editor = app.textViews["snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText(text)
        app.buttons["save-snip"].tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 3))
    }

    private func row(named text: String, in app: XCUIApplication) -> XCUIElement {
        let row = collectionRow(named: text, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        return row
    }

    private func collectionRow(named text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", text)
        ).firstMatch
    }

    private func enterSelection(in app: XCUIApplication) {
        let editButton = app.buttons["select-snips"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.tap()
        let becameDone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Done"),
            object: editButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [becameDone], timeout: 3), .completed)
    }

    private func createList(_ name: String, in app: XCUIApplication) {
        let newList = app.buttons["new-list"]
        if !newList.waitForExistence(timeout: 1) { returnToLists(in: app) }
        newList.tap()
        let field = app.textFields["list-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(name)
        app.buttons["save-list"].tap()
    }

    private func returnToCollection(in app: XCUIApplication) {
        let back = app.buttons["BackButton"]
        if back.exists { back.tap() }
    }

    private func returnToLists(in app: XCUIApplication) {
        returnToCollection(in: app)
        if !app.buttons["new-list"].exists {
            app.buttons["BackButton"].tap()
        }
        XCTAssertTrue(app.buttons["new-list"].waitForExistence(timeout: 3))
    }
}
