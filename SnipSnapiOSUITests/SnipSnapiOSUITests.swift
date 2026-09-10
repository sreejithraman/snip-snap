import UIKit
import XCTest

@MainActor
final class SnipSnapiOSUITests: XCTestCase {
    private var shareAppName = ""

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launchApp(
        storeName: String = "ui-\(UUID().uuidString)",
        withAttachments: Bool = false,
        withRecovery: Bool = false,
        withSyncedContent: Bool = false,
        withSyncEnable: Bool = false,
        withLimitAttachments: Bool = false,
        withEncryptedReset: Bool = false,
        accountNotice: Bool = false,
        withCopyShareFixtures: Bool = false,
        withHapticsTrace: Bool = false,
        syncIssue: String? = nil,
        contentSizeCategory: UIContentSizeCategory? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SNIP_SNAP_UI_TESTING"] = "1"
        if withHapticsTrace { app.launchEnvironment["SNIP_SNAP_UI_TEST_HAPTICS"] = "1" }
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
        if let syncIssue {
            app.launchEnvironment["SNIP_SNAP_UI_TEST_SYNC_ISSUE"] = syncIssue
        }
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory.rawValue]
        }
        app.launch()
        shareAppName = app.label
        return app
    }

    func testSwipeAndContextActionsPublishHapticOutcomes() {
        continueAfterFailure = false
        let app = launchApp(withHapticsTrace: true)
        func expectHaptic(_ kind: String) {
            let trace = app.staticTexts["haptic-event"]
            let expected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label BEGINSWITH %@", kind + ":"), object: trace
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 4), .completed)
        }
        createSnip("Swipe feedback", in: app)
        expectHaptic("saved")
        let swiped = row(named: "Swipe feedback", in: app)
        swiped.swipeRight()
        app.buttons["done"].tap()
        expectHaptic("markedDone")
        swiped.swipeLeft()
        app.buttons["delete-snip"].tap()
        XCTAssertTrue(swiped.waitForNonExistence(timeout: 4))
        expectHaptic("deleted")

        createSnip("Menu feedback", in: app)
        expectHaptic("saved")
        let menuRow = row(named: "Menu feedback", in: app)
        menuRow.press(forDuration: 1)
        app.buttons["copy-snip"].tap()
        expectHaptic("copied")
        menuRow.press(forDuration: 1)
        app.buttons["delete-context-snip"].tap()
        XCTAssertTrue(menuRow.waitForNonExistence(timeout: 4))
        expectHaptic("deleted")
    }

    func testHapticsPreferenceCanChangeAndSurvivesRelaunch() {
        continueAfterFailure = false
        let app = launchApp()
        openSettings(in: app)
        let haptics = app.switches["haptics-toggle"]
        XCTAssertTrue(haptics.waitForExistence(timeout: 3))
        let initial = haptics.value as? String
        XCTAssertEqual(initial, "1")
        toggle(haptics)
        let changed = NSPredicate(format: "value != %@", initial ?? "")
        expectation(for: changed, evaluatedWith: haptics)
        waitForExpectations(timeout: 3)
        let saved = haptics.value as? String

        app.terminate()
        app.launch()
        openSettings(in: app)
        XCTAssertTrue(haptics.waitForExistence(timeout: 3))
        XCTAssertEqual(haptics.value as? String, saved)
        if haptics.value as? String != "1" { toggle(haptics) }
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: haptics)
        waitForExpectations(timeout: 3)
    }

    func testExplicitEnableKeepsLocalContentAndTurnsSyncOn() {
        continueAfterFailure = false
        let app = launchApp(withSyncEnable: true)
        createSnip("Keep while enabling sync", in: app)
        let localSnip = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Keep while enabling sync")
        ).firstMatch
        XCTAssertTrue(localSnip.waitForExistence(timeout: 3))
        openSettings(in: app)
        let privacyPolicy = app.descendants(matching: .any)
            .matching(identifier: "privacy-policy")
            .firstMatch
        XCTAssertTrue(privacyPolicy.waitForExistence(timeout: 3))

        XCTAssertTrue(app.staticTexts["Local Only"].waitForExistence(timeout: 3))
        toggle(app.switches["icloud-sync-toggle"])
        XCTAssertTrue(app.staticTexts["iCloud Sync On"].waitForExistence(timeout: 8))
        app.buttons["Done"].tap()
        let inbox = listControl(named: "Inbox", in: app)
        if inbox.waitForExistence(timeout: 2) {
            inbox.tap()
        }
        XCTAssertTrue(localSnip.waitForExistence(timeout: 3))
    }

    func testSyncEnableReportsEveryAttachmentAboveTheSnipSnapLimit() {
        continueAfterFailure = false
        let app = launchApp(withSyncEnable: true, withLimitAttachments: true)
        XCTAssertTrue(app.staticTexts["Attachment fixture"].waitForExistence(timeout: 8))
        openSettings(in: app)

        toggle(app.switches["icloud-sync-toggle"])

        XCTAssertTrue(app.staticTexts["iCloud Sync Setup Stopped"].waitForExistence(timeout: 8))
        let firstDetail = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "over-limit-a.bin")
        ).firstMatch
        let secondDetail = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "over-limit-b.bin")
        ).firstMatch
        XCTAssertTrue(firstDetail.waitForExistence(timeout: 3))
        XCTAssertTrue(secondDetail.waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["icloud-sync-toggle"].exists)
        XCTAssertFalse(app.staticTexts["iCloud Sync On"].exists)
    }

    func testInternalSyncIssueUsesCalmCopyWithoutRawErrorCodes() {
        continueAfterFailure = false
        let app = launchApp(withSyncedContent: true, syncIssue: "app-data")

        openSettings(in: app)

        XCTAssertTrue(app.staticTexts["Snip Snap Couldn’t Sync"].waitForExistence(timeout: 3))
        let safeCopy = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Your changes are safe on this device")
        ).firstMatch
        XCTAssertTrue(safeCopy.exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "CloudRecordError")
        ).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "error 2")
        ).firstMatch.exists)
    }

    func testTurningSyncOffKeepsTheLibraryAndLeavesDeleteSeparate() {
        continueAfterFailure = false
        let app = launchApp(withSyncedContent: true)
        createSnip("Keep this", in: app)
        let saved = collectionRow(named: "Keep this", in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
        openSettings(in: app)

        let sync = app.switches["icloud-sync-toggle"]
        XCTAssertTrue(sync.waitForExistence(timeout: 3))
        XCTAssertEqual(sync.value as? String, "1")
        XCTAssertTrue(app.buttons["delete-synced-content"].exists)
        toggle(sync)

        let staleCopyAlert = app.alerts["Use This Device’s Copy?"]
        if staleCopyAlert.waitForExistence(timeout: 3) {
            staleCopyAlert.buttons["Use Device Copy"].tap()
        }

        XCTAssertTrue(app.staticTexts["Local Only"].waitForExistence(timeout: 8))
        XCTAssertEqual(sync.value as? String, "0")
        XCTAssertFalse(app.buttons["delete-synced-content"].exists)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "iCloud sync off keeps a local copy"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["Done"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
    }

    func testDeleteSyncedContentExplainsAndConfirmsReset() {
        continueAfterFailure = false
        let app = launchApp(withSyncedContent: true)
        createSnip("Visible before cloud reset", in: app)
        let priorSnip = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Visible before cloud reset")
        ).firstMatch
        XCTAssertTrue(priorSnip.waitForExistence(timeout: 3))
        openSettings(in: app)

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

    func testEncryptedDataResetTurnsSyncOffWithoutOfferingARecoveryUpload() {
        continueAfterFailure = false
        let app = launchApp(withSyncedContent: true, withEncryptedReset: true)
        openSettings(in: app)

        XCTAssertTrue(app.staticTexts["iCloud Sync Was Turned Off"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["encrypted-reset-restore"].exists)
        XCTAssertFalse(app.buttons["encrypted-reset-start-empty"].exists)
        XCTAssertFalse(app.buttons["encrypted-reset-keep-off"].exists)
        XCTAssertTrue(app.switches["icloud-sync-toggle"].value as? String == "0")
    }

    func testReviewsRecoveredSnipAndListEdits() {
        continueAfterFailure = false
        let app = launchApp(withRecovery: true)
        let attention = app.buttons["needs-attention"]
        if !attention.waitForExistence(timeout: 1) {
            let actions = app.buttons["library-actions"]
            if actions.waitForExistence(timeout: 2) {
                actions.tap()
            } else {
                let showSidebar = app.buttons["Show Sidebar"]
                if showSidebar.exists {
                    showSidebar.tap()
                } else if app.buttons["BackButton"].exists {
                    app.buttons["BackButton"].tap()
                } else {
                    app.navigationBars.buttons.firstMatch.tap()
                }
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

        assertCopyStatus("Copied", in: app)
    }

    func testCopiesFileOnlySnipAttachments() {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        openCopyShareFixture(matching: "notes.txt", in: app)
        chooseDetailAction("copy-attachments-snip", in: app)

        assertCopyStatus("Copied Attachments", in: app)
    }

    func testCopiesMixedSnipText() {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        openCopyShareFixture(matching: "Copy mixed fixture", in: app)
        chooseDetailAction("copy-text-snip", in: app)

        assertCopyStatus("Copied Text", in: app)
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

    func testSharesSnipBackIntoSnipSnap() {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        openCopyShareFixture(matching: "Copy text fixture", in: app)
        chooseDetailAction("share-snip", in: app)
        XCTAssertTrue(activityView(in: app).waitForExistence(timeout: 5))

        let snipSnap = app.cells[shareAppName]
        XCTAssertTrue(snipSnap.waitForExistence(timeout: 5))
        snipSnap.tap()

        let sharedText = app.textViews["share-text"]
        XCTAssertTrue(sharedText.waitForExistence(timeout: 5))
        XCTAssertEqual(sharedText.value as? String, "Copy text fixture")
        XCTAssertFalse(app.staticTexts["text.txt"].exists)
        XCTAssertFalse(app.otherElements["share-error"].exists)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Snip shared back into Snip Snap"
        proof.lifetime = .keepAlways
        add(proof)
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
        assertCopyStatus("Copied Text", in: app)
    }

    func testCreatesAndEditsTextSnip() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("A useful thought", in: app)

        let savedText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "A useful thought")
        ).firstMatch
        XCTAssertTrue(savedText.waitForExistence(timeout: 3))
        let composer = app.descendants(matching: .any)["composer-text"]
        expectation(
            for: NSPredicate(format: "value == %@ OR value == %@", "Add to Inbox…", ""),
            evaluatedWith: composer
        )
        waitForExpectations(timeout: 5)

        let snipRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "A useful thought")
        ).firstMatch
        XCTAssertTrue(snipRow.waitForExistence(timeout: 3))
        snipRow.tap()
        XCTAssertFalse(app.navigationBars["Snip"].exists)
        Thread.sleep(forTimeInterval: 0.6)
        snipRow.doubleTap()
        let editor = app.descendants(matching: .any)["inline-snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars["Edit Snip"].exists)
        let inlineEditorScreenshot = XCTAttachment(screenshot: app.screenshot())
        inlineEditorScreenshot.name = "Inline Snip Editor"
        inlineEditorScreenshot.lifetime = .keepAlways
        add(inlineEditorScreenshot)
        editor.tap()
        editor.typeText(" updated")
        app.buttons["inline-snip-save"].tap()

        let updatedText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "updated")
        ).firstMatch
        XCTAssertTrue(updatedText.waitForExistence(timeout: 3))
    }

    func testSearchPreservesInlineSnipDraft() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createSnip("Inline draft", in: app)
        row(named: "Inline draft", in: app).doubleTap()
        let editor = app.descendants(matching: .any)["inline-snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText(" unsaved")
        let draft = editor.value as? String
        app.swipeDown()

        let search = openSearch(in: app)
        search.typeText("Missing entry")
        closeSearch(in: app)

        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, draft)
        app.buttons["inline-snip-save"].tap()
        XCTAssertTrue(collectionRow(named: "Inline draft unsaved", in: app).waitForExistence(timeout: 3))
    }

    func testQuickComposerSendsWithoutOpeningTheEditor() throws {
        continueAfterFailure = false
        let app = launchApp()
        let composer = app.descendants(matching: .any)["composer-text"]
        let addAttachments = app.buttons["composer-add-attachments"]
        let send = app.buttons["composer-send"]
        let compactInbox = compactListTab(named: "Inbox", in: app)
        let newList = compactInbox.exists ? compactInbox : app.buttons["new-list"]

        XCTAssertTrue(
            composer.waitForExistence(timeout: 5),
            "The quick composer must exist on both iPhone and iPad."
        )
        for control in [addAttachments, send, newList] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        XCTAssertEqual(addAttachments.frame.midY, composer.frame.midY, accuracy: 1)
        XCTAssertEqual(send.frame.midY, composer.frame.midY, accuracy: 1)
        XCTAssertTrue(newList.exists)
        XCTAssertFalse(send.isEnabled)

        composer.tap()
        composer.typeText("Sent")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(newList.exists)
        XCTAssertTrue(send.isEnabled)
        XCTAssertEqual(addAttachments.frame.midY, composer.frame.midY, accuracy: 1)
        XCTAssertEqual(send.frame.midY, composer.frame.midY, accuracy: 1)
        let filledComposerScreenshot = XCTAttachment(screenshot: app.screenshot())
        filledComposerScreenshot.name = "Filled Quick Composer"
        filledComposerScreenshot.lifetime = .keepAlways
        add(filledComposerScreenshot)
        composer.typeText(
            " from a quick composer entry that is long enough to wrap "
                + "onto another line even on a wide iPhone display"
        )
        XCTAssertGreaterThan(composer.frame.height, addAttachments.frame.height)
        XCTAssertEqual(addAttachments.frame.maxY, send.frame.maxY, accuracy: 1)
        send.tap()

        let savedText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Sent")
        ).firstMatch
        XCTAssertTrue(savedText.waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled)
    }

    func testCompactRowTapStaysUnselected() throws {
        continueAfterFailure = false
        let app = launchApp()
        let composer = app.descendants(matching: .any)["composer-text"]

        guard composer.waitForExistence(timeout: 5) else {
            throw XCTSkip("The compact library is limited to iPhone.")
        }

        createSnip("Compact interaction fixture", in: app)
        let snipRow = row(named: "Compact interaction fixture", in: app)
        snipRow.tap()
        XCTAssertFalse(snipRow.isSelected)
    }

    func testCompactListDragDismissesKeyboard() throws {
        continueAfterFailure = false
        let app = launchApp()
        let composer = app.descendants(matching: .any)["composer-text"]

        guard composer.waitForExistence(timeout: 5) else {
            throw XCTSkip("The compact library is limited to iPhone.")
        }

        createSnip("Compact keyboard fixture", in: app)
        composer.tap()
        composer.typeText("Unsent draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.swipeDown()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
    }

    func testEmptyCompactListDragDismissesKeyboard() throws {
        continueAfterFailure = false
        let app = launchApp()
        let composer = app.descendants(matching: .any)["composer-text"]

        guard composer.waitForExistence(timeout: 5) else {
            throw XCTSkip("The compact library is limited to iPhone.")
        }

        composer.tap()
        composer.typeText("Unsent empty-list draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.swipeDown()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
    }

    func testLeadingClipboardPasteCapturesCopiedText() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createSnip("Paste button fixture", in: app)
        row(named: "Paste button fixture", in: app).press(forDuration: 1)
        app.buttons["copy-snip"].tap()
        app.buttons["clipboard-tab"].tap()
        let paste = app.buttons["paste-to-clipboard"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        XCTAssertTrue(paste.isEnabled)
        paste.tap()
        let entry = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "clipboard-entry-")
        ).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Paste button fixture"].exists)
        let selector = app.descendants(matching: .any)["list-selector"]
        XCTAssertEqual(paste.frame.midY, selector.frame.midY, accuracy: 2)
        XCTAssertLessThan(paste.frame.maxX, selector.frame.minX)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Leading native Paste button"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testClipboardUsesListScreenControls() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        let restingSelector = app.descendants(matching: .any)["list-selector"].frame
        let restingSelectorWidth = restingSelector.width
        XCTAssertEqual(restingSelector.midX, app.frame.midX, accuracy: 2)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Search'")).count, 1)
        XCTAssertFalse(app.searchFields["Search All"].exists)
        app.buttons["clipboard-tab"].tap()
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.searchFields["Search All"].exists || app.buttons["Search"].exists)
        XCTAssertTrue(app.buttons["workflow-options"].exists)
        XCTAssertTrue(app.buttons["library-actions"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["empty-clipboard"].exists)
        let paste = app.buttons["paste-to-clipboard"]
        XCTAssertTrue(paste.exists)
        let selector = app.descendants(matching: .any)["list-selector"]
        XCTAssertEqual(paste.frame.midY, selector.frame.midY, accuracy: 2)
        XCTAssertLessThan(paste.frame.maxX, selector.frame.minX)
        app.buttons["workflow-options"].tap()
        app.buttons["Pinned"].tap()
        XCTAssertTrue(app.staticTexts["No pinned entries"].waitForExistence(timeout: 3))
        let search = openSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertEqual(search.placeholderValue, "Search All")
        search.typeText("Missing entry")
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 3))
        closeSearch(in: app)
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.searchFields["Search All"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No pinned entries"].waitForExistence(timeout: 3))
        app.buttons["workflow-options"].tap()
        app.buttons["All"].tap()
        XCTAssertTrue(app.staticTexts["Nothing captured yet"].waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Clipboard with shared list screen controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(selector.frame.width, restingSelectorWidth, accuracy: 2)
        XCTAssertEqual(selector.frame.midX, app.frame.midX, accuracy: 2)
        XCTAssertLessThan(selector.frame.maxX, app.buttons["Search"].frame.minX)
        compactListTab(named: "Inbox", in: app).tap()
        XCTAssertTrue(paste.waitForNonExistence(timeout: 3))
        XCTAssertEqual(selector.frame.width, restingSelectorWidth, accuracy: 2)
        XCTAssertEqual(selector.frame.midX, restingSelector.midX, accuracy: 2)
        app.buttons["clipboard-tab"].tap()
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        app.buttons["library-actions"].tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 3))
    }

    func testClipboardAndSelectorPreserveNavigationAndDraft() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createSnip("Selection fixture", in: app)
        let composer = app.descendants(matching: .any)["composer-text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Unsent draft")
        app.swipeDown()
        let clipboard = app.buttons["clipboard-tab"]
        clipboard.tap()
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertFalse(composer.exists)
        let inbox = compactListTab(named: "Inbox", in: app)
        XCTAssertFalse(inbox.isSelected)
        inbox.tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Unsent draft")
        XCTAssertTrue(inbox.isSelected)
        let search = openSearch(in: app)
        search.typeText("Draft search")
        closeSearch(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Unsent draft")
        let selectorBeforeSelection = app.descendants(matching: .any)["list-selector"].frame
        enterSelection(in: app)
        XCTAssertTrue(composer.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.descendants(matching: .any)["list-selector"].frame.midY,
                       selectorBeforeSelection.midY, accuracy: 2)
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Unsent draft")
        clipboard.tap()
        XCTAssertTrue(clipboard.isSelected)
        let selector = app.descendants(matching: .any)["list-selector"]
        XCTAssertEqual(clipboard.frame.midX, selector.frame.midX, accuracy: 2)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Clipboard selected inside list strip"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        clipboard.tap()
        app.menuItems["New List"].tap()
        let field = app.textFields["list-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("From Clipboard")
        app.buttons["save-list"].tap()
        XCTAssertTrue(app.navigationBars["From Clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(compactListTab(named: "From Clipboard", in: app).isSelected)
    }

    func testSelectorSwipeReturnsToCompactWidth() throws {
        continueAfterFailure = false
        let app = launchApp(withHapticsTrace: true)
        try requireCompactSelector(in: app)
        let restingFrame = app.descendants(matching: .any)["list-selector"].frame
        XCTAssertEqual(restingFrame.midX, app.frame.midX, accuracy: 2)
        app.buttons["clipboard-tab"].tap()
        let initialEvent = app.staticTexts["haptic-event"].label
        XCTAssertTrue(initialEvent.hasPrefix("selection:"))
        let selector = app.descendants(matching: .any)["list-selector"]
        let restingWidth = selector.frame.width
        XCTAssertEqual(restingWidth, restingFrame.width, accuracy: 2)
        XCTAssertEqual(selector.frame.midX, restingFrame.midX, accuracy: 2)
        let start = selector.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: -20, dy: 0)),
            withVelocity: XCUIGestureVelocity(rawValue: 80),
            thenHoldForDuration: 0.5
        )
        XCTAssertEqual(app.staticTexts["haptic-event"].label, initialEvent)
        XCTAssertTrue(app.navigationBars["Clipboard"].exists)
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: -130, dy: 0)),
            withVelocity: XCUIGestureVelocity(rawValue: 80),
            thenHoldForDuration: 1
        )
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertEqual(selector.frame.width, restingWidth, accuracy: 2)
        XCTAssertEqual(selector.frame.midX, restingFrame.midX, accuracy: 2)
        XCTAssertLessThan(selector.frame.maxX, app.buttons["Search"].frame.minX)
        XCTAssertFalse(app.buttons["paste-to-clipboard"].exists)
        let switchedEvent = app.staticTexts["haptic-event"].label
        XCTAssertTrue(switchedEvent.hasPrefix("selection:"))
        XCTAssertNotEqual(switchedEvent, initialEvent)
        let back = selector.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        back.press(
            forDuration: 0.05,
            thenDragTo: back.withOffset(CGVector(dx: 130, dy: 0)),
            withVelocity: XCUIGestureVelocity(rawValue: 80),
            thenHoldForDuration: 1
        )
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["paste-to-clipboard"].waitForExistence(timeout: 3))
        XCTAssertEqual(selector.frame.width, restingWidth, accuracy: 2)
        XCTAssertEqual(selector.frame.midX, restingFrame.midX, accuracy: 2)
        XCTAssertTrue(app.staticTexts["haptic-event"].label.hasPrefix("selection:"))
        XCTAssertNotEqual(app.staticTexts["haptic-event"].label, switchedEvent)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Compact centered selector after swiping"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testTabDragKeepsEachListsContentDraftAndRowActions() throws {
        continueAfterFailure = false
        let originalAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = originalAppearance }
        let app = launchApp()
        try requireCompactSelector(in: app)
        createSnip("Inbox page note", in: app)
        let composer = app.descendants(matching: .any)["composer-text"]
        composer.tap()
        composer.typeText("Inbox unsent draft")
        app.swipeDown()
        createList("Work", in: app)
        createSnip("Work page note", in: app)
        composer.tap()
        composer.typeText("Work unsent draft")
        app.swipeDown()

        func dragTabs(_ distance: CGFloat) {
            let selector = app.descendants(matching: .any)["list-selector"]
            let start = selector.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(
                forDuration: 0.05,
                thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
                withVelocity: XCUIGestureVelocity(rawValue: 100),
                thenHoldForDuration: 0.2
            )
        }

        // A short pull returns to the current page and keeps its unsent text.
        dragTabs(20)
        XCTAssertTrue(compactListTab(named: "Work", in: app).isSelected)
        XCTAssertEqual(composer.value as? String, "Work unsent draft")
        dragTabs(140)
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(collectionRow(named: "Inbox page note", in: app).exists)
        XCTAssertFalse(collectionRow(named: "Work page note", in: app).exists)
        XCTAssertEqual(composer.value as? String, "Inbox unsent draft")

        dragTabs(-140)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(collectionRow(named: "Work page note", in: app).exists)
        XCTAssertFalse(collectionRow(named: "Inbox page note", in: app).exists)
        XCTAssertEqual(composer.value as? String, "Work unsent draft")

        let workRow = row(named: "Work page note", in: app)
        workRow.swipeRight()
        XCTAssertTrue(app.buttons["done"].waitForExistence(timeout: 3))
        app.buttons["done"].tap()
        XCTAssertTrue(compactListTab(named: "Work", in: app).isSelected)
        XCTAssertEqual(composer.value as? String, "Work unsent draft")

        // Cross Inbox in one continuous pull to Clipboard, then return to Work.
        func dragAcrossTabs(_ distance: CGFloat) {
            let selector = app.descendants(matching: .any)["list-selector"]
            let start = selector.coordinate(withNormalizedOffset: CGVector(
                dx: distance > 0 ? 0.05 : 0.95, dy: 0.5
            ))
            start.press(
                forDuration: 0.05,
                thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
                withVelocity: XCUIGestureVelocity(rawValue: 100),
                thenHoldForDuration: 0.3
            )
        }
        dragAcrossTabs(260)
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertFalse(composer.exists)
        dragAcrossTabs(-260)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Work"].staticTexts["Work"].isHittable)
        XCTAssertTrue(
            hasVisibleTitlePixels(app.navigationBars["Work"].staticTexts["Work"].screenshot()),
            "The native title must be drawn after returning across several tabs."
        )
        XCTAssertEqual(composer.value as? String, "Work unsent draft")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Work page and draft after tab drag and row action"
        proof.lifetime = .keepAlways
        add(proof)
    }

    private func hasVisibleTitlePixels(_ screenshot: XCUIScreenshot) -> Bool {
        guard let image = screenshot.image.cgImage else { return false }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        return pixels.withUnsafeMutableBytes { pointer in
            guard let context = CGContext(
                data: pointer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return pointer.filter { $0 > 150 }.count > 100
        }
    }

    func testSelectorFitsBesideControlsAtLargestTextSize() throws {
        continueAfterFailure = false
        let app = launchApp(contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        try requireCompactSelector(in: app)
        let selector = app.descendants(matching: .any)["list-selector"]
        let start = selector.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 130, dy: 0)))
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        let paste = app.buttons["paste-to-clipboard"]
        let search = app.buttons["Search"]
        XCTAssertGreaterThan(paste.frame.width, 48)
        XCTAssertEqual(selector.frame.midX, app.frame.midX, accuracy: 2)
        XCTAssertEqual(selector.frame.width, min(256, app.frame.width - 168), accuracy: 2)
        XCTAssertGreaterThanOrEqual(selector.frame.minX - paste.frame.maxX, 7)
        XCTAssertGreaterThanOrEqual(search.frame.minX - selector.frame.maxX, 7)
        XCTAssertFalse(app.searchFields["Search All"].exists)
    }

    func testSelectorPullThresholdCancelAndCreate() throws {
        continueAfterFailure = false
        let app = launchApp(withHapticsTrace: true)
        try requireCompactSelector(in: app)
        let inbox = compactListTab(named: "Inbox", in: app)
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        let edge = app.descendants(matching: .any)["list-selector"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        edge.press(
            forDuration: 0.05,
            thenDragTo: edge.withOffset(CGVector(dx: -80, dy: 0)),
            withVelocity: XCUIGestureVelocity(rawValue: 40),
            thenHoldForDuration: 0.6
        )
        XCTAssertFalse(app.textFields["list-name"].exists)
        XCTAssertTrue(inbox.isSelected)
        XCTAssertEqual(app.staticTexts["haptic-event"].label, "none")

        edge.press(
            forDuration: 0.05,
            thenDragTo: edge.withOffset(CGVector(dx: -110, dy: 0)),
            withVelocity: XCUIGestureVelocity(rawValue: 40),
            thenHoldForDuration: 1
        )
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 4))
        XCTAssertTrue(compactListTab(named: "New List", in: app).isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["composer-text"].exists)
        XCTAssertFalse(app.buttons["Cancel"].exists)
        let field = app.textFields["list-name"]
        field.tap()
        field.typeText("Travel")
        app.buttons["save-list"].tap()
        let travel = compactListTab(named: "Travel", in: app)
        XCTAssertTrue(travel.waitForExistence(timeout: 4))
        XCTAssertTrue(travel.isSelected)
        XCTAssertTrue(app.navigationBars["Travel"].exists)
        let center = travel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 140, dy: 0)))
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(inbox.isSelected)
    }

    func testSelectorDeleteListKeepsItsSnips() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        createSnip("Keep this note", in: app)
        let work = compactListTab(named: "Work", in: app)
        work.tap()
        XCTAssertTrue(app.menuItems["Delete List"].waitForExistence(timeout: 3))
        app.menuItems["Delete List"].tap()
        XCTAssertTrue(app.staticTexts["Its snips will move to Inbox."].waitForExistence(timeout: 3))
        app.buttons["Delete List"].tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(row(named: "Keep this note", in: app).exists)
        XCTAssertFalse(work.exists)
    }

    func testSelectorManyListsAndSelectedMenu() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        for name in ["Work", "Travel", "Reading", "Ideas", "A long list name for later"] {
            createList(name, in: app)
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3))
        }
        let last = compactListTab(named: "A long list name for later", in: app)
        XCTAssertTrue(last.isSelected)
        let selector = app.descendants(matching: .any)["list-selector"]
        XCTAssertEqual(last.frame.midX, selector.frame.midX, accuracy: 2)
        last.tap()
        XCTAssertTrue(app.menuItems["New List"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Edit List…"].exists)
        XCTAssertTrue(app.menuItems["Delete List"].exists)
        app.menuItems["New List"].tap()
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 3))
        app.buttons["save-list"].tap()
        last.tap()
        XCTAssertTrue(last.waitForExistence(timeout: 3))
        XCTAssertTrue(last.isSelected)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Content-sized selector with long name"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCompactListTabsCreateAndSwitchLists() throws {
        continueAfterFailure = false
        let app = launchApp()
        guard app.descendants(matching: .any)["composer-text"].waitForExistence(timeout: 5)
        else {
            throw XCTSkip("The compact list tabs are limited to iPhone.")
        }

        let inbox = compactListTab(named: "Inbox", in: app)
        XCTAssertTrue(inbox.waitForExistence(timeout: 3))
        XCTAssertTrue(inbox.isSelected)

        createList("Work", in: app)
        let work = compactListTab(named: "Work", in: app)
        XCTAssertTrue(work.waitForExistence(timeout: 3))
        XCTAssertTrue(work.isSelected)
        XCTAssertTrue(app.navigationBars["Work"].exists)

        inbox.tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(inbox.isSelected)
    }

    func testListEditorLetsTheUserChooseAnIcon() throws {
        continueAfterFailure = false
        let app = launchApp()
        guard app.descendants(matching: .any)["composer-text"].waitForExistence(timeout: 5)
        else {
            throw XCTSkip("The compact list tabs are limited to iPhone.")
        }

        openNewList(in: app)
        let field = app.textFields["list-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer-text"].exists)
        XCTAssertTrue(compactListTab(named: "New List", in: app).isSelected)
        XCTAssertFalse(app.buttons["Cancel"].exists)
        field.typeText("Starred")
        let chooseIcon = app.descendants(matching: .any)["choose-list-icon"]
        XCTAssertTrue(chooseIcon.waitForExistence(timeout: 3))
        chooseIcon.tap()
        let star = app.buttons["list-icon-star.fill"].firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        star.tap()
        let save = app.buttons["save-list"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()

        let starred = compactListTab(named: "Starred", in: app)
        XCTAssertTrue(starred.waitForExistence(timeout: 5))
        XCTAssertTrue(starred.isSelected)
        XCTAssertTrue(app.navigationBars["Starred"].exists)
    }

    func testExistingListKeepsEditsAfterChoosingAnIcon() throws {
        continueAfterFailure = false
        let app = launchApp()
        createList("Work", in: app)
        let work = listControl(named: "Work", in: app)
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        openListEditor(named: "Work", in: app)

        let field = app.textFields["list-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(" Updated")
        let editedName = try XCTUnwrap(field.value as? String)
        app.buttons["list-color-blue"].tap()
        let chooseIcon = app.descendants(matching: .any)["choose-list-icon"].firstMatch
        chooseIcon.tap()
        let star = app.buttons["list-icon-star.fill"].firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        star.tap()

        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue(chooseIcon.label.contains("Star Fill"))
        XCTAssertEqual(field.value as? String, editedName)
        XCTAssertTrue(app.buttons["list-color-blue"].isSelected)
        app.buttons["save-list"].tap()

        let saved = listControl(named: editedName, in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        openListEditor(named: editedName, in: app)
        XCTAssertTrue(chooseIcon.waitForExistence(timeout: 3))
        XCTAssertTrue(chooseIcon.label.contains("Star Fill"))
        XCTAssertEqual(field.value as? String, editedName)
        XCTAssertTrue(app.buttons["list-color-blue"].isSelected)
    }

    func testListEditorKeepsDraftAcrossSearch() {
        continueAfterFailure = false
        let app = launchApp()
        createList("Reading", in: app)
        createSnip("A saved passage", in: app)
        openListEditor(named: "Reading", in: app)

        let field = app.textFields["list-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(" Notes")
        let editedName = field.value as? String
        app.buttons["list-color-blue"].tap()

        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Glass list editor"
        preview.lifetime = .keepAlways
        add(preview)

        let search = openSearch(in: app)
        search.typeText("saved passage")
        XCTAssertTrue(collectionRow(named: "A saved passage", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(field.exists)
        closeSearch(in: app)

        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, editedName)
        XCTAssertTrue(app.buttons["list-color-blue"].isSelected)
        app.buttons["save-list"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["composer-text"].isHittable)
    }

    func testListEditorIconSearchKeepsControlsReachable() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchApp()
        createList("Reading", in: app)
        openListEditor(named: "Reading", in: app)
        app.buttons["choose-list-icon"].tap()

        let search = app.textFields["Search icons"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("star")
        let star = app.buttons["list-icon-star.fill"].firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 3))
        star.tap()
        app.buttons["save-list"].tap()
        XCTAssertTrue(app.textFields["list-name"].waitForNonExistence(timeout: 3))
    }

    func testLibraryActionsExposeBackupImportWithoutHistoryCommands() {
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
        XCTAssertTrue(app.buttons["Import Backup…"].exists)
        XCTAssertFalse(app.buttons["Undo"].exists)
        XCTAssertFalse(app.buttons["Redo"].exists)
    }

    func testCreatesListMovesSnipAndDeletesIt() {
        continueAfterFailure = false
        let app = launchApp()
        openNewList(in: app)
        let name = app.textFields["list-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Work")
        app.buttons["save-list"].tap()

        let workList = listControl(named: "Work", in: app)
        if workList.waitForExistence(timeout: 1) {
            if !workList.isSelected { workList.tap() }
        } else {
            XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        }
        createSnip("Move this", in: app)

        let moveRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Move this")
        ).firstMatch
        XCTAssertTrue(moveRow.waitForExistence(timeout: 3))
        moveRow.press(forDuration: 1)
        app.buttons["move-snip"].tap()
        app.buttons["move-to-Inbox"].tap()
        compactListTab(named: "Inbox", in: app).tap()
        let moved = row(named: "Move this", in: app)
        moved.press(forDuration: 1)
        app.buttons["Delete"].tap()
        XCTAssertTrue(moved.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["app-toast"].waitForExistence(timeout: 3))
        app.buttons["toast-action"].tap()
        XCTAssertTrue(row(named: "Move this", in: app).waitForExistence(timeout: 3))
    }

    func testDeleteToastUndoRestoresSnip() {
        continueAfterFailure = false
        let originalAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = originalAppearance }
        let app = launchApp()
        createSnip("Undo this", in: app)

        let snip = row(named: "Undo this", in: app)
        XCTAssertTrue(snip.waitForExistence(timeout: 3))
        snip.press(forDuration: 1)
        app.buttons["Delete"].tap()

        XCTAssertTrue(snip.waitForNonExistence(timeout: 3))
        let toast = app.descendants(matching: .any)["app-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertLessThan(toast.frame.width, app.frame.width - 48)
        let composer = app.textFields["composer-text"]
        let sendButton = app.buttons["composer-send"]
        XCTAssertLessThanOrEqual(toast.frame.height, sendButton.frame.height + 4)
        XCTAssertLessThanOrEqual(
            toast.frame.maxY,
            composer.frame.minY
        )
        let actionScreenshot = app.buttons["toast-action"].screenshot()
        let actionAttachment = XCTAttachment(screenshot: actionScreenshot)
        actionAttachment.name = "Filled toast action"
        actionAttachment.lifetime = .keepAlways
        add(actionAttachment)
        XCTAssertEqual(app.buttons["toast-action"].label, "Undo")
        XCTAssertTrue(
            hasDarkPixelsInLabelArea(actionScreenshot),
            "The Undo label must contrast with its light button background in dark mode."
        )
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Delete toast above compact controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["toast-action"].tap()
        XCTAssertTrue(row(named: "Undo this", in: app).waitForExistence(timeout: 3))
    }

    private func hasDarkPixelsInLabelArea(_ screenshot: XCUIScreenshot) -> Bool {
        guard let source = screenshot.image.cgImage else { return false }
        let crop = CGRect(
            x: CGFloat(source.width) * 0.2,
            y: CGFloat(source.height) * 0.25,
            width: CGFloat(source.width) * 0.6,
            height: CGFloat(source.height) * 0.5
        ).integral
        guard let labelArea = source.cropping(to: crop) else { return false }

        let width = labelArea.width
        let height = labelArea.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        return pixels.withUnsafeMutableBytes { pointer in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            context.draw(labelArea, in: CGRect(x: 0, y: 0, width: width, height: height))
            return pointer.contains { $0 < 128 }
        }
    }

    func testTappingCompletionCircleTogglesWithoutEditingOrSelecting() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Tap the completion circle", in: app)
        let snip = row(named: "Tap the completion circle", in: app)
        snip.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.2)).tap()
        let becameDone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Done"), object: snip
        )
        XCTAssertEqual(XCTWaiter.wait(for: [becameDone], timeout: 3), .completed)
        XCTAssertFalse(app.buttons["selection-actions"].exists)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Tappable completion circle"
        proof.lifetime = .keepAlways
        add(proof)
        snip.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.2)).tap()
        let becameNotDone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Not Done"), object: snip
        )
        XCTAssertEqual(XCTWaiter.wait(for: [becameNotDone], timeout: 3), .completed)
        enterSelection(in: app)
        row(named: "Tap the completion circle", in: app).tap()
        XCTAssertTrue(app.buttons["selection-actions"].isEnabled)
        XCTAssertEqual(row(named: "Tap the completion circle", in: app).value as? String, "Not Done")
        app.buttons["finish-selecting"].tap()
    }

    func testRowSwipeShowsAVisibleDestructiveDeleteAction() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Swipe this", in: app)

        let snip = row(named: "Swipe this", in: app)
        let start = snip.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = snip.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)

        let delete = app.buttons["delete-snip"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        let screenshot = delete.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Revealed row delete action"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(
            containsSemanticRedAction(screenshot.image),
            "The revealed Delete action did not render with its red semantic tint."
        )
    }

    func testRowSwipeShowsAVisibleGreenDoneAction() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Finish this", in: app)

        let snip = row(named: "Finish this", in: app)
        let start = snip.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let end = snip.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)

        let done = app.buttons["done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        XCTAssertEqual(done.label, "Done")
        let screenshot = done.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Revealed row Done action"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(
            containsSemanticGreenAction(screenshot.image),
            "The revealed Done action did not render with its green semantic tint."
        )
    }

    func testLocalAttachmentsPreviewRemoveAndSurviveRelaunch() {
        continueAfterFailure = false
        let storeName = "attachments-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName, withAttachments: true)

        let compactPreview = app.buttons["compact-attachment-preview-sample.png"]
        XCTAssertTrue(compactPreview.waitForExistence(timeout: 5))
        compactPreview.tap()
        let compactQuickLook = app.otherElements["QLPreviewControllerView"]
        XCTAssertTrue(compactQuickLook.waitForExistence(timeout: 5))
        dismissQuickLook(compactQuickLook, in: app)
        XCTAssertFalse(compactQuickLook.waitForExistence(timeout: 3))

        openAttachmentFixture(in: app)
        let imagePreview = app.buttons["attachment-row-sample.png"]
        XCTAssertTrue(imagePreview.waitForExistence(timeout: 5))
        let textPreview = app.buttons["attachment-row-notes.txt"]
        XCTAssertTrue(textPreview.waitForExistence(timeout: 3))
        imagePreview.tap()
        let preview = app.otherElements["QLPreviewControllerView"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        dismissQuickLook(preview, in: app)
        XCTAssertFalse(preview.waitForExistence(timeout: 3))

        let imageRow = app.buttons["attachment-row-sample.png"]
        XCTAssertTrue(imageRow.waitForExistence(timeout: 3))
        let removeAttachment = app.buttons["remove-attachment-sample.png"]
        XCTAssertTrue(removeAttachment.waitForExistence(timeout: 3))
        removeAttachment.tap()
        XCTAssertTrue(
            imageRow.waitForNonExistence(timeout: 3),
            "The editor did not remove the attachment before saving."
        )
        let save = app.buttons["save-snip"]
        save.tap()
        XCTAssertTrue(
            save.waitForNonExistence(timeout: 8),
            "The attachment edit did not finish saving."
        )
        let savedRow = row(named: "Attachment fixture", in: app)
        XCTAssertTrue(savedRow.label.contains("notes.txt"))
        XCTAssertFalse(savedRow.label.contains("sample.png"))

        app.terminate()
        app = launchApp(storeName: storeName, withAttachments: true)
        openAttachmentFixture(in: app)
        XCTAssertTrue(app.buttons["attachment-row-notes.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["attachment-row-sample.png"].exists)
    }

    func testNativePickerAddReplacePreviewAndSaveWhenFixturesAreSeeded() throws {
        guard ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_PICKER_FIXTURES"] == "1"
        else {
            throw XCTSkip("Seed attachment-one.txt and attachment-two.txt in local Files to run.")
        }
        continueAfterFailure = false
        let app = launchApp(storeName: "picker-manual-\(UUID().uuidString)")
        let composer = app.descendants(matching: .any)["composer-text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Picker flow")

        app.buttons["composer-add-attachments"].tap()
        pickFile(named: "attachment-one.txt", in: app, confirmsSelection: true)
        let added = app.buttons["composer-attachment-attachment-one.txt"]
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        added.tap()
        let preview = app.otherElements["QLPreviewControllerView"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        dismissQuickLook(preview, in: app)
        XCTAssertFalse(preview.waitForExistence(timeout: 3))

        app.buttons["composer-remove-attachment-attachment-one.txt"].tap()
        app.buttons["composer-add-attachments"].tap()
        pickFile(named: "attachment-two.txt", in: app, confirmsSelection: false)
        XCTAssertTrue(
            app.buttons["composer-attachment-attachment-two.txt"].waitForExistence(timeout: 5)
        )
        app.buttons["composer-send"].tap()
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
            if preview.waitForNonExistence(timeout: 3) {
                return
            }
        }

        preview.tap()
        if let visibleButton = candidates.first(where: { $0.waitForExistence(timeout: 2) }) {
            visibleButton.tap()
            if preview.waitForNonExistence(timeout: 3) {
                return
            }
        }

        preview.swipeDown()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
    }

    private func openAttachmentFixture(in app: XCUIApplication) {
        let fixtureRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Attachment fixture")
        ).firstMatch
        XCTAssertTrue(fixtureRow.waitForExistence(timeout: 5))
        fixtureRow.press(forDuration: 1)
        let editAttachments = app.buttons["edit-snip"]
        XCTAssertTrue(editAttachments.waitForExistence(timeout: 3))
        editAttachments.tap()
        XCTAssertTrue(app.textViews["snip-text"].waitForExistence(timeout: 3))
    }

    private func openCopyShareFixture(matching text: String, in app: XCUIApplication) {
        if app.navigationBars["Snip"].exists, app.buttons["BackButton"].exists {
            app.buttons["BackButton"].tap()
        }
        let fixture = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", text)
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5))
        fixture.press(forDuration: 1)
    }

    private func chooseDetailAction(_ identifier: String, in app: XCUIApplication) {
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        action.tap()
    }

    private func assertCopyStatus(_ label: String, in app: XCUIApplication) {
        let status = app.descendants(matching: .any)
            .matching(identifier: "app-toast")
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3))
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
        shareAppName = app.label
        return app
    }

    private func shareURLFromSafari(token: String) -> XCUIApplication {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        guard let fixtureURL = URL(string: "http://127.0.0.1:58493/#\(token)") else {
            XCTFail("The fixed Share fixture URL is invalid.")
            return safari
        }
        safari.open(fixtureURL)
        let fixture = safari.staticTexts["Snip Snap Share Fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 15))
        let close = safari.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 2) {
            close.tap()
        }
        var share = safari.buttons["Share"].firstMatch
        if !share.waitForExistence(timeout: 3) {
            let more = safari.buttons["More"].firstMatch
            XCTAssertTrue(
                more.waitForExistence(timeout: 5),
                "Safari did not expose its Share button or More menu."
            )
            more.tap()
            share = safari.buttons["Share"].firstMatch
        }
        if !share.waitForExistence(timeout: 12) {
            let more = safari.buttons["More"].firstMatch
            if more.waitForExistence(timeout: 2) {
                more.tap()
            }
        }
        XCTAssertTrue(
            share.waitForExistence(timeout: 12),
            "Safari did not expose Share after retrying its menu."
        )
        share.tap()
        let activity = safari.cells[shareAppName]
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

    func testSearchFromClipboardFindsSnipsAcrossLists() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Alpha inbox", in: app)
        createList("Work", in: app)
        createSnip("Alpha work", in: app)
        returnToCollection(in: app)
        let selector = app.descendants(matching: .any)["list-selector"]
        if selector.exists {
            // Clipboard is offscreen when Work is centered; use the visible picker.
            let start = selector.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            start.press(
                forDuration: 0.05,
                thenDragTo: start.withOffset(CGVector(dx: 260, dy: 0)),
                withVelocity: XCUIGestureVelocity(rawValue: 100),
                thenHoldForDuration: 0.3
            )
        } else {
            app.buttons["clipboard-tab"].tap()
        }
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        let search = openSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertEqual(search.placeholderValue, "Search All")
        XCTAssertTrue(app.descendants(matching: .any)["search-prompt"].exists)
        search.typeText("Alpha")
        XCTAssertTrue(row(named: "Alpha inbox", in: app).isHittable)
        XCTAssertTrue(row(named: "Alpha work", in: app).isHittable)
        XCTAssertTrue(app.staticTexts["Inbox"].exists)
        XCTAssertTrue(app.staticTexts["Work"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
        closeSearch(in: app)
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["list-selector"].exists)
    }

    func testSearchDoneFilter() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Alpha plan", in: app)
        returnToCollection(in: app)
        createSnip("Beta note", in: app)
        returnToCollection(in: app)

        XCTAssertTrue(app.buttons["workflow-options"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["library-actions"].exists)
        _ = openSearch(in: app)
        closeSearch(in: app)
        let search = openSearch(in: app)
        search.typeText("Alpha")
        let alphaResult = row(named: "Alpha plan", in: app)
        XCTAssertTrue(alphaResult.isHittable, "A matching search result should be usable.")
        XCTAssertFalse(collectionRow(named: "Beta note", in: app).exists)
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        } else {
            search.typeText("\n")
        }
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3))
        let workflowOptions = app.buttons["workflow-options"]
        if !workflowOptions.waitForExistence(timeout: 1) {
            closeSearch(in: app)
        }
        XCTAssertTrue(workflowOptions.waitForExistence(timeout: 3))

        let alpha = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Alpha plan")
        ).firstMatch
        alpha.swipeRight()
        if app.buttons["done"].exists {
            app.buttons["done"].tap()
        }
        let becameDone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Done"),
            object: alpha
        )
        XCTAssertEqual(XCTWaiter.wait(for: [becameDone], timeout: 3), .completed)
        workflowOptions.tap()
        app.buttons["filter-done"].tap()
        XCTAssertTrue(collectionRow(named: "Alpha plan", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(collectionRow(named: "Beta note", in: app).exists)

    }

    func testMergesSelectedSnips() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("First merge note", in: app)
        createSnip("Second merge note", in: app)
        enterSelection(in: app)
        row(named: "First merge note", in: app).tap()
        row(named: "Second merge note", in: app).tap()
        app.buttons["selection-actions"].tap()
        XCTAssertTrue(app.buttons["merge-selection"].waitForExistence(timeout: 3))
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "iOS Merge Snips menu"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["merge-selection"].tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
        let merged = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "snip-"))
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged.firstMatch.label.contains("First merge note"))
        XCTAssertTrue(merged.firstMatch.label.contains("Second merge note"))
    }

    func testSelectionFilterClearsHiddenItems() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Filter this selection", in: app)
        enterSelection(in: app)
        row(named: "Filter this selection", in: app).tap()
        XCTAssertTrue(app.buttons["selection-actions"].isEnabled)

        app.buttons["workflow-options"].tap()
        app.buttons["filter-done"].tap()
        XCTAssertFalse(app.buttons["selection-actions"].isEnabled)
        XCTAssertTrue(app.buttons["finish-selecting"].exists)
        app.buttons["workflow-options"].tap()
        app.buttons["filter-all"].tap()
        XCTAssertTrue(row(named: "Filter this selection", in: app).exists)
        XCTAssertFalse(app.buttons["selection-actions"].isEnabled)
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
    }

    func testLongPressSelectsItemAndShowsSeparateClose() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Select this note", in: app)
        createSnip("Leave this note", in: app)

        row(named: "Select this note", in: app).press(forDuration: 1)
        XCTAssertTrue(app.buttons["select-snip"].waitForExistence(timeout: 3))
        let menuProof = XCTAttachment(screenshot: app.screenshot())
        menuProof.name = "Long press with Select"
        menuProof.lifetime = .keepAlways
        add(menuProof)
        app.buttons["select-snip"].tap()
        XCTAssertTrue(app.buttons["finish-selecting"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["library-actions"].exists)
        XCTAssertTrue(app.buttons["workflow-options"].exists)
        XCTAssertEqual(app.buttons["finish-selecting"].label, "Finish Selecting")
        XCTAssertTrue(app.buttons["selection-actions"].isEnabled)
        let selectionProof = XCTAttachment(screenshot: app.screenshot())
        selectionProof.name = "Selection with separate close"
        selectionProof.lifetime = .keepAlways
        add(selectionProof)

        app.buttons["selection-actions"].tap()
        app.buttons["mark-selection-done"].tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
        XCTAssertEqual(row(named: "Select this note", in: app).value as? String, "Done")
        XCTAssertEqual(row(named: "Leave this note", in: app).value as? String, "Not Done")

        enterSelection(in: app)
        XCTAssertTrue(app.buttons["finish-selecting"].exists)
        XCTAssertFalse(app.buttons["selection-actions"].isEnabled)
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["selection-actions"].exists)
    }

    func testDragReordersAndPersistsWithoutSelection() {
        continueAfterFailure = false
        let storeName = "reorder-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName)
        createSnip("First drag sample", in: app)
        createSnip("Second drag sample", in: app)
        let first = row(named: "First drag sample", in: app)
        let second = row(named: "Second drag sample", in: app)
        XCTAssertFalse(app.buttons["selection-actions"].exists)
        XCTAssertLessThan(second.frame.minY, first.frame.minY)

        app.buttons["workflow-options"].tap()
        app.buttons["reorder-snips"].tap()
        XCTAssertFalse(app.buttons["selection-actions"].exists)
        app.buttons["Reorder Second drag sample"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.3,
            thenDragTo: app.buttons["Reorder First drag sample"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
        )
        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in first.frame.minY < second.frame.minY },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Direct drag reordered snips"
        proof.lifetime = .keepAlways
        add(proof)

        app.buttons["finish-reordering"].tap()
        app.terminate()
        app = launchApp(storeName: storeName)
        let restoredFirst = row(named: "First drag sample", in: app)
        let restoredSecond = row(named: "Second drag sample", in: app)
        XCTAssertTrue(restoredFirst.waitForExistence(timeout: 3))
        XCTAssertLessThan(restoredFirst.frame.minY, restoredSecond.frame.minY)
        XCTAssertFalse(app.buttons["Reorder First drag sample"].exists)
        restoredFirst.press(forDuration: 1)
        XCTAssertTrue(app.buttons["edit-snip"].waitForExistence(timeout: 3))
        let menuProof = XCTAttachment(screenshot: app.screenshot())
        menuProof.name = "Item menu after direct drag"
        menuProof.lifetime = .keepAlways
        add(menuProof)
    }

    func testSelectsManyMovesThemAndChangesManualOrder() {
        continueAfterFailure = false
        let app = launchApp()
        createList("Work", in: app)
        returnToLists(in: app)
        listControl(named: "Inbox", in: app).tap()
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
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(app.staticTexts["One"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Two"].waitForExistence(timeout: 3))
        let one = row(named: "One", in: app)
        let two = row(named: "Two", in: app)
        app.buttons["workflow-options"].tap()
        app.buttons["reorder-snips"].tap()
        app.buttons["Reorder One"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.3,
            thenDragTo: app.buttons["Reorder Two"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
        )
        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in one.frame.minY < two.frame.minY },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed)
    }

    func testChangingListsEndsSelection() {
        continueAfterFailure = false
        let app = launchApp()
        createList("Work", in: app)
        returnToLists(in: app)
        listControl(named: "Inbox", in: app).tap()
        createSnip("Selected note", in: app)
        returnToCollection(in: app)

        enterSelection(in: app)
        row(named: "Selected note", in: app).tap()
        XCTAssertTrue(app.buttons["selection-actions"].waitForExistence(timeout: 3))

        let workList = listControl(named: "Work", in: app)
        if !workList.exists { returnToLists(in: app) }
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(app.buttons["selection-actions"].waitForNonExistence(timeout: 3))
    }

    private func createSnip(_ text: String, in app: XCUIApplication) {
        let composer = app.descendants(matching: .any)["composer-text"]
        if composer.waitForExistence(timeout: 1) {
            composer.tap()
            composer.typeText(text)
            let send = app.buttons["composer-send"]
            XCTAssertTrue(send.isEnabled)
            send.tap()
        } else {
            app.buttons["new-snip"].tap()
            let editor = app.textViews["snip-text"]
            XCTAssertTrue(editor.waitForExistence(timeout: 3))
            editor.tap()
            editor.typeText(text)
            app.buttons["save-snip"].tap()
        }
        XCTAssertTrue(collectionRow(named: text, in: app).waitForExistence(timeout: 3))
    }

    private func openSearch(in app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields["Search All"]
        if !field.exists {
            let button = app.buttons["Search"]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        return field
    }

    private func closeSearch(in app: XCUIApplication) {
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Cancel Search", "close"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
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

    private func requireCompactSelector(in app: XCUIApplication) throws {
        guard app.descendants(matching: .any)["list-selector"].waitForExistence(timeout: 3) else {
            throw XCTSkip("The compact selector is limited to iPhone.")
        }
    }

    private func openListEditor(named name: String, in app: XCUIApplication) {
        openListActions(named: name, in: app)
        let edit = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Edit List")
        ).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
    }

    private func openListActions(named name: String, in app: XCUIApplication) {
        let sidebarList = app.buttons["list-\(name)"]
        if sidebarList.exists {
            sidebarList.press(forDuration: 1)
        } else {
            compactListTab(named: name, in: app).tap()
        }
    }

    private func listControl(named name: String, in app: XCUIApplication) -> XCUIElement {
        let sidebarList = app.buttons["list-\(name)"]
        if sidebarList.exists { return sidebarList }
        return compactListTab(named: name, in: app)
    }

    private func compactListTab(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "list-tab-",
                name
            )
        ).firstMatch
    }

    private func enterSelection(in app: XCUIApplication) {
        let actions = app.buttons["library-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        let select = app.buttons["select-snips"]
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        select.tap()
        let selectionActions = app.buttons["selection-actions"]
        XCTAssertTrue(selectionActions.waitForExistence(timeout: 5))
    }

    private func openSettings(in app: XCUIApplication) {
        let actions = app.buttons["library-actions"]
        for _ in 0..<3 where !actions.waitForExistence(timeout: 1) {
            if app.buttons["Show Sidebar"].exists {
                app.buttons["Show Sidebar"].tap()
            } else if app.buttons["BackButton"].exists {
                app.buttons["BackButton"].tap()
            } else if app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let settings = app.buttons["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
    }

    private func toggle(_ element: XCUIElement) {
        let control = element.switches.firstMatch
        if control.exists {
            control.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
    }

    private func createList(_ name: String, in app: XCUIApplication) {
        openNewList(in: app)
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

    private func openNewList(in app: XCUIApplication) {
        returnToLists(in: app)
        if app.buttons["new-list"].exists {
            app.buttons["new-list"].tap()
            return
        }
        let selected = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'list-tab-' AND selected == true")
        ).firstMatch
        selected.tap()
        XCTAssertTrue(app.menuItems["New List"].waitForExistence(timeout: 3))
        app.menuItems["New List"].tap()
    }

    private func returnToLists(in app: XCUIApplication) {
        returnToCollection(in: app)
        if app.descendants(matching: .any)["list-selector"].exists { return }
        if !app.buttons["new-list"].exists {
            if app.buttons["Show Sidebar"].exists {
                app.buttons["Show Sidebar"].tap()
            } else if app.buttons["BackButton"].exists {
                app.buttons["BackButton"].tap()
            }
        }
        XCTAssertTrue(app.buttons["new-list"].waitForExistence(timeout: 3))
    }

}

private func containsSemanticRedAction(_ image: UIImage) -> Bool {
    semanticColorRatio(in: image) { red, green, blue in
        red > 180 && green < 120 && blue < 120
    }.map { $0 > 0.20 } ?? false
}

private func containsSemanticGreenAction(_ image: UIImage) -> Bool {
    semanticColorRatio(in: image) { red, green, blue in
        red < 140 && green > 120 && blue < 160
    }.map { $0 > 0.20 } ?? false
}

private func semanticColorRatio(
    in image: UIImage,
    matches: (UInt8, UInt8, UInt8) -> Bool
) -> Double? {
    guard let cgImage = image.cgImage else { return nil }
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var matchingPixels = 0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        if matches(pixels[offset], pixels[offset + 1], pixels[offset + 2]),
           pixels[offset + 3] > 245 {
            matchingPixels += 1
        }
    }
    return Double(matchingPixels) / Double(width * height)
}
