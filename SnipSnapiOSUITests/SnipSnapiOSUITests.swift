import UIKit
import XCTest

@MainActor
final class SnipSnapiOSUITests: XCTestCase {
    private var shareAppName = ""

    override func tearDown() {
        if XCUIDevice.shared.orientation != .portrait {
            XCUIDevice.shared.orientation = .portrait
        }
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
        withLongList: Bool = false,
        withGatheringFixtures: Bool = false,
        withClipboardEntry: Bool = false,
        syncIssue: String? = nil,
        contentSizeCategory: UIContentSizeCategory? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SNIP_SNAP_UI_TESTING"] = "1"
        if withHapticsTrace { app.launchEnvironment["SNIP_SNAP_UI_TEST_HAPTICS"] = "1" }
        if withLongList { app.launchEnvironment["SNIP_SNAP_UI_TEST_LONG_LIST"] = "1" }
        if withGatheringFixtures { app.launchEnvironment["SNIP_SNAP_UI_TEST_GATHERING"] = "1" }
        if withClipboardEntry { app.launchEnvironment["SNIP_SNAP_UI_TEST_CLIPBOARD_ENTRY"] = "1" }
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

    func testLongSnipExpandsAndCollapsesWithoutEditing() {
        continueAfterFailure = false
        let app = launchApp()
        let text = "First line\nSecond line\nThird line\nFourth line\nLast line of the snip"
        let composer = app.descendants(matching: .any)["composer-text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText(text)
        app.buttons["composer-send"].tap()
        let disclosure = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "snip-text-")
        ).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        XCTAssertEqual(disclosure.value as? String, "Collapsed")
        let collapsedHeight = disclosure.frame.height

        disclosure.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Expanded"), object: disclosure
        )], timeout: 3), .completed)
        XCTAssertGreaterThan(disclosure.frame.height, collapsedHeight)
        XCTAssertFalse(app.descendants(matching: .any)["inline-snip-text"].exists)

        disclosure.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Collapsed"), object: disclosure
        )], timeout: 3), .completed)
        XCTAssertEqual(disclosure.frame.height, collapsedHeight, accuracy: 1)

        disclosure.doubleTap()
        XCTAssertTrue(app.descendants(matching: .any)["inline-snip-text"].waitForExistence(timeout: 3))
    }

    func testContextActionsPublishHapticOutcomes() {
        continueAfterFailure = false
        let app = launchApp(withHapticsTrace: true)
        func expectHaptic(_ kind: String) {
            let trace = app.staticTexts["haptic-event"]
            let expected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label BEGINSWITH %@", kind + ":"), object: trace
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 4), .completed)
        }
        createSnip("Menu feedback", in: app)
        expectHaptic("saved")
        let menuRow = row(named: "Menu feedback", in: app)
        menuRow.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.2)).tap()
        expectHaptic("markedDone")
        menuRow.press(forDuration: 1)
        app.buttons["copy-snip"].tap()
        expectHaptic("copied")
        menuRow.press(forDuration: 1)
        app.buttons["delete-context-snip"].tap()
        XCTAssertTrue(menuRow.waitForNonExistence(timeout: 4))
        expectHaptic("deleted")
    }

    func testListSwipeSwitchesListsFromAVisibleRow() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        createSnip("Work page note", in: app)
        let workRow = row(named: "Work page note", in: app)
        XCTAssertEqual(workRow.value as? String, "Not Done")

        let start = workRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0)),
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        XCTAssertTrue(app.navigationBars["Work"].exists)
        XCTAssertTrue(workRow.exists)

        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        createSnip("Inbox page note", in: app)
        let inboxRow = row(named: "Inbox page note", in: app)
        let back = inboxRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        back.press(forDuration: 0.05, thenDragTo: back.withOffset(CGVector(dx: -180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        XCTAssertEqual(row(named: "Work page note", in: app).value as? String, "Not Done")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "List swipe from row content"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testListSwipeSwitchesEmptyListsFromContent() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        XCTAssertTrue(app.navigationBars["Work"].exists)
        XCTAssertTrue(app.staticTexts["empty-snips"].exists)

        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 160, dy: 0)))
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))

        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: -160, dy: 0)))
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
    }

    func testPageSwipeMovesBetweenInboxAndClipboard() throws {
        continueAfterFailure = false
        let app = launchApp(withClipboardEntry: true)
        try requireCompactSelector(in: app)
        createSnip("Inbox page note", in: app)

        let inboxRow = row(named: "Inbox page note", in: app)
        let toClipboard = inboxRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        toClipboard.press(forDuration: 0.05, thenDragTo: toClipboard.withOffset(CGVector(dx: 180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["clipboard-tab"].isSelected)
        let clipboardProof = XCTAttachment(screenshot: app.screenshot())
        clipboardProof.name = "Clipboard reached by page swipe"
        clipboardProof.lifetime = .keepAlways
        add(clipboardProof)

        let entry = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "clipboard-entry-")
        ).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        let entryY = (entry.frame.midY - app.frame.minY) / app.frame.height
        let toInbox = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: entryY))
        toInbox.press(forDuration: 0.05, thenDragTo: toInbox.withOffset(CGVector(dx: -180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(row(named: "Inbox page note", in: app).exists)
        let inboxProof = XCTAttachment(screenshot: app.screenshot())
        inboxProof.name = "Inbox reached from Clipboard row"
        inboxProof.lifetime = .keepAlways
        add(inboxProof)
    }

    func testPageSwipeReachesClipboardFromScreenEdge() throws {
        continueAfterFailure = false
        let app = launchApp(withClipboardEntry: true)
        try requireCompactSelector(in: app)

        let fromLeftEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.55))
        fromLeftEdge.press(forDuration: 0.05, thenDragTo: fromLeftEdge.withOffset(CGVector(dx: 180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))

        let fromRightEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.55))
        fromRightEdge.press(forDuration: 0.05, thenDragTo: fromRightEdge.withOffset(CGVector(dx: -180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
    }

    func testTrailingPagePullCreatesListAfterLongPull() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55))

        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: -100, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(app.navigationBars["Inbox"].exists)
        XCTAssertFalse(app.textFields["list-name"].exists)

        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: -250, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
        let cancel = app.buttons["cancel-new-list"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertFalse(compactListTab(named: "New List", in: app).exists)
    }

    func testSwipingBackFromNewListEditorCancelsTheList() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: -250, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 4))

        let back = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.45))
        back.press(forDuration: 0.05, thenDragTo: back.withOffset(CGVector(dx: 80, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.textFields["list-name"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)

        back.press(forDuration: 0.05, thenDragTo: back.withOffset(CGVector(dx: 220, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertFalse(compactListTab(named: "New List", in: app).exists)
    }

    func testClipboardHidesSavedListActionsOnIPad() throws {
        continueAfterFailure = false
        let app = launchApp()
        if app.descendants(matching: .any)["list-selector"].exists {
            throw XCTSkip("The sidebar is limited to regular-width iPad.")
        }
        createList("Work", in: app)
        let clipboard = app.buttons["clipboard-sidebar"]
        XCTAssertTrue(clipboard.waitForExistence(timeout: 3))
        clipboard.tap()
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(clipboard.isSelected)

        let actions = app.navigationBars["Lists"].buttons["library-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        XCTAssertFalse(app.buttons["select-snips"].exists)
        XCTAssertFalse(app.menuItems["Edit List…"].exists)
        XCTAssertFalse(app.menuItems["Delete List"].exists)
        XCTAssertTrue(app.buttons["settings"].exists)
    }

    func testLastSnipCanScrollAboveCompactControls() throws {
        continueAfterFailure = false
        let app = launchApp(withLongList: true)
        try requireCompactSelector(in: app)
        let oldest = collectionRow(named: "Fixture oldest", in: app)
        let composer = app.descendants(matching: .any)["composer-text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        let newest = collectionRow(named: "Fixture 23", in: app)
        XCTAssertTrue(newest.isHittable)
        let edgeStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.70))
            .withOffset(CGVector(dx: 8, dy: 0))
        edgeStart.press(forDuration: 0.05, thenDragTo: edgeStart.withOffset(CGVector(dx: 0, dy: -320)))
        XCTAssertFalse(newest.exists, "Vertical scrolling must work from the edge")
        for _ in 0..<12 where !oldest.isHittable || oldest.frame.maxY > composer.frame.minY {
            app.swipeUp()
        }
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Scrolled to final snip"
        proof.lifetime = .keepAlways
        add(proof)
        XCTAssertTrue(oldest.isHittable, "The final snip must be reachable by scrolling")
        XCTAssertLessThanOrEqual(oldest.frame.maxY, composer.frame.minY)
    }

    func testVerticalScrollFromRowCenterDoesNotSwitchLists() throws {
        continueAfterFailure = false
        let app = launchApp(withLongList: true)
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        compactListTab(named: "Inbox", in: app).tap()

        let newest = collectionRow(named: "Fixture 23", in: app)
        let lowerRow = collectionRow(named: "Fixture 17", in: app)
        XCTAssertTrue(newest.isHittable)
        XCTAssertTrue(lowerRow.isHittable)
        let start = lowerRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 25, dy: -300)))

        XCTAssertFalse(newest.exists, "Vertical scrolling must work from row content")
        XCTAssertTrue(app.navigationBars["Inbox"].exists)
    }

    func testHorizontalEndPullDoesNotScrollLongListVertically() throws {
        continueAfterFailure = false
        let app = launchApp(withLongList: true)
        try requireCompactSelector(in: app)
        let newest = collectionRow(named: "Fixture 23", in: app)
        let lowerRow = collectionRow(named: "Fixture 17", in: app)
        XCTAssertTrue(newest.isHittable)
        XCTAssertTrue(lowerRow.isHittable)
        let initialY = newest.frame.minY

        let start = lowerRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: -140, dy: -75)),
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )

        XCTAssertTrue(app.navigationBars["Inbox"].exists)
        XCTAssertEqual(newest.frame.minY, initialY, accuracy: 3,
                       "A horizontal page pull must own the gesture until finger lift")
    }

    func testEdgeSwipeDoesNotDiscardInlineSnipDraft() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        createSnip("Keep draft", in: app)
        row(named: "Keep draft", in: app).doubleTap()
        let editor = app.descendants(matching: .any)["inline-snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText(" unsaved")
        app.swipeDown()
        let draft = editor.value as? String

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.45))
            .withOffset(CGVector(dx: 8, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 130, dy: 0)))
        XCTAssertTrue(app.navigationBars["Work"].exists)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, draft)
    }

    func testEdgeSwipeDoesNotLeaveFocusedComposer() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        let composer = app.descendants(matching: .any)["composer-text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("Unsent edge draft")

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.45))
            .withOffset(CGVector(dx: 8, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 130, dy: 0)))

        XCTAssertTrue(app.navigationBars["Work"].exists)
        XCTAssertEqual(composer.value as? String, "Unsent edge draft")
    }

    func testLandscapeScreenEdgeSwipeSwitchesLists() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        let body = app.staticTexts["empty-snips"]
        XCTAssertTrue(body.waitForExistence(timeout: 3))
        let start = body.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.3))
            .withOffset(CGVector(dx: 8, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
    }

    func testScreenEdgeSwipeDoesNotSwitchBehindAttachmentPreview() throws {
        continueAfterFailure = false
        let app = launchApp(withAttachments: true)
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        compactListTab(named: "Inbox", in: app).tap()
        let preview = app.buttons["compact-attachment-preview-sample.png"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        let image = app.images["Image preview"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.45))
            .withOffset(CGVector(dx: -8, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -130, dy: 0)))
        XCTAssertTrue(image.exists)
        app.buttons["dismiss-attachment-image"].tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
    }

    func testUnavailableListSwipeKeepsRowContextActionsAvailable() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        createSnip("Last list row action", in: app)
        let occupiedRow = row(named: "Last list row action", in: app)
        let start = occupiedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -130, dy: 0)))

        XCTAssertTrue(app.navigationBars["Work"].exists)
        XCTAssertEqual(occupiedRow.value as? String, "Not Done")
        occupiedRow.press(forDuration: 1)
        XCTAssertTrue(app.buttons["delete-context-snip"].waitForExistence(timeout: 3))
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

    func testSettingsOffersPrivacySafeDiagnosticLogActions() {
        continueAfterFailure = false
        let app = launchApp()
        openSettings(in: app)

        let diagnostics = app.buttons["diagnostics"]
        for _ in 0..<3 where !diagnostics.exists { app.swipeUp() }
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["share-diagnostic-log"].exists)
        diagnostics.tap()

        let share = app.buttons["share-diagnostic-log"]
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["clear-diagnostic-log"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "not your content or file names"
        )).firstMatch.exists)
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

        let sync = app.switches["icloud-sync-toggle"]
        XCTAssertTrue(sync.waitForExistence(timeout: 3))
        XCTAssertEqual(sync.value as? String, "0")
        XCTAssertFalse(app.staticTexts["Sync off"].exists)
        toggle(sync)
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: sync)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.staticTexts["Sync on"].exists)
        XCTAssertTrue(app.switches["clipboard-sync-toggle"].isEnabled)
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

        XCTAssertTrue(app.staticTexts["Couldn’t set up sync"].waitForExistence(timeout: 8))
        let firstDetail = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "over-limit-a.bin")
        ).firstMatch
        let secondDetail = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "over-limit-b.bin")
        ).firstMatch
        XCTAssertTrue(firstDetail.waitForExistence(timeout: 3))
        XCTAssertTrue(secondDetail.waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["icloud-sync-toggle"].exists)
        XCTAssertFalse(app.staticTexts["Sync on"].exists)
    }

    func testInternalSyncIssueUsesCalmCopyWithoutRawErrorCodes() {
        continueAfterFailure = false
        let app = launchApp(withSyncedContent: true, syncIssue: "app-data")

        openSettings(in: app)

        XCTAssertTrue(app.staticTexts["Couldn’t sync"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["retry-icloud-sync"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "CloudRecordError")
        ).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "error 2")
        ).firstMatch.exists)
    }

    func testTurningSyncOffKeepsTheLibraryWithoutCloudDeletionControls() {
        continueAfterFailure = false
        let app = launchApp(withSyncEnable: true)
        openSettings(in: app)
        let initialSync = app.switches["icloud-sync-toggle"]
        XCTAssertTrue(initialSync.waitForExistence(timeout: 3))
        toggle(initialSync)
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: initialSync)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.switches["clipboard-sync-toggle"].isEnabled)
        app.buttons["Done"].tap()
        createSnip("Keep this", in: app)
        let saved = collectionRow(named: "Keep this", in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
        openSettings(in: app)

        let sync = app.switches["icloud-sync-toggle"]
        XCTAssertTrue(sync.waitForExistence(timeout: 3))
        XCTAssertEqual(sync.value as? String, "1")
        XCTAssertFalse(app.buttons["delete-synced-content"].exists)
        toggle(sync)

        let staleCopyAlert = app.alerts["Turn off sync?"]
        if staleCopyAlert.waitForExistence(timeout: 3) {
            staleCopyAlert.buttons["Turn off sync"].tap()
        }

        expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: sync)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.staticTexts["Sync off"].exists)
        let clipboardSync = app.switches["clipboard-sync-toggle"]
        XCTAssertEqual(clipboardSync.value as? String, "0")
        XCTAssertFalse(clipboardSync.isEnabled)
        XCTAssertFalse(app.buttons["delete-synced-content"].exists)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "iCloud sync off keeps a local copy"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["Done"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
    }

    func testClipboardSyncConsentExplainsPreviouslySyncedFiles() {
        continueAfterFailure = false
        let app = launchApp(withSyncedContent: true)
        openSettings(in: app)
        let clipboardSync = app.switches["clipboard-sync-toggle"]
        XCTAssertTrue(clipboardSync.waitForExistence(timeout: 3))
        if clipboardSync.value as? String == "1" { toggle(clipboardSync) }
        toggle(clipboardSync)
        let alert = app.alerts["Sync clipboard history?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Files that have synced"
        )).firstMatch.exists)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "across your devices"
        )).firstMatch.exists)
        alert.buttons["Cancel"].tap()
        XCTAssertEqual(clipboardSync.value as? String, "0")
    }

    func testSettingsKeepsNormalSyncQuietWithoutCloudDeletionControls() {
        continueAfterFailure = false
        let app = launchApp(withSyncedContent: true)
        openSettings(in: app)

        let sync = app.switches["icloud-sync-toggle"]
        XCTAssertTrue(sync.waitForExistence(timeout: 3))
        XCTAssertEqual(sync.value as? String, "1")
        XCTAssertFalse(app.staticTexts["Sync on"].exists)
        XCTAssertFalse(app.staticTexts["sync-status"].exists)
        XCTAssertFalse(app.buttons["delete-synced-content"].exists)
        XCTAssertFalse(app.buttons["retry-icloud-sync"].exists)
        XCTAssertFalse(app.buttons["sync-icloud-now"].exists)
        XCTAssertFalse(app.buttons["clear-icloud-downloads"].exists)
        XCTAssertTrue(app.buttons["create-backup"].exists)
        XCTAssertTrue(app.buttons["import-backup"].exists)
    }

    func testEncryptedDataResetTurnsSyncOffWithoutOfferingARecoveryUpload() {
        continueAfterFailure = false
        let app = launchApp(withSyncedContent: true, withEncryptedReset: true)
        openSettings(in: app)

        XCTAssertTrue(app.staticTexts["Sync turned off"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.navigationBars["Recovered snip"].waitForExistence(timeout: 3))
        app.buttons["Use recovered"].tap()

        XCTAssertTrue(app.navigationBars["Needs attention"].waitForExistence(timeout: 3))
        let recoveredList = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Recovered Notes")
        ).firstMatch
        XCTAssertTrue(recoveredList.waitForExistence(timeout: 3))
        recoveredList.tap()
        XCTAssertTrue(app.navigationBars["Recovered list"].waitForExistence(timeout: 3))
        app.buttons["Use recovered"].tap()
        XCTAssertTrue(app.navigationBars["Needs attention"].waitForExistence(timeout: 3))
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

        compactListTab(named: "Inbox", in: app).press(forDuration: 0.7)
        let manager = app.descendants(matching: .any)["list-management-panel"]
        XCTAssertTrue(manager.waitForExistence(timeout: 3))
        let keepFrame = app.buttons["keep-account-cache"].frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: keepFrame.midX, dy: keepFrame.midY)).tap()
        XCTAssertTrue(manager.waitForNonExistence(timeout: 3))
        XCTAssertTrue(notice.exists, "The backdrop must shield the account choice as it dismisses.")
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

        let snipSnap = shareActivityCell(in: app)
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

    func testSharePageShowsEveryListThenSaves() {
        continueAfterFailure = false
        let originalAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .light
        defer { XCUIDevice.shared.appearance = originalAppearance }
        let app = XCUIApplication()
        app.launch()
        shareAppName = app.label
        let suffix = String(UUID().uuidString.prefix(4))
        let work = "Work \(suffix)"
        let reading = "Reading \(suffix)"
        createList(work, color: "red", in: app)
        createList(reading, in: app)

        let token = "share-page-check-\(UUID().uuidString)"
        let safari = shareURLFromSafari(token: token)
        let sharedText = safari.textViews["share-text"]
        XCTAssertTrue(
            sharedText.waitForExistence(timeout: 10),
            "Share page did not open: \(safari.debugDescription)"
        )
        XCTAssertFalse(safari.otherElements["share-error"].exists)
        XCTAssertFalse(safari.descendants(matching: .any)["share-destination-picker"].exists)

        let page = XCTAttachment(screenshot: safari.screenshot())
        page.name = "Share page saves into a list"
        page.lifetime = .keepAlways
        add(page)

        let picker = safari.descendants(matching: .any)["share-list-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let options = safari.descendants(matching: .any)
        for listName in ["Inbox", work, reading] {
            XCTAssertTrue(
                options.matching(NSPredicate(format: "label == %@", listName)).firstMatch
                    .waitForExistence(timeout: 5),
                "\(listName) is missing from the share picker: \(safari.debugDescription)"
            )
        }
        let pickerList = safari.collectionViews.containing(
            .button,
            identifier: "tray.fill"
        ).firstMatch
        XCTAssertTrue(
            pickerList.waitForExistence(timeout: 5),
            "The list picker did not open: \(safari.debugDescription)"
        )
        XCTAssertFalse(
            pickerList.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Clipboard"))
                .firstMatch
                .exists
        )

        let pickerProof = XCTAttachment(screenshot: safari.screenshot())
        pickerProof.name = "Share page list picker shows every list"
        pickerProof.lifetime = .keepAlways
        add(pickerProof)

        options.matching(NSPredicate(format: "label == %@", work)).firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        let colorProof = XCTAttachment(screenshot: safari.screenshot())
        colorProof.name = "Share page commits in the destination list color"
        colorProof.lifetime = .keepAlways
        add(colorProof)

        XCUIDevice.shared.appearance = .dark
        Thread.sleep(forTimeInterval: 2)
        let darkProof = XCTAttachment(screenshot: safari.screenshot())
        darkProof.name = "Share page in dark mode"
        darkProof.lifetime = .keepAlways
        add(darkProof)
        XCUIDevice.shared.appearance = .light

        assertShareExtensionReportedLocalSave(in: safari)

        app.activate()
        let workList = listControl(named: work, in: app)
        XCTAssertTrue(workList.waitForExistence(timeout: 10))
        workList.tap()
        let saved = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", token)
        ).firstMatch
        XCTAssertTrue(
            saved.waitForExistence(timeout: 10),
            "The shared snip did not land in \(work): \(app.debugDescription)"
        )
        revealCompactList(named: "Inbox", in: app)
        let inbox = compactListTab(named: "Inbox", in: app)
        XCTAssertGreaterThanOrEqual(
            inbox.frame.minX,
            0,
            "Inbox stayed off screen at \(inbox.frame)"
        )
        inbox.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(
            for: NSPredicate(format: "selected == true"),
            evaluatedWith: inbox
        )
        waitForExpectations(timeout: 5)
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", token)).firstMatch.exists,
            "The shared snip also appeared in Inbox."
        )
    }

    private func shareActivityCell(in host: XCUIApplication) -> XCUIElement {
        let named = host.cells.matching(
            NSPredicate(format: "label == %@ OR label == %@", shareAppName, "Save to \(shareAppName)")
        ).firstMatch
        if !(named.exists && named.isHittable) {
            let more = host.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "View More")
            ).firstMatch
            if more.exists && more.isHittable {
                more.tap()
            }
        }
        for _ in 0..<6 where !(named.exists && named.isHittable) {
            scrollShareApps(in: host, towardLeft: true)
        }
        for _ in 0..<6 where !(named.exists && named.isHittable) {
            scrollShareApps(in: host, towardLeft: false)
        }
        if !(named.exists && named.isHittable) {
            let hierarchy = XCTAttachment(string: "Expected activity: \(shareAppName) or Save to \(shareAppName)\n" + host.debugDescription)
            hierarchy.name = "Share activity hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: host.screenshot())
            screenshot.name = "Share activity discovery failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        return named
    }

    private func scrollShareApps(in host: XCUIApplication, towardLeft: Bool) {
        let row = host.cells.matching(identifier: "shareCell")
        guard row.count > 1 else { return }
        let anchor = row.element(boundBy: 1)
        if towardLeft {
            anchor.swipeLeft()
        } else {
            anchor.swipeRight()
        }
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
        let copied = collectionRow(named: "Copy unavailable fixture", in: app)
        let done = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Done"), object: copied
        )
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 3), .completed)

        let composer = app.descendants(matching: .any)["composer-text"].firstMatch
        composer.tap()
        composer.press(forDuration: 1)
        app.menuItems["Paste"].tap()
        XCTAssertEqual(composer.value as? String, "Copy unavailable fixture")
    }

    func testContextEditUsesInlineDraftAndPreservesAttachmentsOnCancel() {
        continueAfterFailure = false
        let storeName = "inline-edit-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName, withCopyShareFixtures: true)
        let original = row(named: "Copy mixed fixture", in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.press(forDuration: 1)
        app.buttons["edit-snip"].tap()

        let editor = app.descendants(matching: .any)["inline-snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Edit Snip"].exists)
        app.buttons["remove-attachment-sample.png"].tap()
        editor.tap()
        editor.typeText(" discarded")
        app.buttons["inline-snip-cancel"].tap()

        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["compact-attachment-preview-sample.png"].exists)
        original.press(forDuration: 1)
        app.buttons["edit-snip"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Copy mixed fixture")
        XCTAssertTrue(app.buttons["remove-attachment-sample.png"].exists)
        editor.tap()
        editor.typeText(" saved")
        app.buttons["inline-snip-save"].tap()
        XCTAssertTrue(row(named: "Copy mixed fixture saved", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["compact-attachment-preview-sample.png"].exists)
        app.terminate()
        app = launchApp(storeName: storeName, withCopyShareFixtures: true)
        XCTAssertTrue(row(named: "Copy mixed fixture saved", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["compact-attachment-preview-sample.png"].exists)
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
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        editor.typeText(" unsaved")
        let draft = "Inline draft unsaved"
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", draft), object: editor
        )], timeout: 5), .completed, "Actual text: \(String(describing: editor.value))")
        app.swipeDown()

        let search = openSearch(in: app)
        search.typeText("Missing entry")
        closeSearch(in: app)

        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, draft)

        let matchingSearch = openSearch(in: app)
        matchingSearch.typeText("Inline draft")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, draft)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        editor.typeText(" from search")
        let sharedDraft = "Inline draft unsaved from search"
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", sharedDraft), object: editor
        )], timeout: 5), .completed, "Actual text: \(String(describing: editor.value))")
        app.descendants(matching: .any)["global-search-results"].swipeDown()
        closeSearch(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, sharedDraft)
        app.buttons["inline-snip-save"].tap()
        let saved = row(named: "Inline draft unsaved from search", in: app)
        enterSelection(in: app)
        saved.tap()
        XCTAssertTrue(app.buttons["selection-actions"].isEnabled)
        let selectionSearch = openSearch(in: app)
        selectionSearch.typeText("Inline draft")
        let result = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "search-snip-"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.doubleTap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        app.descendants(matching: .any)["global-search-results"].swipeDown()
        closeSearch(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["selection-actions"].exists)
        app.buttons["inline-snip-cancel"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
    }

    func testSearchEditReopensInItsOriginalListWithoutDiscardingDraft() {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)
        createList("Work", in: app)
        let search = openSearch(in: app)
        search.typeText("Copy mixed fixture")
        let result = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "search-snip-", "Copy mixed fixture"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.doubleTap()
        let editor = app.descendants(matching: .any)["inline-snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        app.buttons["remove-attachment-sample.png"].tap()
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        editor.typeText(" unsaved")
        let text = "Copy mixed fixture unsaved"
        XCTAssertEqual(editor.value as? String, text)
        app.descendants(matching: .any)["global-search-results"].swipeDown()
        closeSearch(in: app)

        listControl(named: "Inbox", in: app).tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, text)
        XCTAssertFalse(app.buttons["remove-attachment-sample.png"].exists)
        app.buttons["inline-snip-save"].tap()
        let saved = row(named: text, in: app)
        saved.doubleTap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, text)
        XCTAssertFalse(app.buttons["remove-attachment-sample.png"].exists)
        app.buttons["inline-snip-cancel"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
    }

    func testQuickComposerLongPressSendsToAnotherListAndPreservesItsDraft() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        let composer = app.descendants(matching: .any)["composer-text"]
        composer.tap()
        composer.typeText("Work draft to keep")
        XCTAssertTrue(compactListTab(named: "Inbox", in: app).waitForNonExistence(timeout: 3))
        dismissComposerKeyboard(in: app)
        XCTAssertTrue(compactListTab(named: "Inbox", in: app).waitForExistence(timeout: 3))
        compactListTab(named: "Inbox", in: app).tap()
        composer.tap()
        composer.typeText("Sent to Work from Inbox")

        let send = app.buttons["composer-send"]
        let initialSendFrame = send.frame
        send.press(forDuration: 1)
        let picker = app.descendants(matching: .any)["composer-send-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertLessThan(picker.frame.width, 240, "Short list names should use a compact menu.")
        let cancelButtons = app.buttons.matching(identifier: "composer-send-dismiss")
        let cancel = cancelButtons.firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertEqual(cancelButtons.count, 1)
        XCTAssertEqual(cancel.label, "Cancel Send to List")
        XCTAssertFalse(send.exists)
        XCTAssertEqual(cancel.frame.minX, initialSendFrame.minX, accuracy: 1)
        XCTAssertEqual(cancel.frame.minY, initialSendFrame.minY, accuracy: 1)
        XCTAssertEqual(cancel.frame.width, initialSendFrame.width, accuracy: 1)
        XCTAssertEqual(cancel.frame.height, initialSendFrame.height, accuracy: 1)
        let destination = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "composer-send-to-", "Work"
        )).firstMatch
        let currentDestination = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "composer-send-to-", "Inbox"
        )).firstMatch
        XCTAssertTrue(currentDestination.waitForExistence(timeout: 3))
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        // The modal container includes Cancel; measure the last visible menu row.
        XCTAssertLessThanOrEqual(destination.frame.maxY, cancel.frame.minY - 4)
        XCTAssertFalse(collectionRow(named: "Sent to Work from Inbox", in: app).exists)
        cancel.tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 3))
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
        XCTAssertTrue(destination.waitForNonExistence(timeout: 3))
        XCTAssertTrue(currentDestination.waitForNonExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Sent to Work from Inbox")
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        let restoredHierarchy = XCTAttachment(string: app.debugDescription)
        restoredHierarchy.name = "Send hierarchy after Cancel"
        restoredHierarchy.lifetime = .keepAlways
        add(restoredHierarchy)
        XCTAssertEqual(send.frame.minX, initialSendFrame.minX, accuracy: 1)
        XCTAssertEqual(send.frame.minY, initialSendFrame.minY, accuracy: 1)
        XCTAssertEqual(send.frame.width, initialSendFrame.width, accuracy: 1)
        XCTAssertEqual(send.frame.height, initialSendFrame.height, accuracy: 1)
        let collapsedProof = XCTAttachment(screenshot: app.screenshot())
        collapsedProof.name = "Send button before morph"
        collapsedProof.lifetime = .keepAlways
        add(collapsedProof)
        send.press(forDuration: 1)
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Long press Send list destinations"
        proof.lifetime = .keepAlways
        add(proof)
        destination.tap()

        XCTAssertTrue(app.navigationBars["Inbox"].exists)
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == false"), object: send
        )
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
        XCTAssertFalse(collectionRow(named: "Sent to Work from Inbox", in: app).exists)
        dismissComposerKeyboard(in: app)
        XCTAssertTrue(compactListTab(named: "Work", in: app).waitForExistence(timeout: 3))
        compactListTab(named: "Work", in: app).tap()
        XCTAssertTrue(row(named: "Sent to Work from Inbox", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Work draft to keep")

        app.terminate()
        app.launch()
        if !compactListTab(named: "Work", in: app).isSelected {
            compactListTab(named: "Work", in: app).tap()
        }
        XCTAssertTrue(row(named: "Sent to Work from Inbox", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Work draft to keep")
        send.tap()
        XCTAssertTrue(row(named: "Work draft to keep", in: app).waitForExistence(timeout: 5))
        compactListTab(named: "Inbox", in: app).tap()
        XCTAssertEqual(composer.value as? String, "")
        XCTAssertEqual(composer.label, "Add to Inbox…")
        XCTAssertFalse(send.isEnabled)

        composer.tap()
        composer.typeText("Sent to Inbox from its own menu")
        send.press(forDuration: 1)
        XCTAssertTrue(currentDestination.waitForExistence(timeout: 3))
        XCTAssertTrue(destination.exists)
        currentDestination.tap()
        XCTAssertTrue(app.navigationBars["Inbox"].exists)
        XCTAssertTrue(row(named: "Sent to Inbox from its own menu", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "")
        XCTAssertEqual(composer.label, "Add to Inbox…")
        XCTAssertFalse(send.isEnabled)
    }

    func testQuickComposerDestinationsWrapLongListNames() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        let name = "Research and planning for upcoming projects and shared team decisions"
        createList(name, in: app)
        let composer = app.descendants(matching: .any)["composer-text"]
        composer.tap()
        composer.typeText("Long name destination")
        app.buttons["composer-send"].press(forDuration: 1)
        let picker = app.descendants(matching: .any)["composer-send-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(picker.frame.width, 264)
        XCTAssertGreaterThanOrEqual(picker.frame.minX, 0)
        let destination = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "composer-send-to-", name
        )).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(destination.frame.height, 44, "Long names should wrap into a taller row.")
        XCTAssertLessThanOrEqual(destination.frame.maxY, picker.frame.maxY)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Long list name wraps in capped destination picker"
        proof.lifetime = .keepAlways
        add(proof)
        destination.tap()
        XCTAssertTrue(row(named: "Long name destination", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "")
        XCTAssertEqual(composer.label, "Add to \(name)…")
    }

    func testQuickComposerSendsWithoutOpeningTheEditor() throws {
        continueAfterFailure = false
        let app = launchApp()
        let composer = app.descendants(matching: .any)["composer-text"]
        let addAttachments = app.buttons["composer-add-attachments"]
        let send = app.buttons["composer-send"]
        let compactInbox = compactListTab(named: "Inbox", in: app)
        let usesCompactSelector = compactInbox.exists
        let newList = usesCompactSelector ? compactInbox : app.buttons["new-list"]

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
        if usesCompactSelector {
            XCTAssertFalse(newList.exists)
        } else {
            XCTAssertTrue(newList.exists)
        }
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

    func testAttachmentAddMenuOffersFilesAndPhotos() {
        continueAfterFailure = false
        let app = launchApp(withAttachments: true)
        app.buttons["composer-add-attachments"].tap()
        XCTAssertTrue(app.buttons["Choose Files"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Choose Photos"].firstMatch.exists)
    }

    func testPhotoPickerStagesAChosenImage() throws {
        continueAfterFailure = false
        let app = launchApp()
        app.buttons["composer-add-attachments"].tap()
        app.buttons["Choose Photos"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 5))
        let firstPhoto = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard firstPhoto.waitForExistence(timeout: 5) else {
            throw XCTSkip("Seed one image in the test Simulator's Photos library to run.")
        }
        // The system Photos picker exposes grid images but does not report them as hittable.
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        let attachment = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "composer-attachment-Photo."
        )).firstMatch
        XCTAssertTrue(attachment.waitForExistence(timeout: 8))
        attachment.tap()
        let image = app.images["Image preview"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        app.buttons["dismiss-attachment-image"].tap()
        XCTAssertTrue(image.waitForNonExistence(timeout: 3))
    }

    func testEditorKeepsStagedPhotoWhenPhotoPickerIsCancelled() throws {
        continueAfterFailure = false
        let storeName = "staged-photo-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName, withAttachments: true)
        let search = openSearch(in: app)
        search.typeText("Attachment fixture")
        let searchResult = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "search-snip-"
        )).firstMatch
        XCTAssertTrue(searchResult.waitForExistence(timeout: 5))
        searchResult.tap()
        XCTAssertTrue(app.descendants(matching: .any)["inline-snip-text"].waitForExistence(timeout: 5))
        app.buttons["add-attachments"].tap()
        app.buttons["Choose Photos"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 5))
        let firstPhoto = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard firstPhoto.waitForExistence(timeout: 5) else {
            throw XCTSkip("Seed one image in the test Simulator's Photos library to run.")
        }
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        let staged = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "attachment-row-Photo."
        )).firstMatch
        XCTAssertTrue(staged.waitForExistence(timeout: 8))

        let replace = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "replace-attachment-Photo."
        )).firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 5))
        replace.tap()
        app.buttons["Choose Photos"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.09, dy: 0.12)).tap()
        XCTAssertTrue(staged.waitForExistence(timeout: 5))
        app.buttons["inline-snip-save"].tap()
        XCTAssertTrue(app.buttons["inline-snip-save"].waitForNonExistence(timeout: 8))

        app.terminate()
        app = launchApp(storeName: storeName, withAttachments: true)
        openAttachmentFixture(in: app)
        XCTAssertTrue(staged.waitForExistence(timeout: 5))
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

    func testComposerPastesCopiedPhotoSnipAsAttachment() {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)
        let source = row(named: "Copy mixed fixture", in: app)
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.press(forDuration: 1)
        app.buttons["copy-snip"].tap()
        let composer = app.descendants(matching: .any)["composer-text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.press(forDuration: 1)
        let paste = app.cells["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()

        let attachment = app.buttons["composer-attachment-sample.png"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Copy mixed fixture")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Copied photo snip pasted into composer"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testLeadingPasteSavesToSelectedListWithoutChangingDraft() throws {
        continueAfterFailure = false
        let app = launchApp()
        let paste = app.buttons["paste-to-clipboard"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        XCTAssertTrue(paste.isHittable)
        XCTAssertTrue(paste.isEnabled)

        let composer = app.descendants(matching: .any)["composer-text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("Quick paste fixture")
        app.buttons["composer-send"].tap()
        row(named: "Quick paste fixture", in: app).press(forDuration: 1)
        app.buttons["copy-snip"].tap()
        createList("Work", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("Prefix: ")
        XCTAssertTrue(paste.waitForNonExistence(timeout: 3))
        dismissComposerKeyboard(in: app)
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        XCTAssertTrue(paste.isHittable)
        paste.tap()
        XCTAssertTrue(row(named: "Quick paste fixture", in: app).exists)
        XCTAssertEqual(composer.value as? String, "Prefix: ")
        XCTAssertFalse(collectionRow(named: "Prefix: Quick paste fixture", in: app).exists)

        listControl(named: "Inbox", in: app).tap()
        XCTAssertFalse(collectionRow(named: "Prefix: Quick paste fixture", in: app).exists)
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(row(named: "Quick paste fixture", in: app).exists)
        XCTAssertEqual(composer.value as? String, "Prefix: ")
        XCTAssertTrue(paste.isHittable)
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

    func testClipboardContextMenuKeepsPinAndDeleteAvailable() throws {
        continueAfterFailure = false
        let app = launchApp(withClipboardEntry: true)
        try requireCompactSelector(in: app)
        app.buttons["clipboard-tab"].tap()

        let entry = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "clipboard-entry-")
        ).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.press(forDuration: 1)
        app.buttons["Pin"].tap()
        XCTAssertEqual(entry.value as? String, "Pinned")
        entry.press(forDuration: 1)
        app.buttons["Unpin"].tap()
        entry.press(forDuration: 1)
        app.buttons["Delete"].tap()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 3))
    }

    func testClipboardUsesListScreenControls() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        let restingSelector = app.descendants(matching: .any)["list-selector"].frame
        let restingSelectorWidth = restingSelector.width
        XCTAssertEqual(restingSelector.midX, app.frame.midX, accuracy: 2)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Search'")).count, 1)
        XCTAssertFalse(app.searchFields["Search"].exists)
        app.buttons["clipboard-tab"].tap()
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.searchFields["Search"].exists || app.buttons["Search"].exists)
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
        XCTAssertEqual(search.placeholderValue, "Search")
        search.typeText("Missing entry")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 3))
        closeSearch(in: app)
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.searchFields["Search"].waitForNonExistence(timeout: 3))
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
        XCTAssertTrue(compactListTab(named: "Inbox", in: app).isSelected)
        XCTAssertTrue(paste.isEnabled)
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
        app.buttons["list-management-new"].tap()
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
        XCTAssertTrue(compactListTab(named: "Inbox", in: app).isSelected)
        XCTAssertTrue(app.buttons["paste-to-clipboard"].isEnabled)
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

    func testTabDragKeepsEachListsContentDraftAndContextActions() throws {
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
        workRow.press(forDuration: 1)
        app.buttons["Pin"].tap()
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
        XCTAssertFalse(app.searchFields["Search"].exists)
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
            thenDragTo: edge.withOffset(CGVector(dx: -175, dy: 0)),
            withVelocity: XCUIGestureVelocity(rawValue: 40),
            thenHoldForDuration: 1
        )
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["composer-text"].exists)
        XCTAssertTrue(app.buttons["cancel-new-list"].exists)
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

    func testSelectorPullFromClipboardCreatesList() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        let clipboard = app.buttons["clipboard-tab"]
        clipboard.tap()
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))

        let edge = app.descendants(matching: .any)["list-selector"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
        edge.press(
            forDuration: 0.05,
            thenDragTo: edge.withOffset(CGVector(dx: -min(300, edge.screenPoint.x - 4), dy: 0)),
            withVelocity: XCUIGestureVelocity(rawValue: 40),
            thenHoldForDuration: 0.8
        )
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
    }

    func testSelectorDeleteListKeepsItsSnips() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", color: "blue", in: app)
        createSnip("Keep this note", in: app)
        createList("Travel", color: "violet", in: app)
        createSnip("Keep the travel note", in: app)
        let work = compactListTab(named: "Work", in: app)
        work.tap()
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        work.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["Delete Travel"].waitForExistence(timeout: 3))
        let managerProof = XCTAttachment(screenshot: app.screenshot())
        managerProof.name = "Colored list titles and leading reorder handles"
        managerProof.lifetime = .keepAlways
        add(managerProof)
        app.buttons["Delete Travel"].tap()
        let travelDialog = app.alerts["Delete Travel?"]
        XCTAssertTrue(travelDialog.waitForExistence(timeout: 3))
        travelDialog.buttons["Cancel"].tap()
        XCTAssertTrue(compactListTab(named: "Travel", in: app).exists)
        app.buttons["Delete Travel"].tap()
        XCTAssertTrue(travelDialog.waitForExistence(timeout: 3))
        let dialogProof = XCTAttachment(screenshot: app.screenshot())
        dialogProof.name = "Centered list deletion dialog"
        dialogProof.lifetime = .keepAlways
        add(dialogProof)
        travelDialog.buttons["Delete List"].tap()
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3), "Deleting another list must preserve the current page.")
        XCTAssertTrue(work.isSelected)
        XCTAssertFalse(compactListTab(named: "Travel", in: app).exists)
        work.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["Delete Work"].waitForExistence(timeout: 3))
        app.buttons["Delete Work"].tap()
        XCTAssertTrue(app.alerts["Delete Work?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["The snips in this list will move to Inbox."].waitForExistence(timeout: 3))
        app.buttons["Delete List"].tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(row(named: "Keep this note", in: app).exists)
        XCTAssertTrue(row(named: "Keep the travel note", in: app).exists)
        XCTAssertFalse(work.exists)
    }

    func testSelectorLongPressReordersListsAndHidesWhileEditing() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        for name in ["Work", "Travel", "Reading"] { createList(name, in: app) }
        let readingTab = compactListTab(named: "Reading", in: app)
        let workTab = compactListTab(named: "Work", in: app)
        let readingID = String(readingTab.identifier.dropFirst("list-tab-".count))
        let workID = String(workTab.identifier.dropFirst("list-tab-".count))
        readingTab.press(forDuration: 0.7)
        let close = app.buttons["list-management-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        let reading = app.buttons["list-management-select-" + readingID]
        let work = app.buttons["list-management-select-" + workID]
        let source = app.cells.containing(.button, identifier: reading.identifier).firstMatch
        let destination = app.cells.containing(.button, identifier: work.identifier).firstMatch
        XCTAssertTrue(source.exists)
        XCTAssertTrue(destination.exists)
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo:
                destination.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.1)))
        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in reading.frame.minY < work.frame.minY }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 4), .completed)
        XCTAssertTrue(close.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Glass manager after dragging Reading before Work"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        readingTab.press(forDuration: 0.7)
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        app.buttons["list-management-edit-" + readingID].tap()
        let name = app.textFields["list-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText(" draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
        XCTAssertEqual(name.value as? String, "Reading draft")
        app.buttons["save-list"].tap()
        XCTAssertTrue(app.navigationBars["Reading draft"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        let renamedTab = compactListTab(named: "Reading draft", in: app)
        XCTAssertTrue(renamedTab.waitForExistence(timeout: 3))
        renamedTab.press(forDuration: 0.7)
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Edit Reading draft"].exists)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
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
        last.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["list-management-new"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Edit A long list name for later"].exists)
        XCTAssertTrue(app.buttons["Delete A long list name for later"].exists)
        let panelScreenshot = XCTAttachment(screenshot: app.screenshot())
        panelScreenshot.name = "Floating glass list manager"
        panelScreenshot.lifetime = .keepAlways
        add(panelScreenshot)
        app.buttons["list-management-new"].tap()
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

    func testNewListFromClipboardWithSeveralListsCanCancelBackToClipboard() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        for name in ["Work", "Travel", "Reading"] {
            createList(name, in: app)
        }
        func swipeToPreviousPage(_ expectedTitle: String) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 180, dy: 0)))
            XCTAssertTrue(app.navigationBars[expectedTitle].waitForExistence(timeout: 3))
        }
        for title in ["Travel", "Work", "Inbox", "Clipboard"] {
            swipeToPreviousPage(title)
        }
        let clipboard = app.descendants(matching: .any)["clipboard-tab"]
        XCTAssertTrue(clipboard.waitForExistence(timeout: 3))
        clipboard.tap()
        let newList = app.buttons["list-management-new"]
        XCTAssertTrue(newList.waitForExistence(timeout: 3))
        newList.tap()
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
        app.buttons["cancel-new-list"].tap()
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertFalse(compactListTab(named: "New List", in: app).exists)
    }

    func testTrailingPagePullCreatesListAfterEditingAnotherPage() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        createList("Travel", in: app)
        openListEditor(named: "Work", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["list-name"].value as? String, "Work")
        app.buttons["save-list"].tap()
        XCTAssertTrue(app.textFields["list-name"].waitForNonExistence(timeout: 3))
        let nextPage = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7))
        nextPage.press(forDuration: 0.05, thenDragTo: nextPage.withOffset(CGVector(dx: -180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Travel"].waitForExistence(timeout: 3))

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.55))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: -240, dy: 0)),
            withVelocity: XCUIGestureVelocity(rawValue: 40),
            thenHoldForDuration: 0.4
        )

        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
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

    func testNewListNameCollisionStillOpensEditorAndExplainsRenameConflict() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        openNewList(in: app)
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 3))
        app.buttons["save-list"].tap()
        XCTAssertTrue(app.navigationBars["New List"].waitForExistence(timeout: 3))

        openNewList(in: app)
        let field = app.textFields["list-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
        let createButtonHeight = app.buttons["save-list"].frame.height
        XCTAssertGreaterThanOrEqual(createButtonHeight, 44)
        XCTAssertLessThanOrEqual(createButtonHeight, 50)
        let editor = XCTAttachment(screenshot: app.screenshot())
        editor.name = "Add List with an existing New List"
        editor.lifetime = .keepAlways
        add(editor)

        field.tap()
        field.typeText("New List")
        app.buttons["save-list"].tap()
        let alert = app.alerts["Name Already Used"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts["A list with that name already exists. Choose another name."].exists)
        let error = XCTAttachment(screenshot: app.screenshot())
        error.name = "Clear duplicate list name error"
        error.lifetime = .keepAlways
        add(error)
        alert.buttons["OK"].tap()
        XCTAssertTrue(field.exists)
        XCTAssertEqual(field.value as? String, "New List")
        field.tap()
        field.typeText(" for Work")
        app.buttons["save-list"].tap()
        XCTAssertTrue(app.navigationBars["New List for Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(compactListTab(named: "New List", in: app).exists)
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
        XCTAssertFalse(app.descendants(matching: .any)["composer-text"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
        XCTAssertTrue(app.buttons["cancel-new-list"].exists)
        field.typeText("Starred")
        let chooseIcon = app.segmentedControls["list-appearance-picker"].buttons["Icon"]
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
        XCTAssertTrue(app.descendants(matching: .any)["composer-text"].waitForExistence(timeout: 3))
    }

    func testLibraryControlsYieldToListEditingAndComposerKeyboard() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        let composer = app.descendants(matching: .any)["composer-text"]
        let selector = app.descendants(matching: .any)["list-selector"]
        composer.tap()
        composer.typeText("Keep this draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(selector.waitForNonExistence(timeout: 3))
        XCTAssertTrue(composer.isHittable)
        XCTAssertTrue(app.buttons["composer-send"].isHittable)
        let itemEntry = XCTAttachment(screenshot: app.screenshot())
        itemEntry.name = "Item entry without bottom navigation"
        itemEntry.lifetime = .keepAlways
        add(itemEntry)

        app.swipeDown()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(selector.waitForExistence(timeout: 3))
        openListEditor(named: "Work", in: app)
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 3))
        XCTAssertFalse(composer.exists)
        XCTAssertFalse(selector.exists)
        XCTAssertLessThanOrEqual(
            app.frame.maxY - app.buttons["save-list"].frame.maxY, 90,
            "An editor opened without a keyboard should fill the remaining screen."
        )
        let fullEditor = XCTAttachment(screenshot: app.screenshot())
        fullEditor.name = "List editor fills remaining space"
        fullEditor.lifetime = .keepAlways
        add(fullEditor)
        app.textFields["list-name"].tap()
        app.textFields["list-name"].typeText(" Unsaved")
        app.buttons["cancel-list-editing"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        XCTAssertTrue(selector.waitForExistence(timeout: 3))
        openListEditor(named: "Work", in: app)
        XCTAssertEqual(app.textFields["list-name"].value as? String, "Work")
        app.buttons["save-list"].tap()

        openNewList(in: app)
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 3))
        XCTAssertFalse(composer.exists)
        XCTAssertFalse(selector.exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let tabs = app.segmentedControls["list-appearance-picker"]
        tabs.buttons["Icon"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        tabs.buttons["Color"].tap()
        app.textFields["list-name"].typeText("Focus stays")
        XCTAssertEqual(app.textFields["list-name"].value as? String, "Focus stays")
        tabs.buttons["Icon"].tap()
        let search = app.textFields["list-icon-search"]
        search.typeText("star.fill")
        let star = app.buttons["list-icon-star.fill"].firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 3))
        XCTAssertTrue(star.isHittable)
        XCTAssertLessThanOrEqual(star.frame.maxY, app.buttons["save-list"].frame.minY)
        XCTAssertLessThanOrEqual(app.buttons["save-list"].frame.maxY, app.keyboards.firstMatch.frame.minY)
        let iconSearch = XCTAttachment(screenshot: app.screenshot())
        iconSearch.name = "New list icon search above keyboard"
        iconSearch.lifetime = .keepAlways
        add(iconSearch)
        let createFrameWithKeyboard = app.buttons["save-list"].frame
        let searchFrameWithKeyboard = search.frame
        search.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertGreaterThan(app.buttons["save-list"].frame.minY, createFrameWithKeyboard.minY + 100)
        XCTAssertLessThanOrEqual(app.frame.maxY - app.buttons["save-list"].frame.maxY, 90)
        let expandedEditor = XCTAttachment(screenshot: app.screenshot())
        expandedEditor.name = "New list expands after keyboard dismissal"
        expandedEditor.lifetime = .keepAlways
        add(expandedEditor)
        XCTAssertEqual(search.frame.minY, searchFrameWithKeyboard.minY, accuracy: 2)
        tabs.buttons["Color"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        tabs.buttons["Icon"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["cancel-new-list"].tap()
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        XCTAssertTrue(selector.waitForExistence(timeout: 3))
    }

    func testListEditorKeepsKeyboardFocusAcrossAccessibilityTabs() throws {
        continueAfterFailure = false
        let app = launchApp(contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        try requireCompactSelector(in: app)
        openNewList(in: app)
        let tabs = app.segmentedControls["list-appearance-picker"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        tabs.buttons["Icon"].tap()
        let search = app.textFields["list-icon-search"]
        search.typeText("circle")
        tabs.buttons["Color"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.textFields["list-name"].typeText("Focus stays")
        XCTAssertEqual(app.textFields["list-name"].value as? String, "Focus stays")
        tabs.buttons["Icon"].tap()
        search.typeText(".fill")
        XCTAssertEqual(search.value as? String, "circle.fill")
        XCTAssertTrue(app.buttons["save-list"].isHittable)
        XCTAssertLessThanOrEqual(app.buttons["save-list"].frame.maxY, app.keyboards.firstMatch.frame.minY)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Accessibility tab focus transfer"
        proof.lifetime = .keepAlways
        add(proof)
        search.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertLessThanOrEqual(app.frame.maxY - app.buttons["save-list"].frame.maxY, 110)
        app.buttons["cancel-new-list"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer-text"].waitForExistence(timeout: 3))
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
        let tabs = app.segmentedControls["list-appearance-picker"]
        let chooseIcon = tabs.buttons["Icon"]
        chooseIcon.tap()
        let search = app.textFields["list-icon-search"]
        search.tap()
        search.typeText("star.fill\n")
        let star = app.buttons["list-icon-star.fill"].firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        star.tap()

        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue(app.images["list-icon-preview"].label.contains("Star Fill"))
        XCTAssertEqual(field.value as? String, editedName)
        tabs.buttons["Color"].tap()
        XCTAssertTrue(app.buttons["list-color-blue"].isSelected)
        chooseIcon.tap()
        XCTAssertEqual(search.value as? String, "star.fill")
        XCTAssertTrue(star.isSelected)
        tabs.buttons["Color"].tap()
        app.buttons["save-list"].tap()

        let saved = listControl(named: editedName, in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        openListEditor(named: editedName, in: app)
        XCTAssertTrue(chooseIcon.waitForExistence(timeout: 3))
        XCTAssertTrue(app.images["list-icon-preview"].label.contains("Star Fill"))
        XCTAssertEqual(field.value as? String, editedName)
        XCTAssertTrue(app.buttons["list-color-blue"].isSelected)
    }

    func testListEditorShowsExpandedPaletteAndPersistsRed() throws {
        continueAfterFailure = false
        let app = launchApp()
        guard app.descendants(matching: .any)["composer-text"].waitForExistence(timeout: 5)
        else {
            throw XCTSkip("The compact list tabs are limited to iPhone.")
        }

        createList("Palette", in: app)
        openListEditor(named: "Palette", in: app)

        let colorIdentifiers = [
            "neutral", "red", "orange", "yellow", "green", "teal",
            "blue", "indigo", "violet", "pink", "clay", "slate",
        ]
        for identifier in colorIdentifiers {
            XCTAssertTrue(app.buttons["list-color-\(identifier)"].waitForExistence(timeout: 3))
        }

        let red = app.buttons["list-color-red"]
        red.tap()
        XCTAssertTrue(red.isSelected)
        app.buttons["save-list"].tap()

        openListEditor(named: "Palette", in: app)
        XCTAssertTrue(red.waitForExistence(timeout: 3))
        XCTAssertTrue(red.isSelected)

        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Expanded palette with Red selected"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testListEditorKeepsDraftAcrossAppearanceTabs() {
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

        XCTAssertFalse(app.descendants(matching: .any)["composer-text"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
        let tabs = app.segmentedControls["list-appearance-picker"]
        tabs.buttons["Icon"].tap()
        tabs.buttons["Color"].tap()

        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, editedName)
        XCTAssertTrue(app.buttons["list-color-blue"].isSelected)
        app.buttons["save-list"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["composer-text"].isHittable)
    }

    func testListEditorKeepsDraftAcrossRotation() {
        continueAfterFailure = false
        let app = launchApp()
        createList("Reading", in: app)
        openListEditor(named: "Reading", in: app)
        let field = app.textFields["list-name"]
        field.tap()
        field.typeText(" Notes")
        let editedName = field.value as? String
        app.buttons["list-color-blue"].tap()
        let tabs = app.segmentedControls["list-appearance-picker"]
        tabs.buttons["Icon"].tap()
        let search = app.textFields["list-icon-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.typeText("star\n")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertEqual(search.value as? String, "star")
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
        XCTAssertTrue(app.buttons["save-list"].isHittable)
        XCUIDevice.shared.orientation = .portrait
        tabs.buttons["Color"].tap()
        XCTAssertEqual(field.value as? String, editedName)
        XCTAssertTrue(app.buttons["list-color-blue"].isSelected)
        XCTAssertTrue(app.images["list-icon-preview"].label.contains("List Bullet"))
        app.buttons["save-list"].tap()
        XCTAssertTrue(app.navigationBars["Reading Notes"].waitForExistence(timeout: 3))
    }

    func testListEditorIconSearchKeepsControlsReachable() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchApp()
        createList("Reading", in: app)
        openListEditor(named: "Reading", in: app)
        app.segmentedControls["list-appearance-picker"].buttons["Icon"].tap()

        let search = app.textFields["list-icon-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("star")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.buttons["save-list"].isHittable)
        XCTAssertLessThanOrEqual(app.buttons["save-list"].frame.maxY, app.keyboards.firstMatch.frame.minY)
        search.typeText("\n")
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3))
        XCTAssertEqual(search.value as? String, "star")
        let results = app.scrollViews["list-icon-results"]
        let star = results.buttons["list-icon-star.fill"].firstMatch
        for _ in 0..<6 where !star.isHittable {
            results.swipeUp()
        }
        XCTAssertTrue(star.waitForExistence(timeout: 3))
        XCTAssertTrue(star.isHittable, "Filtered icons must be reachable in landscape.")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Landscape filtered Star icon"
        proof.lifetime = .keepAlways
        add(proof)
        star.tap()
        XCTAssertTrue(app.buttons["save-list"].isHittable)
        app.buttons["save-list"].tap()
        XCTAssertTrue(app.textFields["list-name"].waitForNonExistence(timeout: 3))
        openListEditor(named: "Reading", in: app)
        XCTAssertTrue(app.images["list-icon-preview"].label.contains("Star"))
    }

    func testLibraryActionsOfferSyncOnlyWhileICloudIsEnabled() {
        continueAfterFailure = false
        let app = launchApp(withSyncEnable: true)
        app.buttons["library-actions"].tap()
        XCTAssertFalse(app.buttons["sync-icloud"].exists)
        app.buttons["settings"].tap()
        let sync = app.switches["icloud-sync-toggle"]
        XCTAssertTrue(sync.waitForExistence(timeout: 3))
        toggle(sync)
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: sync)
        waitForExpectations(timeout: 8)
        app.buttons["Done"].tap()

        app.buttons["library-actions"].tap()
        let syncAction = app.buttons["sync-icloud"]
        XCTAssertTrue(syncAction.waitForExistence(timeout: 3))
        XCTAssertTrue(syncAction.isEnabled)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Sync in library actions"
        proof.lifetime = .keepAlways
        add(proof)
        syncAction.tap()
        app.buttons["clipboard-tab"].tap()
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        app.buttons["library-actions"].tap()
        XCTAssertTrue(syncAction.waitForExistence(timeout: 3))
        XCTAssertEqual(syncAction.label, "Sync")
        XCTAssertTrue(syncAction.isEnabled)
        syncAction.tap()

        openSettings(in: app)
        XCTAssertEqual(sync.value as? String, "1")
        toggle(sync)
        let staleCopy = app.alerts["Turn off sync?"]
        if staleCopy.waitForExistence(timeout: 2) {
            staleCopy.buttons["Turn off sync"].tap()
        }
        expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: sync)
        waitForExpectations(timeout: 8)
        app.buttons["Done"].tap()
        app.buttons["library-actions"].tap()
        XCTAssertFalse(syncAction.exists)
    }

    func testLibraryActionsKeepBackupsAndSyncMaintenanceInSettings() {
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
            actions = app.buttons["Library actions"]
        }

        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        XCTAssertFalse(app.buttons["Import backup…"].exists)
        XCTAssertFalse(app.buttons["sync-icloud-now"].exists)
        XCTAssertFalse(app.buttons["clear-icloud-downloads"].exists)
        XCTAssertFalse(app.buttons["Undo"].exists)
        XCTAssertFalse(app.buttons["Redo"].exists)
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["create-backup"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["import-backup"].exists)
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
        app.buttons["delete-context-snip"].tap()

        XCTAssertTrue(snip.waitForNonExistence(timeout: 3))
        let toast = app.descendants(matching: .any)["app-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertLessThan(toast.frame.width, app.frame.width - 48)
        XCTAssertLessThanOrEqual(toast.frame.height, 60)
        let composer = app.descendants(matching: .any)["composer-text"]
        XCTAssertLessThanOrEqual(
            toast.frame.maxY,
            composer.frame.minY
        )
        XCTAssertGreaterThanOrEqual(app.buttons["toast-action"].frame.height, 44)
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
        app.buttons["toast-action"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            .tap()
        XCTAssertTrue(row(named: "Undo this", in: app).waitForExistence(timeout: 3))
    }

    func testDeleteToastStaysAboveSearchToolbar() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Search after deleting", in: app)

        let snip = row(named: "Search after deleting", in: app)
        XCTAssertTrue(snip.waitForExistence(timeout: 3))
        snip.press(forDuration: 1)
        app.buttons["delete-context-snip"].tap()

        let toast = app.descendants(matching: .any)["app-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        app.buttons["Search"].tap()
        let search = app.searchFields["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertTrue(toast.exists)
        XCTAssertLessThanOrEqual(toast.frame.maxY, search.frame.minY)
        XCTAssertGreaterThanOrEqual(toast.frame.minY, 0)
        XCTAssertTrue(app.buttons["toast-action"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Delete toast beside active search"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["toast-action"].tap()
        closeSearch(in: app)
        XCTAssertTrue(row(named: "Search after deleting", in: app).waitForExistence(timeout: 3))
    }

    func testSearchDoesNotExtendDeleteUndoWindow() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Undo expires", in: app)

        let snip = row(named: "Undo expires", in: app)
        snip.press(forDuration: 1)
        app.buttons["delete-context-snip"].tap()
        let deletedAt = Date()

        let toast = app.descendants(matching: .any)["app-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields["Search"].waitForExistence(timeout: 3))
        XCTAssertTrue(toast.exists)
        let remaining = deletedAt.addingTimeInterval(7).timeIntervalSinceNow
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        XCTAssertFalse(toast.exists)
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
        XCTAssertTrue(collectionRow(named: "Tap the completion circle", in: app).waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "1 item")
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(collectionRow(named: "Tap the completion circle", in: app).waitForExistence(timeout: 3))
        XCTAssertEqual(row(named: "Tap the completion circle", in: app).value as? String, "Not Done")
    }

    func testAttachmentListImagePreviewAndSwipeDismiss() {
        continueAfterFailure = false
        let app = launchApp(withAttachments: true)
        let compactPreview = app.buttons["compact-attachment-preview-sample.png"]
        XCTAssertTrue(compactPreview.waitForExistence(timeout: 5))
        let rowProof = XCTAttachment(screenshot: app.screenshot())
        rowProof.name = "Attachment image preview in list"
        rowProof.lifetime = .keepAlways
        add(rowProof)
        compactPreview.tap()
        let fullScreenImage = app.images["Image preview"]
        XCTAssertTrue(fullScreenImage.waitForExistence(timeout: 5))
        let fullScreenProof = XCTAttachment(screenshot: app.screenshot())
        fullScreenProof.name = "Full-screen attachment image"
        fullScreenProof.lifetime = .keepAlways
        add(fullScreenProof)
        fullScreenImage.swipeDown()
        XCTAssertTrue(fullScreenImage.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["dismiss-attachment-image"].waitForNonExistence(timeout: 3))
    }

    func testLocalAttachmentsPreviewRemoveAndSurviveRelaunch() {
        continueAfterFailure = false
        let storeName = "attachments-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName, withAttachments: true)

        let compactPreview = app.buttons["compact-attachment-preview-sample.png"]
        XCTAssertTrue(compactPreview.waitForExistence(timeout: 5))
        compactPreview.tap()
        let fullScreenImage = app.images["Image preview"]
        XCTAssertTrue(fullScreenImage.waitForExistence(timeout: 5))
        app.buttons["dismiss-attachment-image"].tap()
        XCTAssertTrue(fullScreenImage.waitForNonExistence(timeout: 3))

        openAttachmentFixture(in: app)
        let imagePreview = app.buttons["attachment-row-sample.png"]
        XCTAssertTrue(imagePreview.waitForExistence(timeout: 5))
        let textPreview = app.buttons["attachment-row-notes.txt"]
        XCTAssertTrue(textPreview.waitForExistence(timeout: 3))
        imagePreview.tap()
        XCTAssertTrue(fullScreenImage.waitForExistence(timeout: 5))
        app.buttons["dismiss-attachment-image"].tap()
        XCTAssertTrue(fullScreenImage.waitForNonExistence(timeout: 3))

        textPreview.tap()
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
        let save = app.buttons["inline-snip-save"]
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
        app.buttons["Choose Files"].firstMatch.tap()
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
        app.buttons["Choose Files"].firstMatch.tap()
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
        XCTAssertTrue(app.descendants(matching: .any)["inline-snip-text"].waitForExistence(timeout: 3))
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
        let found = status.waitForExistence(timeout: 3)
        if !found {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Copy status lookup failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(found, "Expected the \(label) toast after copying.")
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
        XCTAssertTrue(
            shareText.waitForExistence(timeout: 8),
            "Safari found the \(shareAppName) activity, but its extension editor did not appear."
        )
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
        let activity = shareActivityCell(in: safari)
        XCTAssertTrue(
            activity.waitForExistence(timeout: 8),
            "Safari did not expose \(shareAppName) or Save to \(shareAppName)."
        )
        XCTAssertTrue(activity.isHittable, "The \(shareAppName) Share activity must be reachable.")
        activity.tap()
        return safari
    }

    private func assertShareExtensionReportedLocalSave(in safari: XCUIApplication) {
        let save = safari.buttons["share-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        XCTAssertTrue(
            safari.textViews["share-text"].waitForNonExistence(timeout: 8),
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
        let clipboard = app.buttons["clipboard-tab"]
        let selector = app.descendants(matching: .any)["list-selector"]
        if selector.exists {
            // Swipe directly from Work to Clipboard, which lies outside the strip.
            let start = selector.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            start.press(
                forDuration: 0.05,
                thenDragTo: start.withOffset(CGVector(dx: selector.frame.width, dy: 0))
            )
        } else {
            clipboard.tap()
        }
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(clipboard.isSelected)
        let search = openSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertEqual(search.placeholderValue, "Search")
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
        XCTAssertTrue(app.buttons["clipboard-tab"].isSelected)
    }

    func testSearchDoneFilter() {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)
        XCTAssertTrue(collectionRow(named: "Copy text fixture", in: app).waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["workflow-options"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["library-actions"].exists)
        _ = openSearch(in: app)
        closeSearch(in: app)
        let search = openSearch(in: app)
        search.typeText("Copy text")
        XCTAssertEqual(search.value as? String, "Copy text")
        let results = app.descendants(matching: .any)["global-search-results"]
        XCTAssertTrue(results.waitForExistence(timeout: 3))
        let matchingResult = results.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Copy text fixture")
        ).firstMatch
        XCTAssertTrue(matchingResult.waitForExistence(timeout: 3))
        XCTAssertTrue(matchingResult.isHittable, "A matching search result should be usable.")
        XCTAssertFalse(results.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Copy mixed fixture")
        ).firstMatch.exists)
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        } else {
            search.typeText("\n")
        }
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3))
        closeSearch(in: app)
        let workflowOptions = app.buttons["workflow-options"]
        XCTAssertTrue(workflowOptions.waitForExistence(timeout: 3))

        let copied = row(named: "Copy text fixture", in: app)
        copied.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "completion-")
        ).firstMatch.tap()
        let becameDone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Done"),
            object: copied
        )
        XCTAssertEqual(XCTWaiter.wait(for: [becameDone], timeout: 3), .completed)
        workflowOptions.tap()
        app.buttons["filter-done"].tap()
        XCTAssertTrue(collectionRow(named: "Copy text fixture", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(collectionRow(named: "Copy mixed fixture", in: app).exists)

    }

    func testGlassSelectionMenuShowsPinnedCompletionAsDisabled() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        let names = ["Sketch a simpler selection flow", "Try the stack interaction on iPhone"]
        for name in names {
            let snip = row(named: name, in: app)
            XCTAssertTrue(snip.waitForExistence(timeout: 5))
            snip.press(forDuration: 1)
            app.buttons["Pin"].tap()
        }
        enterSelection(in: app)
        for name in names { row(named: name, in: app).tap() }
        app.buttons["selection-actions"].tap()
        let markDone = app.buttons["mark-selection-done"]
        XCTAssertTrue(markDone.waitForExistence(timeout: 3))
        XCTAssertFalse(markDone.isEnabled)
        XCTAssertTrue(app.buttons["merge-selection"].isEnabled)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Shared glass disabled selection action"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testGlassSelectionMenuDismissesWithoutLosingGatheredSnips() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(compactListTab(named: "Archive", in: app).waitForExistence(timeout: 5))
        compactListTab(named: "Inbox", in: app).press(forDuration: 0.7)
        let manager = app.descendants(matching: .any)["list-management-panel"]
        XCTAssertTrue(manager.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Lists"].exists)
        XCTAssertFalse(app.staticTexts["Drag to reorder"].exists)
        XCTAssertTrue(app.buttons["Edit Work"].isHittable)
        let listProof = XCTAttachment(screenshot: app.screenshot())
        listProof.name = "Shared glass list manager"
        listProof.lifetime = .keepAlways
        add(listProof)
        app.buttons["list-management-close"].tap()
        XCTAssertTrue(manager.waitForNonExistence(timeout: 3))
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        app.buttons["selection-actions"].tap()
        let menu = app.descendants(matching: .any)["selection-actions-panel"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["merge-selection"].isHittable)
        XCTAssertGreaterThanOrEqual(menu.frame.minX, 0)
        XCTAssertLessThanOrEqual(menu.frame.maxX, app.frame.maxX)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Shared glass selection actions"
        proof.lifetime = .keepAlways
        add(proof)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["merge-selection"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["gathered-stack"].exists)
        XCTAssertTrue(app.buttons["selection-actions"].isEnabled)
        app.buttons["move-gathered"].tap()
        let moveMenu = app.descendants(matching: .any)["selection-move-panel"]
        XCTAssertTrue(moveMenu.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["move-gathered-to-Work"].isHittable)
        XCTAssertTrue(app.alerts["selection-move-panel"].exists, "The chooser should expose modal accessibility semantics.")
        let backgroundTrigger = app.buttons["selection-actions"].frame
        let moveProof = XCTAttachment(screenshot: app.screenshot())
        moveProof.name = "Shared glass move destinations"
        moveProof.lifetime = .keepAlways
        add(moveProof)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: backgroundTrigger.midX, dy: backgroundTrigger.midY)).tap()
        XCTAssertTrue(moveMenu.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["merge-selection"].exists, "A background tap should dismiss without also opening the action menu.")
        XCTAssertTrue(app.buttons["gathered-stack"].exists)
        app.buttons["selection-actions"].tap()
        XCTAssertTrue(app.buttons["mark-selection-done"].waitForExistence(timeout: 3))
        app.buttons["mark-selection-done"].tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 5))
        XCTAssertEqual(row(named: "Sketch a simpler selection flow", in: app).value as? String, "Done")
        XCTAssertEqual(row(named: "Try the stack interaction on iPhone", in: app).value as? String, "Done")
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

    func testSelectionSurvivesFilteringItsSourceRows() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Filter this selection", in: app)
        enterSelection(in: app)
        row(named: "Filter this selection", in: app).tap()
        XCTAssertTrue(app.buttons["selection-actions"].isEnabled)

        app.buttons["workflow-options"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["selection-actions"].isEnabled)
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "1 item")
        XCTAssertTrue(app.buttons["finish-selecting"].exists)
        app.buttons["workflow-options"].tap()
        app.buttons["All"].tap()
        XCTAssertFalse(collectionRow(named: "Filter this selection", in: app).exists)
        XCTAssertTrue(app.buttons["selection-actions"].isEnabled)
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
        XCTAssertEqual(app.buttons["finish-selecting"].label, "Cancel")
        XCTAssertTrue(app.buttons["selection-actions"].isEnabled)
        XCTAssertLessThan(app.buttons["finish-selecting"].frame.midX, app.frame.midX)
        XCTAssertGreaterThan(app.buttons["selection-actions"].frame.minY, app.buttons["gathered-stack"].frame.maxY)
        let selectionProof = XCTAttachment(screenshot: app.screenshot())
        selectionProof.name = "Gathering with leading cancel and container actions"
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

    func testLongPressAddsAnotherItemToExpandedSelection() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        let stack = app.buttons["gathered-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        stack.tap()
        XCTAssertTrue(app.scrollViews["gathered-contents"].waitForExistence(timeout: 3))

        row(named: "Try the stack interaction on iPhone", in: app).press(forDuration: 1)
        let select = app.buttons["select-snip"]
        XCTAssertTrue(select.waitForExistence(timeout: 3), "Select must remain available while selecting other items.")
        select.tap()
        let newest = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Try the stack interaction on iPhone")).firstMatch
        let previous = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Sketch a simpler selection flow")).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertEqual(app.scrollViews["gathered-contents"].value as? String, "2 items")
        XCTAssertLessThan(newest.frame.minY, previous.frame.minY)
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
    }

    func testGatheredHeaderCopiesAndDeletesWithoutOpeningMore() {
        continueAfterFailure = false
        let storeName = "gather-header-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName, withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        row(named: "Try the stack interaction on iPhone", in: app).tap()

        let copyReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: app.buttons["copy-selection"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [copyReady], timeout: 5), .completed)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Four icon actions in the gathered container"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["copy-selection"].tap()
        assertCopyStatus("Copied 2 snips", in: app)
        XCTAssertTrue(app.buttons["delete-selection"].isHittable)
        app.buttons["delete-selection"].tap()
        XCTAssertTrue(app.buttons["gathered-stack"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
        XCTAssertFalse(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)

        app.terminate()
        app = launchApp(storeName: storeName)
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 5))
        XCTAssertFalse(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
        XCTAssertFalse(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
    }

    func testGatheredContainerExpandsInlineAndCollapses() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        let stack = app.buttons["gathered-stack"]
        let expand = app.buttons["expand-gathered"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        XCTAssertEqual(expand.value as? String, "2 items")
        XCTAssertGreaterThanOrEqual(expand.frame.width, 44)
        XCTAssertGreaterThanOrEqual(expand.frame.height, 44)
        let closedControlFrame = expand.frame
        XCTAssertEqual(expand.frame.midY, app.buttons["finish-selecting"].frame.midY, accuracy: 1)
        XCTAssertGreaterThan(expand.frame.minX, stack.frame.midX)
        expand.tap()

        XCTAssertFalse(app.navigationBars["Selected items"].exists, "Inspect the stack within its original container.")
        for identifier in ["move-gathered", "copy-selection", "delete-selection", "selection-actions"] {
            XCTAssertTrue(app.buttons[identifier].isHittable, "Keep the existing header actions available while expanded.")
        }
        let collapse = app.buttons["collapse-gathered"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 3))
        XCTAssertEqual(collapse.frame.minX, closedControlFrame.minX, accuracy: 1)
        XCTAssertEqual(collapse.frame.size.width, closedControlFrame.size.width, accuracy: 1)
        XCTAssertEqual(collapse.frame.size.height, closedControlFrame.size.height, accuracy: 1)
        let contents = app.scrollViews["gathered-contents"]
        let cancel = app.buttons["finish-selecting"]
        XCTAssertGreaterThanOrEqual(contents.frame.minY, cancel.frame.maxY)
        XCTAssertGreaterThanOrEqual(contents.frame.minY, collapse.frame.maxY)
        XCTAssertGreaterThanOrEqual(app.buttons["move-gathered"].frame.minY, contents.frame.maxY)
        XCTAssertFalse(app.navigationBars.buttons["finish-selecting"].exists)
        XCTAssertEqual(cancel.label, "Cancel")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Gathered container expanded in place"
        proof.lifetime = .keepAlways
        add(proof)
        collapse.tap()
        XCTAssertEqual(stack.value as? String, "2 items")
        XCTAssertEqual(expand.value as? String, "2 items")
        stack.tap()
        app.buttons["move-gathered"].tap()
        app.buttons["move-gathered-to-Work"].tap()
        XCTAssertTrue(collapse.waitForNonExistence(timeout: 5))
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
    }

    func testSelectedCardKeepsAttachmentContentAndPreview() {
        continueAfterFailure = false
        let app = launchApp(withAttachments: true)
        let preview = app.buttons["compact-attachment-preview-sample.png"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let sourceProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sourceProof.name = "Shared content in source list"
        sourceProof.lifetime = .keepAlways
        add(sourceProof)
        enterSelection(in: app)
        row(named: "Attachment fixture", in: app).tap()
        let stack = app.buttons["gathered-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 3))
        let closedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        closedProof.name = "Shared content in collapsed card"
        closedProof.lifetime = .keepAlways
        add(closedProof)
        stack.tap()
        let contents = app.scrollViews["gathered-contents"]
        XCTAssertTrue(contents.isHittable)
        XCTAssertTrue(contents.buttons["compact-attachment-preview-sample.png"].waitForExistence(timeout: 3))
        XCTAssertTrue(contents.buttons["compact-attachment-preview-notes.txt"].exists)
        let expandedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expandedProof.name = "Shared content in expanded card"
        expandedProof.lifetime = .keepAlways
        add(expandedProof)
        contents.buttons["compact-attachment-preview-sample.png"].tap()
        let image = app.images["Image preview"]
        XCTAssertTrue(image.waitForExistence(timeout: 3))
        app.buttons["dismiss-attachment-image"].tap()
        XCTAssertTrue(image.waitForNonExistence(timeout: 3))
        app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Attachment fixture")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["gathering-instructions"].waitForExistence(timeout: 3))
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        preview.tap()
        XCTAssertTrue(image.waitForExistence(timeout: 3))
        app.buttons["dismiss-attachment-image"].tap()
    }

    func testGatheredCardsKeepLayoutAndReturnTopItemWhileCollapsed() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        let preview = app.scrollViews["gathered-preview"]
        XCTAssertTrue(preview.exists)
        XCTAssertTrue(app.staticTexts["gathering-instructions"].exists)
        let emptyFrame = preview.frame
        let emptyHeaderY = app.buttons["finish-selecting"].frame.midY
        // The completion control is decorative while the row gathers, so it cannot mark Done.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "completion-")).firstMatch.exists)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        XCTAssertEqual(preview.frame.height, emptyFrame.height, accuracy: 1)
        XCTAssertEqual(preview.frame.minY, emptyFrame.minY, accuracy: 1)
        XCTAssertEqual(app.buttons["finish-selecting"].frame.midY, emptyHeaderY, accuracy: 1)
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        let stack = app.buttons["gathered-stack"]
        let putBack = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Try the stack interaction on iPhone")).firstMatch
        XCTAssertTrue(putBack.isHittable)
        let contentIdentifier = putBack.identifier.replacingOccurrences(of: "put-back-", with: "selected-card-content-")
        let cardContent = app.otherElements[contentIdentifier]
        XCTAssertTrue(cardContent.exists)
        let closedTextFrame = cardContent.frame
        let closedReturnFrame = putBack.frame
        XCTAssertGreaterThanOrEqual(stack.frame.width, 44)
        XCTAssertGreaterThanOrEqual(stack.frame.height, 44)
        XCTAssertGreaterThanOrEqual(stack.frame.minX, closedReturnFrame.maxX)
        let closedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        closedProof.name = "Stable gathered card collapsed"
        closedProof.lifetime = .keepAlways
        add(closedProof)
        stack.tap()
        let expandedText = app.scrollViews["gathered-contents"].staticTexts["Try the stack interaction on iPhone"]
        XCTAssertTrue(expandedText.exists)
        let expandedContent = app.scrollViews["gathered-contents"].otherElements[contentIdentifier]
        XCTAssertTrue(expandedContent.exists)
        XCTAssertEqual(expandedContent.frame.width, closedTextFrame.width, accuracy: 1)
        XCTAssertEqual(putBack.frame.width, closedReturnFrame.width, accuracy: 1)
        XCTAssertEqual(putBack.frame.minX, closedReturnFrame.minX, accuracy: 1)
        XCTAssertEqual(expandedContent.frame.height, closedTextFrame.height, accuracy: 1)
        XCTAssertEqual(putBack.frame.minY - expandedContent.frame.minY, closedReturnFrame.minY - closedTextFrame.minY, accuracy: 1)
        XCTAssertLessThan(putBack.frame.maxX, expandedText.frame.minX)
        let expandedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expandedProof.name = "Stable gathered cards expanded"
        expandedProof.lifetime = .keepAlways
        add(expandedProof)
        app.buttons["collapse-gathered"].tap()
        XCTAssertEqual(cardContent.frame.height, closedTextFrame.height, accuracy: 1)
        XCTAssertTrue(putBack.isHittable)
        putBack.tap()
        XCTAssertEqual(stack.value as? String, "1 item")
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
        let remainingReturn = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Sketch a simpler selection flow")).firstMatch
        XCTAssertTrue(remainingReturn.isHittable)
        remainingReturn.tap()
        XCTAssertTrue(app.staticTexts["gathering-instructions"].waitForExistence(timeout: 3))
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        for _ in 0..<3 {
            stack.tap()
            app.buttons["collapse-gathered"].tap()
        }
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
    }

    func testCollapsedSelectionFitsPromotedShorterCard() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        let longText = Array(repeating: "A longer selected item keeps its full multiline text.", count: 12).joined(separator: " ")
        createSnip(longText, in: app)
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        let stack = app.buttons["gathered-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        let shortHeight = app.scrollViews["gathered-preview"].frame.height
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        stack.tap()
        row(named: longText, in: app).tap()
        let returnLong = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: \(longText)")).firstMatch
        XCTAssertTrue(returnLong.waitForExistence(timeout: 5))
        returnLong.tap()
        app.buttons["collapse-gathered"].tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertEqual(app.scrollViews["gathered-preview"].frame.height, shortHeight, accuracy: 2,
                       "Promoting a mounted shorter card must resize the collapsed viewport.")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Collapsed selection fits promoted shorter card"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(collectionRow(named: longText, in: app).exists)
    }

    func testAddingToScrolledExpandedSelectionRevealsLatestItem() {
        continueAfterFailure = false
        let app = launchApp(withLongList: true)
        enterSelection(in: app)
        for index in stride(from: 23, through: 18, by: -1) {
            row(named: "Fixture \(index)", in: app).tap()
        }
        let stack = app.buttons["gathered-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        stack.tap()
        let contents = app.scrollViews["gathered-contents"]
        let earlier = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Fixture 23")).firstMatch
        for _ in 0..<6 where !earlier.isHittable { contents.swipeUp() }
        XCTAssertTrue(earlier.isHittable)
        row(named: "Fixture 17", in: app).tap()
        let latest = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Fixture 17")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertTrue(latest.isHittable, "A new selection must land in the visible expanded viewport after scrolling.")
        XCTAssertEqual(contents.value as? String, "7 items")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "New item lands after scrolling selected cards"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(collectionRow(named: "Fixture 17", in: app).exists)
        XCTAssertTrue(collectionRow(named: "Fixture 23", in: app).exists)
    }

    func testExpandedGatheredContainerScrollsAndReturnsAll() {
        verifyExpandedSelectionScrollsAndReturnsAll(withAttachments: false)
    }

    func testExpandedSelectedAttachmentCardsScrollAndReturnAll() {
        verifyExpandedSelectionScrollsAndReturnsAll(withAttachments: true)
    }

    private func verifyExpandedSelectionScrollsAndReturnsAll(withAttachments: Bool) {
        continueAfterFailure = false
        let app = launchApp(withAttachments: withAttachments, withLongList: true)
        XCTAssertTrue(collectionRow(named: "Fixture 23", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        for index in stride(from: 23, through: 0, by: -1) {
            row(named: index == 0 ? "Fixture oldest" : "Fixture \(index)", in: app).tap()
        }
        let stack = app.buttons["gathered-stack"]
        XCTAssertEqual(stack.value as? String, "24 items")
        stack.tap()
        let contents = app.scrollViews["gathered-contents"]
        XCTAssertTrue(contents.isHittable)
        let oldest = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Fixture 23")).firstMatch
        for _ in 0..<32 where !oldest.isHittable { contents.swipeUp() }
        XCTAssertTrue(oldest.isHittable, "Expanded selected cards remain scrollable.")
        if withAttachments {
            let cardIdentifier = oldest.identifier.replacingOccurrences(of: "put-back-", with: "selected-card-content-")
            let preview = contents.descendants(matching: .any)[cardIdentifier]
                .buttons["compact-attachment-preview-sample.png"]
            // Reaching the leading control can leave its thumbnail below the viewport.
            for _ in 0..<6 where !preview.isHittable { contents.swipeUp() }
            XCTAssertTrue(preview.isHittable)
            preview.tap()
            XCTAssertTrue(app.images["Image preview"].waitForExistence(timeout: 3))
            app.buttons["dismiss-attachment-image"].tap()
            XCTAssertTrue(app.images["Image preview"].waitForNonExistence(timeout: 3))
        }
        let expandedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expandedProof.name = "Last of 24 selected cards"
        expandedProof.lifetime = .keepAlways
        add(expandedProof)
        oldest.tap()
        app.buttons["collapse-gathered"].tap()
        XCTAssertEqual(stack.value as? String, "23 items")
        stack.tap()
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["collapse-gathered"].exists)
        XCTAssertTrue(collectionRow(named: "Fixture 23", in: app).exists)
        let returnedOldest = collectionRow(named: "Fixture oldest", in: app)
        for _ in 0..<32 where !returnedOldest.isHittable { app.swipeUp() }
        XCTAssertTrue(returnedOldest.isHittable, "Deselect and Cancel return even the offscreen items to the source list.")
        let returnedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        returnedProof.name = "Last item restored to long source list"
        returnedProof.lifetime = .keepAlways
        add(returnedProof)
    }

    func testFilteredGatheredCopyThenMoveFinishesGathering() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        app.buttons["workflow-options"].tap()
        app.buttons["Not Done"].tap()
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        app.buttons["copy-selection"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["app-toast"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "1 item")
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "2 items")
        app.buttons["move-gathered"].tap()
        app.buttons["move-gathered-to-Work"].tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["finish-selecting"].exists)
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).waitForExistence(timeout: 3))
        app.buttons["workflow-options"].tap()
        app.buttons["All"].tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 3))
    }

    func testGatheredStackReturnsSnipsAndCancels() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)

        row(named: "Sketch a simpler selection flow", in: app).tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForNonExistence(timeout: 3))
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).waitForNonExistence(timeout: 3))
        let stack = app.buttons["gathered-stack"]
        XCTAssertEqual(stack.value as? String, "2 items")
        XCTAssertTrue(app.descendants(matching: .any)["all-snips-gathered"].exists)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "All gathered into the stack"
        proof.lifetime = .keepAlways
        add(proof)
        stack.tap()
        let putBack = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Sketch a simpler selection flow")).firstMatch
        XCTAssertTrue(putBack.waitForExistence(timeout: 3))
        putBack.tap()
        app.buttons["collapse-gathered"].tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
        XCTAssertEqual(stack.value as? String, "1 item")
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(stack.exists)
    }

    func testSelectedStackStaysPutAndMovesFromMenu() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        let stack = app.buttons["gathered-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 3))
        let originalFrame = stack.frame
        let target = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: stack.frame.midX, dy: app.buttons["finish-selecting"].frame.minY - 144))
        stack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: target)
        XCTAssertTrue(stack.waitForExistence(timeout: 3), "Swiping the stack must not move selected items.")
        XCTAssertEqual(stack.value as? String, "2 items")
        XCTAssertEqual(stack.frame.minY, originalFrame.minY, accuracy: 1)
        XCTAssertTrue(app.navigationBars["Inbox"].exists)
        let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        proof.name = "Selected stack stays put after swipe"
        proof.lifetime = .keepAlways
        add(proof)
        stack.tap()
        XCTAssertTrue(app.buttons["collapse-gathered"].isHittable)
        app.buttons["collapse-gathered"].tap()
        app.buttons["move-gathered"].tap()
        XCTAssertTrue(app.buttons["add-list-for-move"].exists)
        let menuProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menuProof.name = "Move menu remains available"
        menuProof.lifetime = .keepAlways
        add(menuProof)
        app.buttons["move-gathered-to-Work"].tap()
        XCTAssertTrue(stack.waitForNonExistence(timeout: 5))
        XCTAssertFalse(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
    }

    func testGatheredStackMenuMovesAndPersists() {
        continueAfterFailure = false
        let storeName = "gather-move-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName, withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        app.buttons["move-gathered"].tap()
        app.buttons["move-gathered-to-Work"].tap()
        XCTAssertTrue(app.buttons["gathered-stack"].waitForNonExistence(timeout: 5))
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
        app.terminate()
        app = launchApp(storeName: storeName)
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
    }

    func testGatheredStackFitsAccessibilityText() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true, contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        XCTAssertTrue(app.buttons["gathered-stack"].isHittable)
        for identifier in ["move-gathered", "copy-selection", "delete-selection", "selection-actions"] {
            XCTAssertTrue(app.buttons[identifier].isHittable)
            // Native geometry can represent 44 points as 43.99999999999994.
            XCTAssertGreaterThanOrEqual(app.buttons[identifier].frame.width, 44 - 0.01)
            XCTAssertGreaterThanOrEqual(app.buttons[identifier].frame.height, 44 - 0.01)
        }
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Gathered stack at largest accessibility text"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["gathered-stack"].tap()
        for identifier in ["move-gathered", "copy-selection", "delete-selection", "selection-actions", "collapse-gathered"] {
            XCTAssertTrue(app.buttons[identifier].isHittable)
            XCTAssertGreaterThanOrEqual(app.buttons[identifier].frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(app.buttons[identifier].frame.maxY, app.frame.maxY)
        }
        let contents = app.scrollViews["gathered-contents"]
        let text = contents.staticTexts["Try the stack interaction on iPhone"]
        XCTAssertTrue(text.exists)
        XCTAssertLessThanOrEqual(text.frame.minY + 44, contents.frame.maxY, "Keep at least a readable first line in the viewport.")
        let putBack = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Try the stack interaction on iPhone")).firstMatch
        XCTAssertTrue(putBack.isHittable)
        let expandedProof = XCTAttachment(screenshot: app.screenshot())
        expandedProof.name = "Expanded glass at largest accessibility text"
        expandedProof.lifetime = .keepAlways
        add(expandedProof)
        app.buttons["collapse-gathered"].tap()
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).waitForExistence(timeout: 3))
    }

    func testGatheredStackRegathersAfterReturningLastSnipAndRotating() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        let stack = app.buttons["gathered-stack"]
        stack.tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Sketch a simpler selection flow")).firstMatch.tap()
        XCTAssertTrue(app.otherElements["gathering-instructions"].exists || app.staticTexts["gathering-instructions"].exists)
        XCTAssertTrue(app.buttons["finish-selecting"].exists)
        XCTAssertTrue(stack.waitForNonExistence(timeout: 3))
        XCUIDevice.shared.orientation = .landscapeLeft
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 3))
        XCTAssertEqual(stack.value as? String, "1 item")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Regathered after returning the last snip and rotating"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).waitForExistence(timeout: 3))
    }

    func testGatheredStackFitsLandscape() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        // The short source viewport shows the newest row; scroll the older one
        // into view before selecting it, instead of tapping beneath the dock.
        row(named: "Try the stack interaction on iPhone", in: app).swipeUp()
        XCTAssertTrue(row(named: "Sketch a simpler selection flow", in: app).isHittable)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        let stack = app.buttons["gathered-stack"]
        XCTAssertTrue(stack.isHittable)
        XCTAssertTrue(app.buttons["move-gathered"].isHittable)
        stack.tap()
        XCTAssertTrue(app.buttons["collapse-gathered"].isHittable)
        XCTAssertTrue(app.buttons["move-gathered"].isHittable)
        let expandedProof = XCTAttachment(screenshot: app.screenshot())
        expandedProof.name = "Expanded glass in landscape"
        expandedProof.lifetime = .keepAlways
        add(expandedProof)
        app.buttons["collapse-gathered"].tap()
        XCTAssertEqual(stack.value as? String, "1 item")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Gathered stack in landscape"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["move-gathered"].tap()
        app.buttons["move-gathered-to-Work"].tap()
        XCTAssertTrue(stack.waitForNonExistence(timeout: 5))
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 3))
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
        XCTAssertTrue(restoredFirst.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "completion-")
        ).firstMatch.exists)
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
        app.buttons["move-gathered"].tap()
        app.buttons["move-gathered-to-Work"].tap()

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

    func testSelectionPersistsAcrossLists() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(app.buttons["gathered-stack"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "1 item")
        listControl(named: "Inbox", in: app).tap()
        XCTAssertFalse(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 3))
    }

    func testPageSwipePreservesExpandedMultiListSelection() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        listControl(named: "Work", in: app).tap()
        createSnip("Work selection", in: app)
        returnToCollection(in: app)
        listControl(named: "Inbox", in: app).tap()
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        app.buttons["gathered-stack"].tap()

        let toWork = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3))
        toWork.press(forDuration: 0.05, thenDragTo: toWork.withOffset(CGVector(dx: -180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["collapse-gathered"].isHittable)
        XCTAssertTrue(app.buttons["Deselect: Sketch a simpler selection flow"].isHittable)
        row(named: "Work selection", in: app).tap()
        app.buttons["collapse-gathered"].tap()
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "2 items")
        XCTAssertTrue(app.buttons["Deselect: Work selection"].isHittable)
        app.buttons["gathered-stack"].tap()

        let toInbox = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        toInbox.press(forDuration: 0.05, thenDragTo: toInbox.withOffset(CGVector(dx: 180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["collapse-gathered"].isHittable)
        XCTAssertTrue(app.buttons["Deselect: Work selection"].isHittable)
        XCTAssertFalse(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 3))
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(collectionRow(named: "Work selection", in: app).waitForExistence(timeout: 3))
    }

    func testMultiListSelectionCreatesDestinationFromMoveMenu() {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        listControl(named: "Work", in: app).tap()
        createSnip("From Work", in: app)
        returnToCollection(in: app)
        listControl(named: "Inbox", in: app).tap()
        enterSelection(in: app)
        row(named: "Sketch a simpler selection flow", in: app).tap()
        row(named: "Try the stack interaction on iPhone", in: app).tap()
        XCTAssertTrue(app.buttons["Deselect: Try the stack interaction on iPhone"].isHittable)
        listControl(named: "Work", in: app).tap()
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "2 items")
        row(named: "From Work", in: app).tap()
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "3 items")
        XCTAssertTrue(app.buttons["Deselect: From Work"].isHittable)
        let stackProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        stackProof.name = "Multi-list selection newest on top"
        stackProof.lifetime = .keepAlways
        add(stackProof)
        app.buttons["gathered-stack"].tap()
        let expandedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expandedProof.name = "Multi-list selection expanded"
        expandedProof.lifetime = .keepAlways
        add(expandedProof)
        app.buttons["collapse-gathered"].tap()
        app.buttons["move-gathered"].tap()
        XCTAssertTrue(app.buttons["move-gathered-to-Work"].exists)
        XCTAssertTrue(app.buttons["add-list-for-move"].exists)
        let menuProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menuProof.name = "Move destinations and Add List"
        menuProof.lifetime = .keepAlways
        add(menuProof)
        app.buttons["add-list-for-move"].tap()
        XCTAssertTrue(app.alerts["Add List"].waitForExistence(timeout: 3))
        app.alerts["Add List"].buttons["Cancel"].tap()
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "3 items")
        app.buttons["move-gathered"].tap()
        app.buttons["add-list-for-move"].tap()
        let name = app.alerts["Add List"].textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("Selected notes")
        app.alerts["Add List"].buttons["Create and Move"].tap()
        XCTAssertTrue(app.buttons["gathered-stack"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
        revealCompactList(named: "Selected notes", in: app)
        listControl(named: "Selected notes", in: app).tap()
        for text in ["From Work", "Sketch a simpler selection flow", "Try the stack interaction on iPhone"] {
            XCTAssertTrue(collectionRow(named: text, in: app).waitForExistence(timeout: 3))
        }
    }

    func testSingleItemMoveCanAddFirstCustomList() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Move into a new list", in: app)
        returnToCollection(in: app)
        row(named: "Move into a new list", in: app).press(forDuration: 1)
        app.buttons["move-snip"].tap()
        app.buttons["Add List…"].tap()
        let name = app.alerts["Add List"].textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("First list")
        app.alerts["Add List"].buttons["Create and Move"].tap()
        XCTAssertTrue(listControl(named: "First list", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(collectionRow(named: "Move into a new list", in: app).waitForExistence(timeout: 3))
        listControl(named: "Inbox", in: app).tap()
        XCTAssertTrue(collectionRow(named: "Move into a new list", in: app).waitForNonExistence(timeout: 3))
    }

    private func createSnip(_ text: String, in app: XCUIApplication) {
        let composer = app.descendants(matching: .any)["composer-text"].firstMatch
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
        dismissComposerKeyboard(in: app)
    }

    private func dismissComposerKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        app.swipeDown()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
    }

    private func openSearch(in app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields["Search"]
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
        XCTAssertTrue(cancel.isHittable, "Search Close must be visible before tapping it.")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
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
        let usesSidebar = app.buttons["list-\(name)"].exists
        let listID = usesSidebar ? nil : compactListTab(named: name, in: app).identifier
            .dropFirst("list-tab-".count)
        openListActions(named: name, in: app)
        let edit: XCUIElement
        if usesSidebar {
            edit = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", "Edit List")
            ).firstMatch
        } else if let listID {
            edit = app.buttons["list-management-edit-\(listID)"]
        } else {
            XCTFail("List identifier must be captured before opening its actions.")
            return
        }
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
    }

    private func openListActions(named name: String, in app: XCUIApplication) {
        let sidebarList = app.buttons["list-\(name)"]
        if sidebarList.exists {
            sidebarList.press(forDuration: 1)
        } else {
            compactListTab(named: name, in: app).press(forDuration: 0.7)
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

    /// Scroll-to-visible fails once a tab sits far outside the compact strip.
    private func revealCompactList(named name: String, in app: XCUIApplication) {
        let tab = compactListTab(named: name, in: app)
        let selector = app.descendants(matching: .any)["list-selector"]
        guard selector.exists else { return }
        for _ in 0..<24 {
            guard tab.exists, tab.frame.width > 1 else { return }
            let frame = tab.frame
            if frame.minX >= 4, frame.maxX <= app.frame.width - 4 { return }
            let towardRight = frame.minX < 0
            let start = selector.coordinate(
                withNormalizedOffset: CGVector(dx: towardRight ? 0.08 : 0.92, dy: 0.5)
            )
            let dx = (towardRight ? 1 : -1) * selector.frame.width * 0.8
            start.press(
                forDuration: 0.02,
                thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0))
            )
        }
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

    private func createList(_ name: String, color: String? = nil, in app: XCUIApplication) {
        openNewList(in: app)
        let field = app.textFields["list-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(name)
        if let color { app.buttons["list-color-\(color)"].tap() }
        let save = app.buttons["save-list"]
        if save.isHittable {
            save.tap()
        } else {
            let done = app.keyboards.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 3))
            done.tap()
        }
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.buttons["list-management-new"].waitForExistence(timeout: 3))
        app.buttons["list-management-new"].tap()
    }

    private func returnToLists(in app: XCUIApplication) {
        dismissComposerKeyboard(in: app)
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
