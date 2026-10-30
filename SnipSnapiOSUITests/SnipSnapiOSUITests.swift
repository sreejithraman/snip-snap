import UIKit
import XCTest

@MainActor
final class SnipSnapiOSUITests: XCTestCase {
    private var shareAppName = ""

    override func tearDown() async throws {
        await MainActor.run {
            if XCUIDevice.shared.orientation != .portrait {
                XCUIDevice.shared.orientation = .portrait
            }
        }
        try await super.tearDown()
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
        withListHistoryFixtures: Bool = false,
        withClipboardEntry: Bool = false,
        syncIssue: String? = nil,
        contentSizeCategory: UIContentSizeCategory? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SNIP_SNAP_UI_TESTING"] = "1"
        if withHapticsTrace { app.launchEnvironment["SNIP_SNAP_UI_TEST_HAPTICS"] = "1" }
        if withLongList { app.launchEnvironment["SNIP_SNAP_UI_TEST_LONG_LIST"] = "1" }
        if withGatheringFixtures || withListHistoryFixtures {
            app.launchEnvironment["SNIP_SNAP_UI_TEST_GATHERING"] = "1"
        }
        if withListHistoryFixtures { app.launchEnvironment["SNIP_SNAP_UI_TEST_LIST_HISTORY"] = "1" }
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
        print("[DEBUG-r47-test] uptime=\(ProcessInfo.processInfo.systemUptime) stage=launch-request appearance=\(XCUIDevice.shared.appearance)")
        app.launch()
        print("[DEBUG-r47-test] uptime=\(ProcessInfo.processInfo.systemUptime) stage=launch-returned appearance=\(XCUIDevice.shared.appearance)")
        shareAppName = app.label
        waitForAppStartup(in: app)
        return app
    }

    private func waitForAppStartup(in app: XCUIApplication) {
        XCTAssertTrue(
            app.staticTexts["ui-test-startup-complete"].waitForExistence(timeout: 5),
            "App loading and fixture setup must finish before a workflow starts."
        )
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

    func testContextActionsPublishHapticOutcomes() throws {
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
        try visibleTouchCenter(of: menuRow, in: app).press(forDuration: 1)
        app.buttons["copy-snip"].tap()
        expectHaptic("copied")
        try visibleTouchCenter(of: menuRow, in: app).press(forDuration: 1)
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

    func testListSwipePerformanceAfterVisitingEightLists() throws {
        continueAfterFailure = false
        let app = launchApp(withListHistoryFixtures: true)
        try requireCompactSelector(in: app)
        let fixtureReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'list-tab-'")
            ).count == 9 && app.navigationBars["Inbox"].isEnabled
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [fixtureReady], timeout: 8), .completed)

        func swipe(to title: String, distance: Double) {
            let start = app.coordinate(withNormalizedOffset: CGVector(
                dx: distance < 0 ? 0.8 : 0.2, dy: 0.36
            ))
            start.press(
                forDuration: 0.1,
                thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
                withVelocity: XCUIGestureVelocity(rawValue: 180),
                thenHoldForDuration: 0
            )
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.navigationBars[title].exists && app.navigationBars[title].isEnabled
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 4), .completed)
            if title == "Inbox" {
                XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
                XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
            } else if title == "Work" {
                XCTAssertTrue(collectionRow(named: "Work history note", in: app).exists)
            }
        }

        for title in ["Work", "Ideas", "Reading", "Project reference library", "Weekend plans", "Archive", "Scale 07", "Scale 08"] {
            swipe(to: title, distance: -220)
        }
        for title in ["Scale 07", "Archive", "Weekend plans", "Project reference library", "Reading", "Ideas", "Work", "Inbox"] {
            swipe(to: title, distance: 220)
        }

        // This records completed-navigation CPU work. Device input/visual timing
        // needs a separate physical trace and user check; there is no portable ms gate.
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(application: app)], options: options) {
            Thread.sleep(forTimeInterval: 3)
            swipe(to: "Work", distance: -220)
            Thread.sleep(forTimeInterval: 3)
            swipe(to: "Inbox", distance: 220)
        }
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Main-content swipes return through eight visited lists"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testListSwipePerformance() throws {
        continueAfterFailure = false
        let app = launchApp(withLongList: true)
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        createSnip("Work page note", in: app)
        let options = XCTMeasureOptions()
        options.iterationCount = 4

        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            for (distance, title, content) in [(180.0, "Inbox", "Fixture 23"), (-180.0, "Work", "Work page note")] {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                start.press(
                    forDuration: 0.05,
                    thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
                    withVelocity: XCUIGestureVelocity(rawValue: 240),
                    thenHoldForDuration: 0
                )
                XCTAssertTrue(app.navigationBars[title].exists)
                let destinationRow = row(named: content, in: app)
                XCTAssertTrue(destinationRow.exists)
                XCTAssertTrue(destinationRow.isEnabled, "The destination must finish settling before measurement ends.")
            }
        }
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Measured list swipes completed at Work"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testPageSwipePreservesListPositionAndTitle() throws {
        continueAfterFailure = false
        let app = launchApp(withLongList: true)
        try requireCompactSelector(in: app)
        let anchor = scrollToListAnchor(in: app)
        let originalY = anchor.frame.minY
        let originalHeaderHeight = app.navigationBars["Inbox"].frame.height

        for _ in 0..<3 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 200, dy: 0)))
            XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
            let back = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.45))
            back.press(forDuration: 0.05, thenDragTo: back.withOffset(CGVector(dx: -200, dy: 0)))
            XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
            assertListAnchor(anchor, at: originalY, headerHeight: originalHeaderHeight, in: app)
        }
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "List position and compact title after repeated page swipes"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testSearchPreservesListPositionAndTitle() throws {
        continueAfterFailure = false
        let app = launchApp(withLongList: true)
        try requireCompactSelector(in: app)
        let anchor = scrollToListAnchor(in: app)
        let originalY = anchor.frame.minY
        let originalHeaderHeight = app.navigationBars["Inbox"].frame.height

        let search = openSearch(in: app)
        search.typeText("No fixture matches this query")
        XCTAssertTrue(app.descendants(matching: .any)["empty-search"].waitForExistence(timeout: 3))
        closeSearch(in: app)

        assertListAnchor(anchor, at: originalY, headerHeight: originalHeaderHeight, in: app)
    }

    func testNewListCreationAndCancellationPreservePreviousListPosition() throws {
        continueAfterFailure = false
        let app = launchApp(withLongList: true)
        try requireCompactSelector(in: app)
        let expandedHeaderHeight = app.navigationBars["Inbox"].frame.height
        let anchor = scrollToListAnchor(in: app)
        let originalY = anchor.frame.minY
        let originalHeaderHeight = app.navigationBars["Inbox"].frame.height

        openNewList(in: app)
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 3))
        app.buttons["cancel-new-list"].tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        assertListAnchor(anchor, at: originalY, headerHeight: originalHeaderHeight, in: app)

        createList("Position check", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["empty-snips"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.navigationBars["Position check"].frame.height, expandedHeaderHeight, accuracy: 1,
                       "A new empty list must start with its native expanded title")
        createSnip("First snip in the new list", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["empty-snips"].exists)
        XCTAssertEqual(app.navigationBars["Position check"].frame.height, expandedHeaderHeight, accuracy: 1)

        revealCompactList(named: "Inbox", in: app)
        let inboxTab = compactListTab(named: "Inbox", in: app)
        let selector = app.descendants(matching: .any)["list-selector"]
        XCTAssertTrue(selector.frame.contains(inboxTab.frame), "Reveal Inbox inside the selector before tapping")
        inboxTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        assertListAnchor(anchor, at: originalY, headerHeight: originalHeaderHeight, in: app)
        XCTAssertFalse(app.textFields["list-name"].exists, "Inactive list editors must not remain accessible")

        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Scrolled Inbox after canceling and saving a new list"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testInlineDraftRemainsEditableWhenItsListIsDeleted() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        createSnip("Moving draft", in: app)
        row(named: "Moving draft", in: app)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        let editor = app.descendants(matching: .any)["inline-snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        editor.typeText(" unsaved")
        XCTAssertEqual(editor.value as? String, "Moving draft unsaved")
        app.swipeDown()

        compactListTab(named: "Work", in: app)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["Delete Work"].waitForExistence(timeout: 3))
        app.buttons["Delete Work"].tap()
        let dialog = app.alerts["Delete Work?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        dialog.buttons["Delete List"].tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))

        XCTAssertTrue(editor.waitForExistence(timeout: 3), "The retained draft must belong to its new collection host")
        XCTAssertTrue(editor.isEnabled)
        XCTAssertEqual(editor.value as? String, "Moving draft unsaved")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        editor.typeText(" in Inbox")
        XCTAssertEqual(editor.value as? String, "Moving draft unsaved in Inbox")
        app.swipeDown()
        app.buttons["inline-snip-cancel"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(row(named: "Moving draft", in: app).waitForExistence(timeout: 3))
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
        if app.descendants(matching: .any)["list-selector"].waitForExistence(timeout: 3) {
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
        XCTAssertTrue(hasVisibleTouchTarget(newest, within: activeSnipViewport(in: app), in: app))
        let edgeStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.70))
            .withOffset(CGVector(dx: 8, dy: 0))
        edgeStart.press(forDuration: 0.05, thenDragTo: edgeStart.withOffset(CGVector(dx: 0, dy: -320)))
        XCTAssertFalse(newest.exists, "Vertical scrolling must work from the edge")
        for _ in 0..<12 where !hasVisibleTouchTarget(oldest, within: activeSnipViewport(in: app), in: app) || oldest.frame.maxY > composer.frame.minY {
            app.swipeUp()
        }
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Scrolled to final snip"
        proof.lifetime = .keepAlways
        add(proof)
        XCTAssertTrue(hasVisibleTouchTarget(oldest, within: activeSnipViewport(in: app), in: app), "The final snip must be reachable by scrolling")
        XCTAssertLessThanOrEqual(oldest.frame.maxY, composer.frame.minY)
    }

    func testVerticalScrollFromRowCenterDoesNotSwitchLists() throws {
        continueAfterFailure = false
        let app = launchApp(withLongList: true)
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        compactListTab(named: "Inbox", in: app).tap()

        let newest = collectionRow(named: "Fixture 23", in: app)
        let lowerRow = collectionRow(named: "Fixture 20", in: app)
        let sourceRowsReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.hasVisibleTouchTarget(newest, within: self.activeSnipViewport(in: app), in: app)
                && self.hasVisibleTouchTarget(lowerRow, within: self.activeSnipViewport(in: app), in: app)
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [sourceRowsReady], timeout: 5), .completed)
        let composer = app.descendants(matching: .any)["composer-text"]
        XCTAssertLessThanOrEqual(lowerRow.frame.maxY, composer.frame.minY)
        let start = lowerRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 25, dy: -300)))

        XCTAssertFalse(newest.exists, "Vertical scrolling must work from row content")
        XCTAssertTrue(app.navigationBars["Inbox"].exists)
        XCTAssertTrue(compactListTab(named: "Inbox", in: app).isSelected)
    }

    func testHorizontalEndPullDoesNotScrollLongListVertically() throws {
        continueAfterFailure = false
        let app = launchApp(withLongList: true)
        try requireCompactSelector(in: app)
        let newest = collectionRow(named: "Fixture 23", in: app)
        let lowerRow = collectionRow(named: "Fixture 17", in: app)
        XCTAssertTrue(hasVisibleTouchTarget(newest, within: activeSnipViewport(in: app), in: app))
        XCTAssertTrue(hasVisibleTouchTarget(lowerRow, within: activeSnipViewport(in: app), in: app))
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
        try visibleTouchCenter(of: row(named: "Keep draft", in: app), in: app).doubleTap()
        let editor = app.descendants(matching: .any)["inline-snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        try visibleTouchCenter(of: editor, in: app).tap()
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
        let emptyStates = app.staticTexts.matching(identifier: "empty-snips")
            .matching(NSPredicate(format: "enabled == true"))
        let body = emptyStates.element
        XCTAssertTrue(body.waitForExistence(timeout: 3))
        XCTAssertEqual(emptyStates.count, 1)
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
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
        try visibleTouchCenter(of: occupiedRow, in: app).press(forDuration: 1)
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
        XCTAssertTrue(app.switches["diagnostics-recording-toggle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["diagnostic-log-range"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "exclude snip content and file names"
        )).firstMatch.exists)
    }

    func testDiagnosticRecordingChoiceSurvivesRelaunchAndCanResume() {
        continueAfterFailure = false
        let app = launchApp()
        func openDiagnostics() {
            openSettings(in: app)
            let diagnostics = app.buttons["diagnostics"]
            for _ in 0..<3 where !diagnostics.exists { app.swipeUp() }
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 3))
            diagnostics.tap()
        }
        openDiagnostics()
        let recording = app.switches["diagnostics-recording-toggle"]
        XCTAssertTrue(recording.waitForExistence(timeout: 3))
        if recording.value as? String != "1" { toggle(recording) }
        expectation(for: NSPredicate(format: "value == '1' AND enabled == true"), evaluatedWith: recording)
        waitForExpectations(timeout: 5)
        toggle(recording)
        expectation(for: NSPredicate(format: "value == '0' AND enabled == true"), evaluatedWith: recording)
        waitForExpectations(timeout: 5)

        app.terminate()
        app.launch()
        openDiagnostics()
        expectation(for: NSPredicate(format: "value == '0' AND enabled == true"), evaluatedWith: recording)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["share-diagnostic-log"].isEnabled)
        toggle(recording)
        expectation(for: NSPredicate(format: "value == '1' AND enabled == true"), evaluatedWith: recording)
        waitForExpectations(timeout: 5)
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

    func testCopiesTextOnlySnip() throws {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        try openCopyShareFixture(matching: "Copy text fixture", in: app)
        chooseDetailAction("copy-snip", in: app)

        assertCopyStatus("Copied", in: app)
    }

    func testCopiesFileOnlySnipAttachments() throws {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        try openCopyShareFixture(matching: "notes.txt", in: app)
        chooseDetailAction("copy-attachments-snip", in: app)

        assertCopyStatus("Copied Attachments", in: app)
    }

    func testCopiesMixedSnipText() throws {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        try openCopyShareFixture(matching: "Copy mixed fixture", in: app)
        chooseDetailAction("copy-text-snip", in: app)

        assertCopyStatus("Copied Text", in: app)
    }

    func testSharesMultipleSelectedSnips() throws {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)
        returnToCollection(in: app)
        XCTAssertTrue(
            collectionRow(named: "Copy text fixture", in: app).waitForExistence(timeout: 5)
        )
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Copy text fixture", in: app), in: app).tap()
        try visibleTouchCenter(of: row(named: "Copy mixed fixture", in: app), in: app).tap()
        try visibleTouchCenter(of: app.buttons["selection-actions"], in: app).tap()
        let share = app.buttons["share-selection"]
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        share.tap()

        XCTAssertTrue(activityView(in: app).waitForExistence(timeout: 5))
    }

    func testSharesSnipBackIntoSnipSnap() throws {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        try openCopyShareFixture(matching: "Copy text fixture", in: app)
        chooseDetailAction("share-snip", in: app)
        XCTAssertTrue(activityView(in: app).waitForExistence(timeout: 5))

        let snipSnap = shareActivityCell(in: app)
        XCTAssertTrue(snipSnap.waitForExistence(timeout: 5))
        snipSnap.tap()
        assertShareExtensionStarted(in: app)

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
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.appearance = originalAppearance }
        }
        XCUIDevice.shared.appearance = .light
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
        assertShareExtensionStarted(in: safari)
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
        let pickerQuery = safari.collectionViews.matching(
            NSPredicate(format: "identifier != %@", "activityCollectionView")
        )
        XCTAssertTrue(
            pickerQuery.firstMatch.waitForExistence(timeout: 5),
            "The list picker did not open: \(safari.debugDescription)"
        )
        XCTAssertEqual(pickerQuery.count, 1, "The destination menu must be unambiguous")
        let pickerList = pickerQuery.element
        for listName in ["Inbox", work, reading] {
            let option = revealSharePickerList(
                named: listName, in: pickerList, host: safari, towardBottom: listName != "Inbox"
            )
            XCTAssertTrue(
                option.waitForExistence(timeout: 5),
                "\(listName) is missing from the share picker: \(safari.debugDescription)"
            )
            XCTAssertTrue(option.isHittable, "\(listName) cannot be chosen in the share picker")
        }
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

        revealSharePickerList(named: work, in: pickerList, host: safari, towardBottom: false).tap()
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
        let listTabCount = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "list-tab-")
        ).count
        let sharedLibraryScrollLimit = max(24, listTabCount * 2)
        revealCompactList(named: work, in: app, scrollLimit: sharedLibraryScrollLimit)
        let workList = listControl(named: work, in: app)
        XCTAssertTrue(workList.waitForExistence(timeout: 10))
        if !workList.isSelected { tapVisibleSelectorTab(workList, in: app) }
        XCTAssertTrue(app.navigationBars[work].waitForExistence(timeout: 3))
        XCTAssertTrue(workList.isSelected)
        let workContents = listContents(for: workList, in: app)
        let saved = workContents.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", token)
        ).firstMatch
        XCTAssertTrue(
            saved.waitForExistence(timeout: 10),
            "The shared snip did not land in \(work): \(app.debugDescription)"
        )
        revealCompactList(named: "Inbox", in: app, scrollLimit: sharedLibraryScrollLimit)
        let inbox = compactListTab(named: "Inbox", in: app)
        XCTAssertGreaterThanOrEqual(
            inbox.frame.minX,
            0,
            "Inbox stayed off screen at \(inbox.frame)"
        )
        if !inbox.isSelected { tapVisibleSelectorTab(inbox, in: app) }
        expectation(
            for: NSPredicate(format: "selected == true"),
            evaluatedWith: inbox
        )
        waitForExpectations(timeout: 5)
        let inboxContents = listContents(for: inbox, in: app)
        XCTAssertFalse(
            inboxContents.buttons.matching(NSPredicate(format: "label CONTAINS %@", token)).firstMatch.exists,
            "The shared snip also appeared in Inbox."
        )
        revealCompactList(named: work, in: app, scrollLimit: sharedLibraryScrollLimit)
        if !workList.isSelected { tapVisibleSelectorTab(workList, in: app) }
        XCTAssertTrue(
            saved.waitForExistence(timeout: 10),
            "The shared snip was unavailable after returning to \(work): \(app.debugDescription)"
        )
        XCTAssertEqual(activeSnipRows(in: app).matching(NSPredicate(format: "label CONTAINS %@", token)).count, 1)
    }

    private func shareActivityCell(in host: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(
            host.collectionViews["activityCollectionView"].waitForExistence(timeout: 15),
            "The system Share content did not start."
        )
        XCTAssertTrue(
            host.cells.matching(identifier: "shareCell").firstMatch.waitForExistence(timeout: 8),
            "The Share apps row did not appear."
        )
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

    private func revealSharePickerList(
        named name: String,
        in menu: XCUIElement,
        host: XCUIApplication,
        towardBottom: Bool
    ) -> XCUIElement {
        let option = menu.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        for _ in 0..<32 {
            XCTAssertFalse(menu.buttons.matching(NSPredicate(format: "label == %@", "Clipboard")).firstMatch.exists)
            let scrollBar = menu.otherElements.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar")
            ).firstMatch
            // The menu's accessibility frame extends below its clipped popup.
            let viewport = scrollBar.exists
                ? CGRect(x: menu.frame.minX, y: scrollBar.frame.minY,
                         width: menu.frame.width, height: scrollBar.frame.height).intersection(host.frame)
                : menu.frame.intersection(host.frame)
            if option.exists && option.isHittable
                && viewport.contains(CGPoint(x: option.frame.midX, y: option.frame.midY)) {
                return option
            }
            guard scrollBar.exists else { return option }
            let gestureArea = viewport.insetBy(dx: 16, dy: 24)
            guard gestureArea.width > 44, gestureArea.height > 44 else {
                XCTFail("The share picker has no visible scroll area: \(host.debugDescription)")
                return option
            }
            let down = option.exists ? option.frame.midY > viewport.midY : towardBottom
            let origin = host.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(
                dx: gestureArea.midX - host.frame.minX,
                dy: gestureArea.minY + gestureArea.height * (down ? 0.75 : 0.25) - host.frame.minY
            ))
            let end = origin.withOffset(CGVector(
                dx: gestureArea.midX - host.frame.minX,
                dy: gestureArea.minY + gestureArea.height * (down ? 0.25 : 0.75) - host.frame.minY
            ))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not reveal \(name) in the share picker: \(host.debugDescription)")
        return option
    }

    private func scrollShareApps(in host: XCUIApplication, towardLeft: Bool) {
        let row = host.cells.matching(identifier: "shareCell")
        guard row.count > 1 else { return }
        let anchorFrame = row.element(boundBy: 1).frame
        let sheetFrame = activityView(in: host).frame
        let contentFrame = host.collectionViews["activityCollectionView"].frame
        XCTAssertEqual(contentFrame.width, sheetFrame.width, accuracy: 1)
        XCTAssertEqual(contentFrame.height, sheetFrame.height, accuracy: 1)
        // Remote Share content can report frames relative to its host sheet.
        let y = sheetFrame.minY + anchorFrame.midY - contentFrame.minY
        XCTAssertGreaterThan(y, sheetFrame.minY)
        XCTAssertLessThan(y, sheetFrame.maxY)
        let origin = host.frame.origin
        let start = host.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: sheetFrame.minX + sheetFrame.width * (towardLeft ? 0.8 : 0.2) - origin.x,
            dy: y - origin.y
        ))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(
            dx: sheetFrame.width * (towardLeft ? -0.6 : 0.6), dy: 0
        )))
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

    func testUnavailableAttachmentOffersOnlyCopyTextOrCancel() throws {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)

        try openCopyShareFixture(matching: "Copy unavailable fixture", in: app)
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

    func testContextEditUsesInlineDraftAndPreservesAttachmentsOnCancel() throws {
        continueAfterFailure = false
        let storeName = "inline-edit-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName, withCopyShareFixtures: true)
        let original = row(named: "Copy mixed fixture", in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        try visibleTouchCenter(of: original, in: app).press(forDuration: 1)
        app.buttons["edit-snip"].tap()

        let editor = app.descendants(matching: .any)["inline-snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Edit Snip"].exists)
        try visibleTouchCenter(of: app.buttons["remove-attachment-sample.png"], in: app).tap()
        try visibleTouchCenter(of: editor, in: app).tap()
        editor.typeText(" discarded")
        try visibleTouchCenter(of: app.buttons["inline-snip-cancel"], in: app).tap()

        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["compact-attachment-preview-sample.png"].exists)
        try visibleTouchCenter(of: original, in: app).press(forDuration: 1)
        app.buttons["edit-snip"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Copy mixed fixture")
        XCTAssertTrue(app.buttons["remove-attachment-sample.png"].exists)
        try visibleTouchCenter(of: editor, in: app).tap()
        editor.typeText(" saved")
        try saveInlineEditor(in: app)
        XCTAssertTrue(row(named: "Copy mixed fixture saved", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["compact-attachment-preview-sample.png"].exists)
        app.terminate()
        app = launchApp(storeName: storeName, withCopyShareFixtures: true)
        XCTAssertTrue(row(named: "Copy mixed fixture saved", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["compact-attachment-preview-sample.png"].exists)
    }

    func testCreatesAndEditsTextSnip() throws {
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
        let touch = try visibleTouchCenter(of: snipRow, clippedTo: app.frame, in: app)
        touch.tap()
        XCTAssertFalse(app.navigationBars["Snip"].exists)
        Thread.sleep(forTimeInterval: 0.6)
        touch.doubleTap()
        let editor = app.descendants(matching: .any)["inline-snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars["Edit Snip"].exists)
        let inlineEditorScreenshot = XCTAttachment(screenshot: app.screenshot())
        inlineEditorScreenshot.name = "Inline Snip Editor"
        inlineEditorScreenshot.lifetime = .keepAlways
        add(inlineEditorScreenshot)
        try visibleTouchCenter(of: editor, clippedTo: app.frame, in: app).tap()
        editor.typeText(" updated")
        try visibleTouchCenter(of: app.buttons["inline-snip-save"], clippedTo: app.frame, in: app).tap()

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
        row(named: "Inline draft", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
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
        let searchEditor = app.descendants(matching: .any)["global-search-results"]
            .descendants(matching: .any)["inline-snip-text"]
        XCTAssertTrue(searchEditor.waitForExistence(timeout: 3))
        XCTAssertEqual(searchEditor.value as? String, draft)
        searchEditor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        searchEditor.typeText(" from search")
        let sharedDraft = "Inline draft unsaved from search"
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", sharedDraft), object: searchEditor
        )], timeout: 5), .completed, "Actual text: \(String(describing: searchEditor.value))")
        app.descendants(matching: .any)["global-search-results"].swipeDown()
        closeSearch(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, sharedDraft)
        app.buttons["inline-snip-save"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let saved = row(named: "Inline draft unsaved from search", in: app)
        enterSelection(in: app)
        saved.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["selection-actions"].isEnabled)
        let selectionSearch = openSearch(in: app)
        selectionSearch.typeText("Inline draft")
        let result = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "search-snip-"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(searchEditor.waitForExistence(timeout: 3))
        app.descendants(matching: .any)["global-search-results"].swipeDown()
        closeSearch(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["selection-actions"].exists)
        app.buttons["inline-snip-cancel"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
    }

    func testSearchEditReopensInItsOriginalListWithoutDiscardingDraft() throws {
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
        try visibleSearchResultTouchCenter(identifiedBy: result.identifier, in: app).doubleTap()
        let editor = app.descendants(matching: .any)["inline-snip-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        try visibleTouchCenter(of: app.buttons["remove-attachment-sample.png"], in: app).tap()
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        editor.typeText(" unsaved")
        let text = "Copy mixed fixture unsaved"
        XCTAssertEqual(editor.value as? String, text)
        try ensureOnscreenKeyboard(for: editor, in: app)
        XCTAssertEqual(editor.value as? String, text)
        app.descendants(matching: .any)["global-search-results"].swipeDown()
        closeSearch(in: app)

        listControl(named: "Inbox", in: app).tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, text)
        XCTAssertFalse(app.buttons["remove-attachment-sample.png"].exists)
        try visibleTouchCenter(of: app.buttons["inline-snip-save"], in: app).tap()
        let saved = row(named: text, in: app)
        try visibleTouchCenter(of: saved, in: app).doubleTap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, text)
        XCTAssertFalse(app.buttons["remove-attachment-sample.png"].exists)
        try visibleTouchCenter(of: app.buttons["inline-snip-cancel"], in: app).tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
    }

    func testQuickComposerLongPressSendsToAnotherListAndPreservesItsDraft() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createList("Work", in: app)
        let workContents = listContents(for: compactListTab(named: "Work", in: app), in: app)
        let composer = app.descendants(matching: .any)["composer-text"]
        composer.tap()
        composer.typeText("Work draft to keep")
        XCTAssertTrue(compactListTab(named: "Inbox", in: app).waitForNonExistence(timeout: 3))
        dismissComposerKeyboard(in: app)
        XCTAssertTrue(compactListTab(named: "Inbox", in: app).waitForExistence(timeout: 3))
        let inboxTab = compactListTab(named: "Inbox", in: app)
        let inboxContents = listContents(for: inboxTab, in: app)
        inboxTab.tap()
        composer.tap()
        composer.typeText("Sent to Work from Inbox")

        try ensureOnscreenKeyboard(for: composer, in: app)
        let send = app.buttons["composer-send"]
        let keyboard = app.keyboards.firstMatch
        let layoutReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard keyboard.exists, app.frame.contains(keyboard.frame),
                  self.hasVisibleTouchTarget(send, in: app),
                  app.frame.contains(send.frame) else { return false }
            return send.frame.maxY <= keyboard.frame.minY
        }, object: nil)
        let ready = XCTWaiter.wait(for: [layoutReady], timeout: 3)
        if ready != .completed { attachUIState("Composer before Send morph", in: app) }
        XCTAssertEqual(ready, .completed)
        let initialSendFrame = send.frame
        try visibleTouchCenter(of: send, in: app).press(forDuration: 1)
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
        try visibleTouchCenter(of: send, in: app).press(forDuration: 1)
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
        XCTAssertEqual(composer.label, "Add to Inbox…")
        XCTAssertTrue(inboxContents.waitForExistence(timeout: 3))
        let sentRowInInbox = collectionRow(named: "Sent to Work from Inbox", in: inboxContents)
        if sentRowInInbox.exists { attachUIState("Inbox after Send to Work", in: app) }
        XCTAssertFalse(sentRowInInbox.exists)
        dismissComposerKeyboard(in: app)
        XCTAssertTrue(compactListTab(named: "Work", in: app).waitForExistence(timeout: 3))
        compactListTab(named: "Work", in: app).tap()
        XCTAssertTrue(collectionRow(named: "Sent to Work from Inbox", in: workContents).waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Work draft to keep")

        app.terminate()
        app.launch()
        if !compactListTab(named: "Work", in: app).isSelected {
            compactListTab(named: "Work", in: app).tap()
        }
        XCTAssertTrue(collectionRow(named: "Sent to Work from Inbox", in: workContents).waitForExistence(timeout: 5))
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
        let composerAboveKeyboard = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            guard keyboard.exists, keyboard.frame.intersects(app.frame) else { return false }
            return [composer, addAttachments, send].allSatisfy {
                !$0.frame.isEmpty && $0.frame.maxY <= keyboard.frame.minY
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [composerAboveKeyboard], timeout: 3), .completed)
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
        send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

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

    private func assertPhotosPickerReady(in app: XCUIApplication) {
        let photos = app.buttons["Photos"]
        let loading = app.navigationBars["PUPickerUnavailableView"]
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            photos.exists || loading.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: 5), .completed)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            photos.exists || !loading.exists
        }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [loaded], timeout: 15), .completed,
            "The system Photos picker did not finish loading."
        )
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
    }

    func testPhotoPickerStagesAChosenImage() throws {
        continueAfterFailure = false
        let app = launchApp()
        app.buttons["composer-add-attachments"].tap()
        app.buttons["Choose Photos"].firstMatch.tap()
        assertPhotosPickerReady(in: app)
        let firstPhoto = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard firstPhoto.waitForExistence(timeout: 5) else {
            attachUIState("Photo picker fixture precondition", in: app)
            throw XCTSkip("Seed one image in the test Simulator's Photos library to run.")
        }
        // The system Photos picker exposes grid images but does not report them as hittable.
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        let attachment = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "composer-attachment-Photo."
        )).firstMatch
        XCTAssertTrue(attachment.waitForExistence(timeout: 8))
        try visibleTouchCenter(of: attachment, in: app).tap()
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
        searchResult.doubleTap()
        XCTAssertTrue(app.descendants(matching: .any)["inline-snip-text"].waitForExistence(timeout: 5))
        app.buttons["add-attachments"].tap()
        app.buttons["Choose Photos"].firstMatch.tap()
        assertPhotosPickerReady(in: app)
        let firstPhoto = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard firstPhoto.waitForExistence(timeout: 5) else {
            attachUIState("Photo picker fixture precondition", in: app)
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
        assertPhotosPickerReady(in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.09, dy: 0.12)).tap()
        XCTAssertTrue(staged.waitForExistence(timeout: 5))
        try visibleTouchCenter(of: app.buttons["inline-snip-save"], in: app).tap()
        XCTAssertTrue(app.buttons["inline-snip-save"].waitForNonExistence(timeout: 8))

        app.terminate()
        app = launchApp(storeName: storeName, withAttachments: true)
        try openAttachmentFixture(in: app)
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
        try visibleTouchCenter(
            of: snipRow, clippedTo: app.collectionViews.firstMatch.frame, in: app
        ).tap()
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

    func testComposerPastesCopiedPhotoSnipAsAttachment() throws {
        continueAfterFailure = false
        let app = launchApp(withCopyShareFixtures: true)
        let source = row(named: "Copy mixed fixture", in: app)
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        try visibleTouchCenter(of: source, in: app).press(forDuration: 1)
        app.buttons["copy-snip"].tap()
        let composer = app.descendants(matching: .any)["composer-text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.press(forDuration: 1)
        let paste = app.menuItems["Paste"]
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
        XCTAssertTrue(hasVisibleTouchTarget(paste, in: app))
        XCTAssertTrue(paste.isEnabled)

        let composer = app.descendants(matching: .any)["composer-text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        try visibleTouchCenter(of: composer, in: app).tap()
        composer.typeText("Quick paste fixture")
        app.buttons["composer-send"].tap()
        try visibleTouchCenter(of: row(named: "Quick paste fixture", in: app), in: app).press(forDuration: 1)
        app.buttons["copy-snip"].tap()
        createList("Work", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        try visibleTouchCenter(of: composer, in: app).tap()
        composer.typeText("Prefix: ")
        XCTAssertTrue(paste.waitForNonExistence(timeout: 3))
        dismissComposerKeyboard(in: app)
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        XCTAssertTrue(hasVisibleTouchTarget(paste, in: app))
        try visibleTouchCenter(of: paste, in: app).tap()
        XCTAssertTrue(row(named: "Quick paste fixture", in: app).exists)
        XCTAssertEqual(composer.value as? String, "Prefix: ")
        XCTAssertFalse(collectionRow(named: "Prefix: Quick paste fixture", in: app).exists)

        listControl(named: "Inbox", in: app).tap()
        XCTAssertFalse(collectionRow(named: "Prefix: Quick paste fixture", in: app).exists)
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(row(named: "Quick paste fixture", in: app).exists)
        XCTAssertEqual(composer.value as? String, "Prefix: ")
        XCTAssertTrue(hasVisibleTouchTarget(paste, in: app))
    }

    func testLeadingClipboardPasteCapturesCopiedText() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createSnip("Paste button fixture", in: app)
        try visibleTouchCenter(of: row(named: "Paste button fixture", in: app), in: app).press(forDuration: 1)
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
        let selector = app.descendants(matching: .any)["list-selector"]
        let clipboard = app.buttons["clipboard-tab"]
        XCTAssertGreaterThanOrEqual(clipboard.frame.minX, selector.frame.minX - 1)
        XCTAssertLessThanOrEqual(clipboard.frame.maxX, selector.frame.maxX + 1)
        try visibleTouchCenter(of: clipboard, clippedTo: selector.frame, in: app).tap()

        let entry = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "clipboard-entry-")
        ).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        try visibleTouchCenter(
            of: entry, clippedTo: app.collectionViews.firstMatch.frame, in: app
        ).press(forDuration: 1)
        app.buttons["Pin"].tap()
        XCTAssertEqual(entry.value as? String, "Pinned")
        try visibleTouchCenter(
            of: entry, clippedTo: app.collectionViews.firstMatch.frame, in: app
        ).press(forDuration: 1)
        app.buttons["Unpin"].tap()
        XCTAssertNotEqual(entry.value as? String, "Pinned")
        try visibleTouchCenter(
            of: entry, clippedTo: app.collectionViews.firstMatch.frame, in: app
        ).press(forDuration: 1)
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

    func testNewListFromClipboardOpensWhenButtonBecomesAvailable() async throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        let clipboard = app.buttons["clipboard-tab"]
        clipboard.tap()
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        clipboard.tap()
        let newList = app.buttons["list-management-new"]
        let deadline = ContinuousClock.now + .seconds(3)
        while !newList.exists && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(newList.exists)
        newList.tap()
        XCTAssertTrue(app.textFields["list-name"].waitForExistence(timeout: 4))
        app.buttons["save-list"].tap()
        XCTAssertTrue(app.navigationBars["New List"].waitForExistence(timeout: 3))
        XCTAssertTrue(compactListTab(named: "New List", in: app).isSelected)
    }

    func testClipboardAndSelectorPreserveNavigationAndDraft() throws {
        continueAfterFailure = false
        let app = launchApp()
        try requireCompactSelector(in: app)
        createSnip("Selection fixture", in: app)
        let composer = app.textViews["composer-text"]
        try visibleTouchCenter(of: composer, in: app).tap()
        composer.typeText("Unsent draft")
        dismissComposerKeyboard(in: app)
        let clipboard = app.buttons["clipboard-tab"]
        tapVisibleSelectorTab(clipboard, in: app)
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertFalse(composer.exists)
        let inbox = compactListTab(named: "Inbox", in: app)
        XCTAssertFalse(inbox.isSelected)
        tapVisibleSelectorTab(inbox, in: app)
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Unsent draft")
        XCTAssertTrue(inbox.isSelected)
        let search = openSearch(in: app)
        search.typeText("Draft search")
        closeSearch(in: app)
        _ = try visibleTouchCenter(of: composer, in: app)
        XCTAssertEqual(composer.value as? String, "Unsent draft")
        dismissComposerKeyboard(in: app)
        let selectorBeforeSelection = app.descendants(matching: .any)["list-selector"].frame
        enterSelection(in: app)
        XCTAssertTrue(composer.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.descendants(matching: .any)["list-selector"].frame.midY,
                       selectorBeforeSelection.midY, accuracy: 2)
        app.buttons["finish-selecting"].tap()
        _ = try visibleTouchCenter(of: composer, in: app)
        XCTAssertEqual(composer.value as? String, "Unsent draft")
        tapVisibleSelectorTab(clipboard, in: app)
        XCTAssertTrue(clipboard.isSelected)
        let selector = app.descendants(matching: .any)["list-selector"]
        XCTAssertEqual(clipboard.frame.midX, selector.frame.midX, accuracy: 2)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Clipboard selected inside list strip"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        tapVisibleSelectorTab(clipboard, in: app, reselect: true)
        let newList = app.buttons["list-management-new"]
        XCTAssertTrue(newList.waitForExistence(timeout: 3))
        newList.tap()
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
        let composer = app.textViews["composer-text"]
        try visibleTouchCenter(of: composer, in: app).tap()
        composer.typeText("Inbox unsent draft")
        dismissComposerKeyboard(in: app)
        createList("Work", in: app)
        createSnip("Work page note", in: app)
        try visibleTouchCenter(of: composer, in: app).tap()
        composer.typeText("Work unsent draft")
        dismissComposerKeyboard(in: app)

        func dragTabs(_ distance: CGFloat) throws {
            let selector = app.descendants(matching: .any)["list-selector"]
            _ = try visibleTouchCenter(of: app.buttons["Search"], in: app)
            let start = selector.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(
                forDuration: 0.05,
                thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
                withVelocity: XCUIGestureVelocity(rawValue: 100),
                thenHoldForDuration: 0.2
            )
        }

        try dragTabs(20)
        XCTAssertTrue(compactListTab(named: "Work", in: app).isSelected)
        XCTAssertEqual(composer.value as? String, "Work unsent draft")
        try dragTabs(140)
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        _ = try visibleTouchCenter(of: row(named: "Inbox page note", in: app), in: app)
        // Visited pages stay mounted to preserve native scroll and navigation state.
        // Their rows must stop accepting input when another list becomes active.
        XCTAssertFalse(collectionRow(named: "Work page note", in: app).isHittable)
        XCTAssertFalse(collectionRow(named: "Work page note", in: app).isEnabled)
        _ = try visibleTouchCenter(of: composer, in: app)
        XCTAssertEqual(composer.value as? String, "Inbox unsent draft")

        try dragTabs(-140)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        _ = try visibleTouchCenter(of: row(named: "Work page note", in: app), in: app)
        XCTAssertFalse(collectionRow(named: "Inbox page note", in: app).isHittable)
        XCTAssertFalse(collectionRow(named: "Inbox page note", in: app).isEnabled)
        _ = try visibleTouchCenter(of: composer, in: app)
        XCTAssertEqual(composer.value as? String, "Work unsent draft")

        let workRow = row(named: "Work page note", in: app)
        try visibleTouchCenter(of: workRow, in: app).press(forDuration: 1)
        app.buttons["Pin"].tap()
        XCTAssertTrue(compactListTab(named: "Work", in: app).isSelected)
        XCTAssertEqual(composer.value as? String, "Work unsent draft")

        func dragAcrossTabs(_ distance: CGFloat) throws {
            let selector = app.descendants(matching: .any)["list-selector"]
            _ = try visibleTouchCenter(of: app.buttons["Search"], in: app)
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
        try dragAcrossTabs(260)
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertFalse(composer.exists)
        try dragAcrossTabs(-260)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        _ = try visibleTouchCenter(of: composer, in: app)
        let title = app.navigationBars["Work"].staticTexts["Work"]
        XCTAssertTrue(title.exists)
        XCTAssertFalse(title.frame.intersection(app.navigationBars["Work"].frame).intersection(app.frame).isEmpty)
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
        XCTAssertTrue(app.staticTexts["Lists"].exists)
        let clipboard = app.buttons["list-management-select-clipboard"]
        let inbox = app.buttons["list-management-select-00000000-0000-0000-0000-000000000001"]
        XCTAssertFalse(clipboard.exists)
        XCTAssertFalse(inbox.exists)
        XCTAssertFalse(app.buttons["Reorder Clipboard"].exists)
        XCTAssertFalse(app.buttons["Reorder Inbox"].exists)
        let reading = app.buttons["list-management-select-" + readingID]
        let work = app.buttons["list-management-select-" + workID]
        let source = app.cells.containing(.button, identifier: reading.identifier).firstMatch
        let destination = app.cells.containing(.button, identifier: work.identifier).firstMatch
        XCTAssertTrue(source.exists)
        XCTAssertTrue(destination.exists)
        let grabber = app.buttons["Reorder Reading"]
        XCTAssertTrue(grabber.exists)
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
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
        let inlineError = app.descendants(matching: .any)["inline-operation-error"]
        XCTAssertTrue(inlineError.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["A list with that name already exists. Choose another name."].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let error = XCTAttachment(screenshot: app.screenshot())
        error.name = "Clear duplicate list name error"
        error.lifetime = .keepAlways
        add(error)
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
        let composer = app.textViews["composer-text"]
        let selector = app.descendants(matching: .any)["list-selector"]
        try visibleTouchCenter(of: composer, in: app).tap()
        composer.typeText("Keep this draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(selector.waitForNonExistence(timeout: 3))
        _ = try visibleTouchCenter(of: composer, in: app)
        _ = try visibleTouchCenter(of: app.buttons["composer-send"], in: app)
        let itemEntry = XCTAttachment(screenshot: app.screenshot())
        itemEntry.name = "Item entry without bottom navigation"
        itemEntry.lifetime = .keepAlways
        add(itemEntry)

        dismissComposerKeyboard(in: app)
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
        XCTAssertTrue(hasVisibleTouchTarget(star, within: app.scrollViews["list-icon-results"], in: app))
        XCTAssertGreaterThanOrEqual(star.frame.minY, search.frame.maxY)
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
        let completedQuery = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "circle.fill"), object: search
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completedQuery], timeout: 3), .completed)
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
        XCTAssertTrue(hasVisibleTouchTarget(app.descendants(matching: .any)["composer-text"], in: app))
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
        search.tap()
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

    func testListEditorIconSearchKeepsControlsReachable() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchApp()
        createList("Reading", in: app)
        openListEditor(named: "Reading", in: app)
        app.segmentedControls["list-appearance-picker"].buttons["Icon"].tap()

        let search = app.textFields["list-icon-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.frame.contains(search.frame))
        search.tap()
        search.typeText("star")
        try ensureOnscreenKeyboard(for: search, in: app)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.buttons["save-list"].isHittable)
        let focusedState = try app.snapshot()
        let keyboard = try XCTUnwrap(keyboardObservation(in: focusedState).visibleFrame)
        let saveFooter = try XCTUnwrap(matchingSnapshots(identifiedBy: "save-list", in: focusedState)
            .first { $0.elementType == .button })
        XCTAssertTrue(focusedState.frame.contains(saveFooter.frame))
        XCTAssertLessThanOrEqual(saveFooter.frame.maxY, keyboard.minY)
        attachUIState("Landscape icon search with Save above the keyboard", in: app)
        search.typeText("\n")
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3))
        XCTAssertEqual(search.value as? String, "star")
        let results = app.scrollViews["list-icon-results"]
        let initialSearchY = search.frame.minY
        results.swipeUp()
        XCTAssertTrue(search.isHittable, "Icon search must stay pinned while browsing results.")
        let pinnedSearchY = search.frame.minY
        XCTAssertGreaterThanOrEqual(pinnedSearchY, results.frame.minY)
        let roundingError = max(initialSearchY.ulp, pinnedSearchY.ulp) * 8
        XCTAssertLessThanOrEqual(pinnedSearchY - initialSearchY, roundingError)
        results.swipeDown()
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

    func testCreatesListMovesSnipAndDeletesIt() throws {
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
        try visibleTouchCenter(of: moveRow, in: app).press(forDuration: 1)
        app.buttons["move-snip"].tap()
        let inboxDestination = app.collectionViews.buttons.matching(
            NSPredicate(format: "label == %@", "Inbox")
        ).element
        XCTAssertTrue(inboxDestination.waitForExistence(timeout: 3))
        inboxDestination.tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(listControl(named: "Inbox", in: app).isSelected)
        let inboxContents = selectedListContents(in: app)
        let moved = inboxContents.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'snip-' AND NOT identifier BEGINSWITH 'snip-text-' AND label BEGINSWITH %@",
            "Move this"
        )).element
        XCTAssertTrue(moved.waitForExistence(timeout: 3))
        try visibleTouchCenter(of: moved, in: app).press(forDuration: 1)
        XCTAssertTrue(app.buttons["delete-context-snip"].waitForExistence(timeout: 3))
        app.buttons["delete-context-snip"].tap()
        XCTAssertTrue(moved.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["app-toast"].waitForExistence(timeout: 3))
        app.buttons["toast-action"].tap()
        XCTAssertTrue(collectionRow(named: "Move this", in: inboxContents).waitForExistence(timeout: 3))
    }

    func testDeleteToastUndoRestoresSnip() throws {
        continueAfterFailure = false
        let originalAppearance = XCUIDevice.shared.appearance
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.appearance = originalAppearance }
        }
        XCUIDevice.shared.appearance = .dark
        let app = launchApp()
        createSnip("Undo this", in: app)
        let presentation = try deleteSnipAndCaptureToast(named: "Undo this", in: app)
        let action = try capturedSnapshot(identifiedBy: "toast-action", in: presentation.state)
        XCTAssertEqual(action.label, "Undo deletion")
        XCTAssertTrue(action.isEnabled)
        XCTAssertTrue(presentation.state.frame.contains(action.frame))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: action.frame.midX - presentation.state.frame.minX,
            dy: action.frame.minY + action.frame.height * 0.1 - presentation.state.frame.minY
        )).tap()
        XCTAssertTrue(row(named: "Undo this", in: app).waitForExistence(timeout: 3))
    }

    func testDeleteToastPresentationInDarkMode() throws {
        continueAfterFailure = false
        let size = CGSize(width: 100, height: 60)
        for color in [UIColor.black, UIColor.white] {
            let blank = UIGraphicsImageRenderer(size: size).image { context in
                context.cgContext.setFillColor(color.cgColor)
                context.cgContext.fill(CGRect(origin: .zero, size: size))
            }
            XCTAssertFalse(
                hasDarkLabelOnLightBackground(blank),
                "A blank image cannot prove the filled Undo button and contrasting label."
            )
        }
        let originalAppearance = XCUIDevice.shared.appearance
        addTeardownBlock {
            await MainActor.run {
                print("[DEBUG-r47-test] uptime=\(ProcessInfo.processInfo.systemUptime) stage=appearance-restore-request appearance=\(originalAppearance)")
                XCUIDevice.shared.appearance = originalAppearance
                print("[DEBUG-r47-test] uptime=\(ProcessInfo.processInfo.systemUptime) stage=appearance-restore-return appearance=\(XCUIDevice.shared.appearance)")
            }
        }
        XCUIDevice.shared.appearance = .dark
        let app = launchApp()
        createSnip("Inspect delete feedback", in: app)
        let presentation = try deleteSnipAndCaptureToast(named: "Inspect delete feedback", in: app)
        let state = presentation.state
        let toast = try capturedSnapshot(identifiedBy: "app-toast", in: state)
        let action = try capturedSnapshot(identifiedBy: "toast-action", in: state)
        let composer = try capturedSnapshot(identifiedBy: "composer-text", in: state)
        let screenshot = presentation.screenshot
        let source = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGAffineTransform(
            scaleX: CGFloat(source.width) / state.frame.width,
            y: CGFloat(source.height) / state.frame.height
        )
        let actionRect = action.frame
            .offsetBy(dx: -state.frame.minX, dy: -state.frame.minY)
            .applying(scale).integral
        let actionImage = UIImage(cgImage: try XCTUnwrap(source.cropping(to: actionRect)))

        XCTAssertLessThan(toast.frame.width, state.frame.width - 48)
        XCTAssertLessThanOrEqual(toast.frame.height, 60)
        XCTAssertLessThanOrEqual(toast.frame.maxY, composer.frame.minY)
        XCTAssertGreaterThanOrEqual(action.frame.height, 44)
        XCTAssertEqual(action.label, "Undo deletion")
        XCTAssertTrue(
            hasDarkLabelOnLightBackground(actionImage),
            "The Undo label must contrast with its light button background in dark mode."
        )
        let actionAttachment = XCTAttachment(
            data: try XCTUnwrap(actionImage.pngData()), uniformTypeIdentifier: "public.png"
        )
        actionAttachment.name = "Filled toast action"
        actionAttachment.lifetime = .keepAlways
        add(actionAttachment)
        let proof = XCTAttachment(screenshot: screenshot)
        proof.name = "Delete toast above compact controls"
        proof.lifetime = .keepAlways
        add(proof)
    }

    private func deleteSnipAndCaptureToast(
        named text: String, in app: XCUIApplication
    ) throws -> (state: any XCUIElementSnapshot, screenshot: XCUIScreenshot) {
        let snip = row(named: text, in: app)
        XCTAssertTrue(snip.waitForExistence(timeout: 3))
        let snipID = snip.identifier
        try visibleTouchCenter(of: snip, in: app).press(forDuration: 1)
        app.buttons["delete-context-snip"].tap()
        // Live AX queries can outlast transient feedback on Simulator.
        let screenshot = XCUIScreen.main.screenshot()
        let state = try app.snapshot()
        XCTAssertTrue(matchingSnapshots(identifiedBy: snipID, in: state).isEmpty)
        _ = try capturedSnapshot(identifiedBy: "app-toast", in: state)
        return (state, screenshot)
    }

    private func capturedSnapshot(
        identifiedBy identifier: String, in state: any XCUIElementSnapshot
    ) throws -> any XCUIElementSnapshot {
        let matches = matchingSnapshots(identifiedBy: identifier, in: state)
        XCTAssertEqual(matches.count, 1, "The captured interface must contain one \(identifier).")
        return try XCTUnwrap(matches.first)
    }

    private func matchingSnapshots(
        identifiedBy identifier: String, in state: any XCUIElementSnapshot
    ) -> [any XCUIElementSnapshot] {
        var matches: [any XCUIElementSnapshot] = state.identifier == identifier ? [state] : []
        for child in state.children {
            matches += matchingSnapshots(identifiedBy: identifier, in: child)
        }
        return matches
    }

    func testDeleteToastStaysAboveSearchToolbar() throws {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Search after deleting", in: app)

        let snip = row(named: "Search after deleting", in: app)
        XCTAssertTrue(snip.waitForExistence(timeout: 3))
        try visibleTouchCenter(of: snip, in: app).press(forDuration: 1)
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

    func testSearchDoesNotExtendDeleteUndoWindow() throws {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Undo expires", in: app)

        let snip = row(named: "Undo expires", in: app)
        try visibleTouchCenter(of: snip, in: app).press(forDuration: 1)
        app.buttons["delete-context-snip"].tap()
        let deletedAt = Date()

        let toast = app.descendants(matching: .any)["app-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        app.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields["Search"].waitForExistence(timeout: 3))
        XCTAssertTrue(toast.exists)
        let remaining = deletedAt.addingTimeInterval(7).timeIntervalSinceNow
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        XCTAssertFalse(toast.exists)
    }

    private func hasDarkLabelOnLightBackground(_ image: UIImage) -> Bool {
        guard let source = image.cgImage else { return false }
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
            let darkPixels = pointer.lazy.filter { $0 < 128 }.count
            return darkPixels > 0 && darkPixels * 2 < pointer.count
        }
    }

    func testDoneSnackbarUndoReopensTheSnip() {
        let app = launchApp()
        createSnip("Undo marking Done", in: app)
        let snipID = row(named: "Undo marking Done", in: app).identifier
        let snip = activeSnipRows(in: app).matching(identifier: snipID).firstMatch
        snip.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.2)).tap()
        let done = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Done"), object: snip
        )
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 3), .completed)
        let action = app.buttons["toast-action"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertEqual(action.label, "Undo marking Done")
        action.tap()
        let reopened = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Not Done"), object: snip
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 3), .completed)
        XCTAssertFalse(action.exists)
    }

    func testDoneUndoRemainsActionableInSettings() {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Undo while Settings is open", in: app)
        let snipID = row(named: "Undo while Settings is open", in: app).identifier
        activeSnipRows(in: app).matching(identifier: snipID).firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.2)).tap()

        openSettings(in: app)

        let undo = app.buttons["toast-action"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2))
        XCTAssertEqual(app.buttons.matching(identifier: "toast-action").count, 1)
        XCTAssertTrue(undo.isHittable)
        XCTAssertEqual(undo.label, "Undo marking Done")
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.switches["haptics-toggle"].exists)
        app.navigationBars.buttons["Done"].tap()
        let reopened = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Not Done"), object: activeSnipRows(in: app).matching(identifier: snipID).firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 3), .completed)
    }

    func testTappingCompletionCircleTogglesWithoutEditingOrSelecting() throws {
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
        try visibleTouchCenter(of: row(named: "Tap the completion circle", in: app), in: app).tap()
        XCTAssertTrue(app.buttons["selection-actions"].isEnabled)
        XCTAssertTrue(collectionRow(named: "Tap the completion circle", in: app).waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "1 item")
        app.buttons["finish-selecting"].tap()
        XCTAssertTrue(collectionRow(named: "Tap the completion circle", in: app).waitForExistence(timeout: 3))
        XCTAssertEqual(row(named: "Tap the completion circle", in: app).value as? String, "Not Done")
    }

    func testAttachmentListImagePreviewAndSwipeDismiss() throws {
        continueAfterFailure = false
        let app = launchApp(withAttachments: true)
        let compactPreview = app.buttons["compact-attachment-preview-sample.png"]
        XCTAssertTrue(compactPreview.waitForExistence(timeout: 5))
        let rowProof = XCTAttachment(screenshot: app.screenshot())
        rowProof.name = "Attachment image preview in list"
        rowProof.lifetime = .keepAlways
        add(rowProof)
        try visibleTouchCenter(of: compactPreview, in: app).tap()
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

    func testLocalAttachmentsPreviewRemoveAndSurviveRelaunch() throws {
        continueAfterFailure = false
        let storeName = "attachments-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName, withAttachments: true)

        let compactPreview = app.buttons["compact-attachment-preview-sample.png"]
        XCTAssertTrue(compactPreview.waitForExistence(timeout: 5))
        try visibleTouchCenter(of: compactPreview, in: app).tap()
        let fullScreenImage = app.images["Image preview"]
        XCTAssertTrue(fullScreenImage.waitForExistence(timeout: 5))
        app.buttons["dismiss-attachment-image"].tap()
        XCTAssertTrue(fullScreenImage.waitForNonExistence(timeout: 3))

        try openAttachmentFixture(in: app)
        let imagePreview = app.buttons["attachment-row-sample.png"]
        XCTAssertTrue(imagePreview.waitForExistence(timeout: 5))
        let textPreview = app.buttons["attachment-row-notes.txt"]
        XCTAssertTrue(textPreview.waitForExistence(timeout: 3))
        try visibleTouchCenter(of: imagePreview, in: app).tap()
        XCTAssertTrue(fullScreenImage.waitForExistence(timeout: 5))
        app.buttons["dismiss-attachment-image"].tap()
        XCTAssertTrue(fullScreenImage.waitForNonExistence(timeout: 3))

        try visibleTouchCenter(of: textPreview, in: app).tap()
        let preview = app.otherElements["QLPreviewControllerView"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        dismissQuickLook(preview, in: app)
        XCTAssertFalse(preview.waitForExistence(timeout: 3))

        let imageRow = app.buttons["attachment-row-sample.png"]
        XCTAssertTrue(imageRow.waitForExistence(timeout: 3))
        let removeAttachment = app.buttons["remove-attachment-sample.png"]
        XCTAssertTrue(removeAttachment.waitForExistence(timeout: 3))
        try visibleTouchCenter(of: removeAttachment, in: app).tap()
        XCTAssertTrue(
            imageRow.waitForNonExistence(timeout: 3),
            "The editor did not remove the attachment before saving."
        )
        try saveInlineEditor(in: app)
        let savedRow = row(named: "Attachment fixture", in: app)
        XCTAssertTrue(savedRow.label.contains("notes.txt"))
        XCTAssertFalse(savedRow.label.contains("sample.png"))

        app.terminate()
        app = launchApp(storeName: storeName, withAttachments: true)
        try openAttachmentFixture(in: app)
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

    private func openAttachmentFixture(in app: XCUIApplication) throws {
        let fixtureRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Attachment fixture")
        ).firstMatch
        XCTAssertTrue(fixtureRow.waitForExistence(timeout: 5))
        try visibleTouchCenter(of: fixtureRow, in: app).press(forDuration: 1)
        let editAttachments = app.buttons["edit-snip"]
        XCTAssertTrue(editAttachments.waitForExistence(timeout: 3))
        editAttachments.tap()
        XCTAssertTrue(app.descendants(matching: .any)["inline-snip-text"].waitForExistence(timeout: 3))
    }

    private func openCopyShareFixture(matching text: String, in app: XCUIApplication) throws {
        if app.navigationBars["Snip"].exists, app.buttons["BackButton"].exists {
            app.buttons["BackButton"].tap()
        }
        let fixture = activeSnipRows(in: app).matching(
            NSPredicate(format: "label CONTAINS %@", text)
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5))
        let viewport = activeSnipViewport(in: app)
        for _ in 0..<3 where !hasVisibleTouchTarget(fixture, within: viewport, in: app) {
            if fixture.frame.midY < viewport.frame.minY {
                viewport.swipeDown()
            } else {
                viewport.swipeUp()
            }
        }
        try visibleTouchCenter(of: fixture, clippedTo: viewport.frame, in: app)
            .press(forDuration: 1)
    }

    private func chooseDetailAction(_ identifier: String, in app: XCUIApplication) {
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        action.tap()
    }

    private func assertCopyStatus(_ label: String, in app: XCUIApplication) {
        let expected: String
        switch label {
        case "Copied Text": expected = "Text copied"
        case "Copied Attachments": expected = "Attachments copied"
        case "Copied 2 snips": expected = "2 snips snapped"
        default: expected = "Snapped"
        }
        let status = app.descendants(matching: .any)
            .matching(identifier: "app-toast")
            .matching(NSPredicate(format: "label CONTAINS %@", expected))
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
        assertShareExtensionStarted(in: safari)
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
        waitForAppStartup(in: app)
        return app
    }

    private func shareURLFromSafari(token: String) -> XCUIApplication {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        guard let fixtureBase = ProcessInfo.processInfo.environment["SNIP_SNAP_SHARE_FIXTURE_URL"],
              var components = URLComponents(string: fixtureBase),
              components.scheme == "http", components.host == "127.0.0.1",
              let port = components.port, (1...65535).contains(port)
        else {
            XCTFail("Run Share tests through scripts/run.sh or scripts/release-matrix-tests.sh to supply their local fixture URL.")
            return safari
        }
        components.fragment = token
        guard let fixtureURL = components.url else {
            XCTFail("The supplied Share fixture URL is invalid.")
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
            let more = safari.buttons["MoreMenuButton"].firstMatch
            XCTAssertTrue(
                more.waitForExistence(timeout: 5),
                "Safari did not expose its Share button or More menu."
            )
            more.tap()
            share = safari.buttons["Share"].firstMatch
        }
        if !share.waitForExistence(timeout: 12) {
            let more = safari.buttons["MoreMenuButton"].firstMatch
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

    private func assertShareExtensionStarted(in host: XCUIApplication) {
        let surface = host.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier IN %@",
                ["share-loading", "share-text", "share-storage-unavailable", "share-error"]
            )
        ).firstMatch
        XCTAssertTrue(
            surface.waitForExistence(timeout: 15),
            "The selected \(shareAppName) extension did not present its interface."
        )
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
        let results = app.buttons.matching(NSPredicate(
            format: "identifier MATCHES %@ AND enabled == true",
            "search-snip-[0-9A-Fa-f-]{36}"
        ))
        for text in ["Alpha inbox", "Alpha work"] {
            let result = results.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 3))
            XCTAssertTrue(result.isHittable)
        }
        XCTAssertTrue(app.staticTexts["Inbox"].exists)
        XCTAssertTrue(app.staticTexts["Work"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["list-selector"].exists)
        closeSearch(in: app)
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["list-selector"].exists)
        XCTAssertTrue(app.buttons["clipboard-tab"].isSelected)
    }

    func testSearchDoneFilter() throws {
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
        let completion = copied.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "completion-")
        ).firstMatch
        try visibleTouchCenter(of: completion, in: app).tap()
        let becameDone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Done"),
            object: copied
        )
        XCTAssertEqual(XCTWaiter.wait(for: [becameDone], timeout: 3), .completed)
        workflowOptions.tap()
        let doneFilter = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).element
        XCTAssertTrue(doneFilter.waitForExistence(timeout: 3))
        doneFilter.tap()
        XCTAssertTrue(doneFilter.waitForNonExistence(timeout: 3),
                      "Choosing Done must dismiss the View options menu.")
        let filteredContents = selectedListContents(in: app)
        XCTAssertTrue(collectionRow(named: "Copy text fixture", in: filteredContents).waitForExistence(timeout: 3))
        XCTAssertFalse(collectionRow(named: "Copy mixed fixture", in: filteredContents).exists)

    }

    func testGlassSelectionMenuShowsPinnedCompletionAsDisabled() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        let names = ["Sketch a simpler selection flow", "Try the stack interaction on iPhone"]
        for name in names {
            let snip = row(named: name, in: app)
            XCTAssertTrue(snip.waitForExistence(timeout: 5))
            try visibleTouchCenter(of: snip, in: app).press(forDuration: 1)
            app.buttons["Pin"].tap()
        }
        enterSelection(in: app)
        for name in names { try visibleTouchCenter(of: row(named: name, in: app), in: app).tap() }
        try visibleTouchCenter(of: app.buttons["selection-actions"], in: app).tap()
        let markDone = app.buttons["mark-selection-done"]
        XCTAssertTrue(markDone.waitForExistence(timeout: 3))
        XCTAssertFalse(markDone.isEnabled)
        XCTAssertTrue(app.buttons["merge-selection"].isEnabled)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Shared glass disabled selection action"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testGlassSelectionMenuDismissesWithoutLosingGatheredSnips() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(compactListTab(named: "Archive", in: app).waitForExistence(timeout: 5))
        compactListTab(named: "Inbox", in: app).press(forDuration: 0.7)
        let manager = app.descendants(matching: .any)["list-management-panel"]
        XCTAssertTrue(manager.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Lists"].exists)
        XCTAssertFalse(app.staticTexts["Drag to reorder"].exists)
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["Edit Work"], in: app))
        let listProof = XCTAttachment(screenshot: app.screenshot())
        listProof.name = "Shared glass list manager"
        listProof.lifetime = .keepAlways
        add(listProof)
        app.buttons["list-management-close"].tap()
        XCTAssertTrue(manager.waitForNonExistence(timeout: 3))
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
        try visibleTouchCenter(of: app.buttons["selection-actions"], in: app).tap()
        let menu = app.descendants(matching: .any)["selection-actions-panel"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["merge-selection"], in: app))
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
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["move-gathered-to-Work"], in: app))
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
        try visibleTouchCenter(of: app.buttons["selection-actions"], in: app).tap()
        XCTAssertTrue(app.buttons["mark-selection-done"].waitForExistence(timeout: 3))
        app.buttons["mark-selection-done"].tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 5))
        XCTAssertEqual(row(named: "Sketch a simpler selection flow", in: app).value as? String, "Done")
        XCTAssertEqual(row(named: "Try the stack interaction on iPhone", in: app).value as? String, "Done")
    }

    func testMergesSelectedSnips() throws {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("First merge note", in: app)
        createSnip("Second merge note", in: app)
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "First merge note", in: app), in: app).tap()
        try visibleTouchCenter(of: row(named: "Second merge note", in: app), in: app).tap()
        try visibleTouchCenter(of: app.buttons["selection-actions"], in: app).tap()
        XCTAssertTrue(app.buttons["merge-selection"].waitForExistence(timeout: 3))
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "iOS Merge Snips menu"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["merge-selection"].tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
        let merged = activeSnipRows(in: app)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged.firstMatch.label.contains("First merge note"))
        XCTAssertTrue(merged.firstMatch.label.contains("Second merge note"))
    }

    func testSelectionSurvivesFilteringItsSourceRows() throws {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Filter this selection", in: app)
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Filter this selection", in: app), in: app).tap()
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
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
    }

    func testLongPressSelectsItemAndShowsSeparateClose() throws {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Select this note", in: app)
        createSnip("Leave this note", in: app)

        try visibleTouchCenter(of: row(named: "Select this note", in: app), in: app).press(forDuration: 1)
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

    func testLongPressAddsAnotherItemToExpandedSelection() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        let stack = app.buttons["gathered-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        stack.tap()
        XCTAssertTrue(app.scrollViews["gathered-contents"].waitForExistence(timeout: 3))

        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).press(forDuration: 1)
        let select = app.buttons["select-snip"]
        XCTAssertTrue(select.waitForExistence(timeout: 3), "Select must remain available while selecting other items.")
        select.tap()
        let newest = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Try the stack interaction on iPhone")).firstMatch
        let previous = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Sketch a simpler selection flow")).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertEqual(app.scrollViews["gathered-contents"].value as? String, "2 items")
        XCTAssertLessThan(newest.frame.minY, previous.frame.minY)
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
    }

    func testGatheredHeaderCopiesAndDeletesWithoutOpeningMore() throws {
        continueAfterFailure = false
        let storeName = "gather-header-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName, withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()

        let copyReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.hasVisibleTouchTarget(app.buttons["copy-selection"], in: app) },
            object: app.buttons["copy-selection"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [copyReady], timeout: 5), .completed)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Four icon actions in the gathered container"
        proof.lifetime = .keepAlways
        add(proof)
        try visibleTouchCenter(of: app.buttons["copy-selection"], in: app).tap()
        assertCopyStatus("Copied 2 snips", in: app)
        let delete = app.buttons["delete-selection"]
        let deleteIsVisible = hasVisibleTouchTarget(delete, in: app)
        if !deleteIsVisible { attachUIState("Gathered actions after copy confirmation", in: app) }
        XCTAssertTrue(deleteIsVisible)
        let toast = app.descendants(matching: .any)["app-toast"]
        XCTAssertTrue(toast.exists, "The copy confirmation must remain visible while gathered actions are available.")
        XCTAssertFalse(toast.frame.intersects(delete.frame), "The copy confirmation must leave gathered actions clear.")
        let copyFeedback = XCTAttachment(screenshot: app.screenshot())
        copyFeedback.name = "Copy confirmation leaves gathered actions reachable"
        copyFeedback.lifetime = .keepAlways
        add(copyFeedback)
        try visibleTouchCenter(of: delete, in: app).tap()
        XCTAssertTrue(app.buttons["gathered-stack"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
        XCTAssertFalse(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)

        app.terminate()
        app = launchApp(storeName: storeName)
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 5))
        XCTAssertFalse(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
        XCTAssertFalse(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
    }

    func testGatheredContainerExpandsInlineAndCollapses() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
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
            XCTAssertTrue(hasVisibleTouchTarget(app.buttons[identifier], in: app),
                          "Keep the existing header actions available while expanded.")
        }
        try visibleTouchCenter(of: app.buttons["copy-selection"], in: app).tap()
        assertCopyStatus("Copied 2 snips", in: app)
        XCTAssertTrue(app.scrollViews["gathered-contents"].exists,
                      "Copying must keep the expanded selection open.")
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

    func testSelectedCardKeepsAttachmentContentAndPreview() throws {
        continueAfterFailure = false
        let app = launchApp(withAttachments: true)
        let preview = app.buttons["compact-attachment-preview-sample.png"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let sourceProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sourceProof.name = "Shared content in source list"
        sourceProof.lifetime = .keepAlways
        add(sourceProof)
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Attachment fixture", in: app), in: app).tap()
        let stack = app.buttons["gathered-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 3))
        let closedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        closedProof.name = "Shared content in collapsed card"
        closedProof.lifetime = .keepAlways
        add(closedProof)
        stack.tap()
        let contents = app.scrollViews["gathered-contents"]
        XCTAssertTrue(hasVisibleTouchTarget(contents, in: app))
        XCTAssertTrue(contents.buttons["compact-attachment-preview-sample.png"].waitForExistence(timeout: 3))
        XCTAssertTrue(contents.buttons["compact-attachment-preview-notes.txt"].exists)
        let expandedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expandedProof.name = "Shared content in expanded card"
        expandedProof.lifetime = .keepAlways
        add(expandedProof)
        try visibleTouchCenter(of: contents.buttons["compact-attachment-preview-sample.png"], clippedTo: contents.frame, in: app).tap()
        let image = app.images["Image preview"]
        XCTAssertTrue(image.waitForExistence(timeout: 3))
        app.buttons["dismiss-attachment-image"].tap()
        XCTAssertTrue(image.waitForNonExistence(timeout: 3))
        try visibleTouchCenter(of: app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Attachment fixture")).firstMatch, in: app).tap()
        XCTAssertTrue(app.staticTexts["gathering-instructions"].waitForExistence(timeout: 3))
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        try visibleTouchCenter(of: preview, in: app).tap()
        XCTAssertTrue(image.waitForExistence(timeout: 3))
        app.buttons["dismiss-attachment-image"].tap()
    }

    func testGatheredCardsKeepLayoutAndReturnTopItemWhileCollapsed() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        let preview = app.scrollViews["gathered-preview"]
        XCTAssertTrue(preview.exists)
        XCTAssertTrue(app.staticTexts["gathering-instructions"].exists)
        let emptyFrame = preview.frame
        let emptyHeaderY = app.buttons["finish-selecting"].frame.midY
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "completion-")).firstMatch.exists)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        XCTAssertEqual(preview.frame.height, emptyFrame.height, accuracy: 1)
        XCTAssertEqual(preview.frame.minY, emptyFrame.minY, accuracy: 1)
        XCTAssertEqual(app.buttons["finish-selecting"].frame.midY, emptyHeaderY, accuracy: 1)
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
        let stack = app.buttons["gathered-stack"]
        let putBackIdentifier = app.buttons.matching(
            NSPredicate(format: "label == %@", "Deselect: Try the stack interaction on iPhone")
        ).firstMatch.identifier
        XCTAssertTrue(putBackIdentifier.hasPrefix("put-back-"))
        let putBack = app.buttons[putBackIdentifier]
        XCTAssertTrue(hasVisibleTouchTarget(putBack, within: preview, in: app))
        let contentIdentifier = putBackIdentifier.replacingOccurrences(of: "put-back-", with: "selected-card-content-")
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
        try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app).tap()
        XCTAssertEqual(cardContent.frame.height, closedTextFrame.height, accuracy: 1)
        XCTAssertTrue(hasVisibleTouchTarget(putBack, within: preview, in: app))
        try visibleTouchCenter(of: putBack, clippedTo: preview.frame, in: app).tap()
        XCTAssertEqual(stack.value as? String, "1 item")
        let returned = collectionRow(named: "Try the stack interaction on iPhone", in: app)
            .waitForExistence(timeout: 3)
        if !returned { attachUIState("Collapsed card after return", in: app) }
        XCTAssertTrue(returned)
        let remainingReturn = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Sketch a simpler selection flow")).firstMatch
        XCTAssertTrue(hasVisibleTouchTarget(remainingReturn, within: preview, in: app))
        try visibleTouchCenter(of: remainingReturn, clippedTo: preview.frame, in: app).tap()
        XCTAssertTrue(app.staticTexts["gathering-instructions"].waitForExistence(timeout: 3))
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
        for _ in 0..<3 {
            stack.tap()
            try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app).tap()
        }
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
    }

    func testCollapsedSelectionFitsPromotedShorterCard() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        let longText = Array(repeating: "A longer selected item keeps its full multiline text.", count: 12).joined(separator: " ")
        createSnip(longText, in: app)
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        let stack = app.buttons["gathered-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        let shortHeight = app.scrollViews["gathered-preview"].frame.height
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        stack.tap()
        let longRow = row(named: longText, in: app)
        XCTAssertTrue(longRow.identifier.hasPrefix("snip-"))
        let returnIdentifier = "put-back-" + longRow.identifier.dropFirst("snip-".count)
        try visibleTouchCenter(of: longRow, in: app).tap()
        let returnLong = app.buttons[returnIdentifier]
        XCTAssertTrue(returnLong.waitForExistence(timeout: 5))
        try visibleTouchCenter(of: returnLong, clippedTo: app.scrollViews["gathered-contents"].frame, in: app).tap()
        try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app).tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertEqual(app.scrollViews["gathered-preview"].frame.height, shortHeight, accuracy: 2,
                       "Promoting a mounted shorter card must resize the collapsed viewport.")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Collapsed selection fits promoted shorter card"
        proof.lifetime = .keepAlways
        add(proof)
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(collectionRow(named: longText, in: app).exists)
    }

    func testAddingToScrolledExpandedSelectionRevealsLatestItem() throws {
        continueAfterFailure = false
        let app = launchApp(withLongList: true)
        enterSelection(in: app)
        for index in stride(from: 23, through: 18, by: -1) {
            try visibleTouchCenter(of: row(named: "Fixture \(index)", in: app), in: app).tap()
        }
        let stack = app.buttons["gathered-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        stack.tap()
        let contents = app.scrollViews["gathered-contents"]
        let earlier = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Fixture 23")).firstMatch
        for _ in 0..<6 where !hasVisibleTouchTarget(earlier, within: contents, in: app) { contents.swipeUp() }
        XCTAssertTrue(hasVisibleTouchTarget(earlier, within: contents, in: app))
        try visibleTouchCenter(of: row(named: "Fixture 17", in: app), in: app).tap()
        let latest = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Fixture 17")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertTrue(hasVisibleTouchTarget(latest, within: contents, in: app), "A new selection must land in the expanded viewport after scrolling. Card: \(latest.frame); viewport: \(contents.frame); visible in app: \(hasVisibleTouchTarget(latest, in: app)).")
        XCTAssertEqual(contents.value as? String, "7 items")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "New item lands after scrolling selected cards"
        proof.lifetime = .keepAlways
        add(proof)
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(collectionRow(named: "Fixture 17", in: app).exists)
        XCTAssertTrue(collectionRow(named: "Fixture 23", in: app).exists)
    }

    func testExpandedGatheredContainerScrollsAndReturnsAll() throws {
        try verifyExpandedSelectionScrollsAndReturnsAll(withAttachments: false)
    }

    func testExpandedSelectedAttachmentCardsScrollAndReturnAll() throws {
        try verifyExpandedSelectionScrollsAndReturnsAll(withAttachments: true)
    }

    private func verifyExpandedSelectionScrollsAndReturnsAll(withAttachments: Bool) throws {
        continueAfterFailure = false
        let app = launchApp(withAttachments: withAttachments, withLongList: true)
        XCTAssertTrue(collectionRow(named: "Fixture 23", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        for index in stride(from: 23, through: 0, by: -1) {
            try visibleTouchCenter(of: row(named: index == 0 ? "Fixture oldest" : "Fixture \(index)", in: app), in: app).tap()
        }
        let stack = app.buttons["gathered-stack"]
        XCTAssertEqual(stack.value as? String, "24 items")
        stack.tap()
        let contents = app.scrollViews["gathered-contents"]
        XCTAssertTrue(hasVisibleTouchTarget(contents, in: app))
        let oldest = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Fixture 23")).firstMatch
        for _ in 0..<32 where !hasVisibleTouchTarget(oldest, within: contents, in: app) { contents.swipeUp() }
        XCTAssertTrue(hasVisibleTouchTarget(oldest, within: contents, in: app), "Expanded selected cards remain scrollable.")
        if withAttachments {
            let cardIdentifier = oldest.identifier.replacingOccurrences(of: "put-back-", with: "selected-card-content-")
            let preview = contents.descendants(matching: .any)[cardIdentifier]
                .buttons["compact-attachment-preview-sample.png"]
            // Reaching the leading control can leave its thumbnail below the viewport.
            for _ in 0..<6 where !hasVisibleTouchTarget(preview, within: contents, in: app) { contents.swipeUp() }
            XCTAssertTrue(hasVisibleTouchTarget(preview, within: contents, in: app))
            try visibleTouchCenter(of: preview, clippedTo: contents.frame, in: app).tap()
            XCTAssertTrue(app.images["Image preview"].waitForExistence(timeout: 3))
            app.buttons["dismiss-attachment-image"].tap()
            XCTAssertTrue(app.images["Image preview"].waitForNonExistence(timeout: 3))
        }
        let expandedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expandedProof.name = "Last of 24 selected cards"
        expandedProof.lifetime = .keepAlways
        add(expandedProof)
        try visibleTouchCenter(of: oldest, clippedTo: contents.frame, in: app).tap()
        try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app).tap()
        XCTAssertEqual(stack.value as? String, "23 items")
        stack.tap()
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["collapse-gathered"].exists)
        XCTAssertTrue(collectionRow(named: "Fixture 23", in: app).exists)
        let returnedOldest = collectionRow(named: "Fixture oldest", in: app)
        let source = activeSnipViewport(in: app)
        for _ in 0..<32 where !hasVisibleTouchTarget(returnedOldest, within: source, in: app) { source.swipeUp() }
        XCTAssertTrue(hasVisibleTouchTarget(returnedOldest, within: source, in: app), "Deselect and Cancel return even the offscreen items to the source list.")
        let returnedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        returnedProof.name = "Last item restored to long source list"
        returnedProof.lifetime = .keepAlways
        add(returnedProof)
    }

    func testFilteredGatheredCopyThenMoveFinishesGathering() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        app.buttons["workflow-options"].tap()
        app.buttons["Not Done"].tap()
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        try visibleTouchCenter(of: app.buttons["copy-selection"], in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["app-toast"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "1 item")
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
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

    func testGatheredStackReturnsSnipsAndCancels() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)

        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForNonExistence(timeout: 3))
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
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
        XCTAssertTrue(hasVisibleTouchTarget(putBack, in: app))
        // Native automation can choose the card center instead of this leading control.
        let returnControl = putBack.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: min(44, putBack.frame.width) / 2,
            dy: min(44, putBack.frame.height) / 2
        ))
        returnControl.tap()
        let oneSelectedItem = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1 item"),
            object: app.descendants(matching: .any)["gathered-contents"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [oneSelectedItem], timeout: 3), .completed)
        try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app).tap()
        let returned = collectionRow(named: "Sketch a simpler selection flow", in: app)
            .waitForExistence(timeout: 3)
        if !returned { attachUIState("Gathered return after collapse", in: app) }
        XCTAssertTrue(returned)
        XCTAssertFalse(collectionRow(named: "Try the stack interaction on iPhone", in: app).exists)
        XCTAssertEqual(stack.value as? String, "1 item")
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(stack.exists)
    }

    func testSelectedStackStaysPutAndMovesFromMenu() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
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
        let inboxContents = selectedListContents(in: app)
        let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        proof.name = "Selected stack stays put after swipe"
        proof.lifetime = .keepAlways
        add(proof)
        stack.tap()
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["collapse-gathered"], in: app))
        try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app).tap()
        try visibleTouchCenter(of: app.buttons["move-gathered"], in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["selection-move-panel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["add-list-for-move"].waitForExistence(timeout: 3))
        let menuProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menuProof.name = "Move menu remains available"
        menuProof.lifetime = .keepAlways
        add(menuProof)
        let destination = app.buttons["move-gathered-to-Work"]
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        destination.tap()
        XCTAssertTrue(stack.waitForNonExistence(timeout: 5))
        XCTAssertTrue(compactListTab(named: "Inbox", in: app).isSelected)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: inboxContents).waitForNonExistence(timeout: 3))
        let work = listControl(named: "Work", in: app)
        if !work.isSelected { tapVisibleSelectorTab(work, in: app) }
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(work.isSelected)
        let workContents = selectedListContents(in: app)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: workContents).waitForExistence(timeout: 3))
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: workContents).exists)
    }

    func testGatheredStackMenuMovesAndPersists() throws {
        continueAfterFailure = false
        let storeName = "gather-move-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName, withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
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

    func testGatheredStackFitsAccessibilityText() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true, contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["gathered-stack"], in: app))
        for identifier in ["move-gathered", "copy-selection", "delete-selection", "selection-actions"] {
            XCTAssertTrue(hasVisibleTouchTarget(app.buttons[identifier], in: app))
            // Native geometry can represent 44 points as 43.99999999999994.
            XCTAssertGreaterThanOrEqual(app.buttons[identifier].frame.width, 44 - 0.01)
            XCTAssertGreaterThanOrEqual(app.buttons[identifier].frame.height, 44 - 0.01)
        }
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Gathered stack at largest accessibility text"
        proof.lifetime = .keepAlways
        add(proof)
        try visibleTouchCenter(of: app.buttons["gathered-stack"], in: app).tap()
        for identifier in ["move-gathered", "copy-selection", "delete-selection", "selection-actions", "collapse-gathered"] {
            XCTAssertTrue(hasVisibleTouchTarget(app.buttons[identifier], in: app))
            XCTAssertGreaterThanOrEqual(app.buttons[identifier].frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(app.buttons[identifier].frame.maxY, app.frame.maxY)
        }
        let contents = app.scrollViews["gathered-contents"]
        let text = contents.staticTexts["Try the stack interaction on iPhone"]
        XCTAssertTrue(text.exists)
        XCTAssertLessThanOrEqual(text.frame.minY + 44, contents.frame.maxY, "Keep at least a readable first line in the viewport.")
        let putBack = app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Try the stack interaction on iPhone")).firstMatch
        let putBackIsVisible = hasVisibleTouchTarget(putBack, within: contents, in: app)
        if !putBackIsVisible { attachUIState("Expanded gathered card with clipped Put-back", in: app) }
        XCTAssertTrue(putBackIsVisible)
        let expandedProof = XCTAttachment(screenshot: app.screenshot())
        expandedProof.name = "Expanded glass at largest accessibility text"
        expandedProof.lifetime = .keepAlways
        add(expandedProof)
        try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app).tap()
        try visibleTouchCenter(of: app.buttons["gathered-stack"], in: app).tap()
        XCTAssertTrue(hasVisibleTouchTarget(putBack, within: contents, in: app))
        try visibleTouchCenter(of: putBack, clippedTo: contents.frame, in: app).tap()
        XCTAssertTrue(app.staticTexts["gathering-instructions"].waitForExistence(timeout: 3))
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).waitForExistence(timeout: 3))
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).waitForExistence(timeout: 3))
    }

    func testGatheredStackRegathersAfterReturningLastSnipAndRotating() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        let stack = app.buttons["gathered-stack"]
        stack.tap()
        try visibleTouchCenter(of: app.buttons.matching(NSPredicate(format: "label == %@", "Deselect: Sketch a simpler selection flow")).firstMatch, in: app).tap()
        XCTAssertTrue(app.otherElements["gathering-instructions"].exists || app.staticTexts["gathering-instructions"].exists)
        XCTAssertTrue(app.buttons["finish-selecting"].exists)
        XCTAssertTrue(stack.waitForNonExistence(timeout: 3))
        XCUIDevice.shared.orientation = .landscapeLeft
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 3))
        XCTAssertEqual(stack.value as? String, "1 item")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Regathered after returning the last snip and rotating"
        proof.lifetime = .keepAlways
        add(proof)
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(collectionRow(named: "Try the stack interaction on iPhone", in: app).waitForExistence(timeout: 3))
    }

    func testGatheredStackFitsLandscape() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        // The short source viewport shows the newest row; scroll the older one
        // into view before selecting it, instead of tapping beneath the dock.
        row(named: "Try the stack interaction on iPhone", in: app).swipeUp()
        XCTAssertTrue(hasVisibleTouchTarget(row(named: "Sketch a simpler selection flow", in: app), within: activeSnipViewport(in: app), in: app))
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        let stack = app.buttons["gathered-stack"]
        XCTAssertTrue(hasVisibleTouchTarget(stack, in: app))
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["move-gathered"], in: app))
        stack.tap()
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["collapse-gathered"], in: app))
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["move-gathered"], in: app))
        let expandedProof = XCTAttachment(screenshot: app.screenshot())
        expandedProof.name = "Expanded glass in landscape"
        expandedProof.lifetime = .keepAlways
        add(expandedProof)
        try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app).tap()
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

    func testDragReordersAndPersistsWithoutSelection() throws {
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
        try visibleTouchCenter(of: restoredFirst, in: app).press(forDuration: 1)
        XCTAssertTrue(app.buttons["edit-snip"].waitForExistence(timeout: 3))
        let menuProof = XCTAttachment(screenshot: app.screenshot())
        menuProof.name = "Item menu after direct drag"
        menuProof.lifetime = .keepAlways
        add(menuProof)
    }

    func testSelectsManyMovesThemAndChangesManualOrder() throws {
        continueAfterFailure = false
        let storeName = "move-reorder-\(UUID().uuidString)"
        var app = launchApp(storeName: storeName)
        createList("Work", in: app)
        returnToLists(in: app)
        listControl(named: "Inbox", in: app).tap()
        createSnip("One", in: app)
        returnToCollection(in: app)
        createSnip("Two", in: app)
        returnToCollection(in: app)

        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "One", in: app), in: app).tap()
        try visibleTouchCenter(of: row(named: "Two", in: app), in: app).tap()
        app.buttons["move-gathered"].tap()
        app.buttons["move-gathered-to-Work"].tap()

        returnToLists(in: app)
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(app.staticTexts["One"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Two"].waitForExistence(timeout: 3))
        let one = activeSnipRows(in: app).matching(NSPredicate(format: "label BEGINSWITH %@", "One")).firstMatch
        let two = activeSnipRows(in: app).matching(NSPredicate(format: "label BEGINSWITH %@", "Two")).firstMatch
        XCTAssertLessThan(two.frame.minY, one.frame.minY)
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
        let reorderedResult = XCTWaiter.wait(for: [reordered], timeout: 5)
        XCTAssertEqual(reorderedResult, .completed)
        app.buttons["finish-reordering"].tap()
        app.terminate()
        app = launchApp(storeName: storeName)
        listControl(named: "Work", in: app).tap()
        let restoredOne = activeSnipRows(in: app).matching(NSPredicate(format: "label BEGINSWITH %@", "One")).firstMatch
        let restoredTwo = activeSnipRows(in: app).matching(NSPredicate(format: "label BEGINSWITH %@", "Two")).firstMatch
        XCTAssertTrue(restoredOne.waitForExistence(timeout: 3))
        XCTAssertLessThan(restoredOne.frame.minY, restoredTwo.frame.minY)
    }

    func testSelectionPersistsAcrossLists() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        listControl(named: "Work", in: app).tap()
        XCTAssertTrue(app.buttons["gathered-stack"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "1 item")
        listControl(named: "Inbox", in: app).tap()
        XCTAssertFalse(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 3))
    }

    func testPageSwipePreservesExpandedMultiListSelection() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        func selectableRow(named text: String) -> XCUIElement {
            // Inactive mounted pages can remain in XCTest's hierarchy. Select
            // the enabled row on the destination, then wait for motion to settle.
            let row = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH 'snip-' AND NOT identifier BEGINSWITH 'snip-text-' AND label BEGINSWITH %@ AND enabled == true",
                text
            )).firstMatch
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.hasVisibleTouchTarget(row, within: self.activeSnipViewport(in: app), in: app)
            }, object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            return row
        }
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        tapVisibleSelectorTab(listControl(named: "Work", in: app), in: app)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        createSnip("Work selection", in: app)
        returnToCollection(in: app)
        tapVisibleSelectorTab(listControl(named: "Inbox", in: app), in: app)
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        _ = try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app)
        enterSelection(in: app)
        try visibleTouchCenter(of: selectableRow(named: "Sketch a simpler selection flow"), in: app).tap()
        try visibleTouchCenter(of: app.buttons["gathered-stack"], in: app).tap()
        _ = try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app)

        let toWork = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3))
        toWork.press(forDuration: 0.05, thenDragTo: toWork.withOffset(CGVector(dx: -180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["collapse-gathered"], in: app))
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["Deselect: Sketch a simpler selection flow"], within: app.scrollViews["gathered-contents"], in: app))
        try visibleTouchCenter(of: selectableRow(named: "Work selection"), in: app).tap()
        try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app).tap()
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "2 items")
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["Deselect: Work selection"], within: app.scrollViews["gathered-preview"], in: app))
        try visibleTouchCenter(of: app.buttons["gathered-stack"], in: app).tap()
        _ = try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app)

        let toInbox = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        toInbox.press(forDuration: 0.05, thenDragTo: toInbox.withOffset(CGVector(dx: 180, dy: 0)))
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["collapse-gathered"], in: app))
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["Deselect: Work selection"], within: app.scrollViews["gathered-contents"], in: app))
        XCTAssertFalse(collectionRow(named: "Sketch a simpler selection flow", in: app).exists)
        try visibleTouchCenter(of: app.buttons["finish-selecting"], in: app).tap()
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 3))
        tapVisibleSelectorTab(listControl(named: "Work", in: app), in: app)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(collectionRow(named: "Work selection", in: app).waitForExistence(timeout: 3))
    }

    func testMultiListSelectionCreatesDestinationFromMoveMenu() throws {
        continueAfterFailure = false
        let app = launchApp(withGatheringFixtures: true)
        XCTAssertTrue(collectionRow(named: "Sketch a simpler selection flow", in: app).waitForExistence(timeout: 10))
        listControl(named: "Work", in: app).tap()
        createSnip("From Work", in: app)
        returnToCollection(in: app)
        listControl(named: "Inbox", in: app).tap()
        enterSelection(in: app)
        try visibleTouchCenter(of: row(named: "Sketch a simpler selection flow", in: app), in: app).tap()
        try visibleTouchCenter(of: row(named: "Try the stack interaction on iPhone", in: app), in: app).tap()
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["Deselect: Try the stack interaction on iPhone"], within: app.scrollViews["gathered-preview"], in: app))
        listControl(named: "Work", in: app).tap()
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "2 items")
        try visibleTouchCenter(of: row(named: "From Work", in: app), in: app).tap()
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "3 items")
        XCTAssertTrue(hasVisibleTouchTarget(app.buttons["Deselect: From Work"], within: app.scrollViews["gathered-preview"], in: app))
        let stackProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        stackProof.name = "Multi-list selection newest on top"
        stackProof.lifetime = .keepAlways
        add(stackProof)
        try visibleTouchCenter(of: app.buttons["gathered-stack"], in: app).tap()
        let expandedProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expandedProof.name = "Multi-list selection expanded"
        expandedProof.lifetime = .keepAlways
        add(expandedProof)
        try visibleTouchCenter(of: app.buttons["collapse-gathered"], in: app).tap()
        try visibleTouchCenter(of: app.buttons["move-gathered"], in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["selection-move-panel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["move-gathered-to-Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["add-list-for-move"].waitForExistence(timeout: 3))
        let menuProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menuProof.name = "Move destinations and Add List"
        menuProof.lifetime = .keepAlways
        add(menuProof)
        app.buttons["add-list-for-move"].tap()
        XCTAssertTrue(app.textFields["move-new-list-name"].waitForExistence(timeout: 3))
        app.buttons["cancel-create-move"].tap()
        XCTAssertEqual(app.buttons["gathered-stack"].value as? String, "3 items")
        try visibleTouchCenter(of: app.buttons["move-gathered"], in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["selection-move-panel"].waitForExistence(timeout: 3))
        app.buttons["add-list-for-move"].tap()
        let name = app.textFields["move-new-list-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Work")
        app.buttons["create-and-move"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["inline-operation-error"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["A list with that name already exists. Choose another name."].exists)
        XCTAssertEqual(name.value as? String, "Work")
        name.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        name.typeText("Selected notes")
        app.buttons["create-and-move"].tap()
        XCTAssertTrue(app.buttons["gathered-stack"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library-actions"].waitForExistence(timeout: 3))
        revealCompactList(named: "Selected notes", in: app)
        listControl(named: "Selected notes", in: app).tap()
        for text in ["From Work", "Sketch a simpler selection flow", "Try the stack interaction on iPhone"] {
            XCTAssertTrue(collectionRow(named: text, in: app).waitForExistence(timeout: 3))
        }
    }

    func testSingleItemMoveCanAddFirstCustomList() throws {
        continueAfterFailure = false
        let app = launchApp()
        createSnip("Move into a new list", in: app)
        returnToCollection(in: app)
        try visibleTouchCenter(of: row(named: "Move into a new list", in: app), in: app).press(forDuration: 1)
        app.buttons["move-snip"].tap()
        app.buttons["Add List…"].tap()
        let name = app.textFields["move-new-list-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("First list")
        app.buttons["create-and-move"].tap()
        let firstList = listControl(named: "First list", in: app)
        XCTAssertTrue(firstList.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["First list"].waitForExistence(timeout: 3))
        XCTAssertTrue(firstList.isSelected)
        let firstListContents = selectedListContents(in: app)
        XCTAssertTrue(collectionRow(named: "Move into a new list", in: firstListContents).waitForExistence(timeout: 3))
        let inbox = listControl(named: "Inbox", in: app)
        inbox.tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))
        XCTAssertTrue(inbox.isSelected)
        let inboxContents = selectedListContents(in: app)
        let absentFromInbox = collectionRow(named: "Move into a new list", in: inboxContents)
            .waitForNonExistence(timeout: 3)
        if !absentFromInbox { attachUIState("Single move after returning to Inbox", in: app) }
        XCTAssertTrue(absentFromInbox)
        firstList.tap()
        XCTAssertTrue(firstList.isSelected)
        XCTAssertTrue(collectionRow(named: "Move into a new list", in: firstListContents).waitForExistence(timeout: 3))
    }

    private func scrollToListAnchor(in app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(collectionRow(named: "Fixture 23", in: app).waitForExistence(timeout: 5))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68))
        start.press(forDuration: 0.05,
                    thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertFalse(collectionRow(named: "Fixture 23", in: app).exists)
        let anchor = collectionRow(named: "Fixture 17", in: app)
        XCTAssertTrue(anchor.exists)
        XCTAssertGreaterThan(anchor.frame.minY, app.navigationBars["Inbox"].frame.maxY)
        XCTAssertLessThan(anchor.frame.maxY, app.descendants(matching: .any)["composer-text"].frame.minY)
        return anchor
    }

    private func assertListAnchor(
        _ anchor: XCUIElement, at y: CGFloat, headerHeight: CGFloat, in app: XCUIApplication
    ) {
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            anchor.exists && abs(anchor.frame.minY - y) <= 3
                && abs(app.navigationBars["Inbox"].frame.height - headerHeight) <= 1
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 4), .completed,
                       "Returning to Inbox must preserve the visible snip position and native title state")
    }

    private func createSnip(_ text: String, in app: XCUIApplication) {
        let composer = app.descendants(matching: .any)["composer-text"].firstMatch
        if composer.waitForExistence(timeout: 1) {
            composer.tap()
            composer.typeText(text)
            let send = app.buttons["composer-send"]
            let sendReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard send.exists, send.isEnabled else { return false }
                let frame = send.frame
                guard !frame.isEmpty, app.frame.contains(frame) else { return false }
                let keyboard = app.keyboards.firstMatch
                return !keyboard.exists || frame.maxY <= keyboard.frame.minY
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [sendReady], timeout: 3), .completed)
            XCTAssertEqual(composer.value as? String, text)
            // XCTest can retain Send's hit point from before the keyboard appeared.
            send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            app.buttons["new-snip"].tap()
            let editor = app.textViews["snip-text"]
            XCTAssertTrue(editor.waitForExistence(timeout: 3))
            editor.tap()
            editor.typeText(text)
            app.buttons["save-snip"].tap()
        }
        XCTAssertTrue(collectionRow(named: text, in: selectedListContents(in: app)).waitForExistence(timeout: 3))
        dismissComposerKeyboard(in: app)
    }

    private func dismissComposerKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        app.swipeDown()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
    }

    private func saveInlineEditor(in app: XCUIApplication) throws {
        let save = app.buttons["inline-snip-save"]
        let list = app.collectionViews.containing(.any, identifier: "inline-snip-text").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        func visibleBounds() -> CGRect {
            let composer = app.descendants(matching: .any)["composer-text"].firstMatch
            let frame = list.frame.intersection(app.frame)
            guard composer.exists else { return frame }
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width,
                          height: max(0, min(frame.maxY, composer.frame.minY) - frame.minY))
        }
        for _ in 0..<3 where !visibleBounds().contains(save.frame) {
            let bounds = visibleBounds()
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: bounds.midX, dy: bounds.minY + bounds.height * 0.8)).press(
                forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: bounds.midX, dy: bounds.minY + bounds.height * 0.2))
            )
        }
        XCTAssertTrue(visibleBounds().contains(save.frame), "Save must be fully visible above the composer.")
        try visibleTouchCenter(of: save, clippedTo: visibleBounds(), in: app).tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 8), "The attachment edit did not finish saving.")
    }

    // Synthetic SwiftUI accessibility containers can lack an AX hit point even when touch works.
    private func visibleSearchResultTouchCenter(
        identifiedBy identifier: String, in app: XCUIApplication
    ) throws -> XCUICoordinate {
        var point: CGVector?
        var observations: [String] = []
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let began = ContinuousClock.now
            guard let state = try? app.snapshot() else {
                observations.append("Snapshot unavailable after \(began.duration(to: ContinuousClock.now)).")
                return false
            }
            let owners = self.matchingSnapshots(identifiedBy: "global-search-results", in: state)
            guard owners.count == 1, let owner = owners.first, owner.isEnabled else {
                observations.append("Search owners=\(owners.count), elapsed=\(began.duration(to: ContinuousClock.now)).")
                return false
            }
            let targets = self.matchingSnapshots(identifiedBy: identifier, in: owner)
            guard targets.count == 1, let target = targets.first else {
                observations.append("Target matches=\(targets.count), elapsed=\(began.duration(to: ContinuousClock.now)).")
                return false
            }
            let visible = target.frame.intersection(owner.frame).intersection(state.frame)
            observations.append("enabled=\(target.isEnabled), target=\(target.frame), visible=\(visible), elapsed=\(began.duration(to: ContinuousClock.now)).")
            guard target.isEnabled, !visible.isNull, !visible.isEmpty else { return false }
            point = CGVector(dx: visible.midX - state.frame.minX, dy: visible.midY - state.frame.minY)
            return true
        }, object: nil)
        let outcome = XCTWaiter.wait(for: [ready], timeout: 5)
        let evidence = XCTAttachment(string: observations.joined(separator: "\n"))
        evidence.name = "Search result snapshot readiness"
        evidence.lifetime = .keepAlways
        add(evidence)
        if outcome != .completed { attachUIState("Search result before editing", in: app) }
        XCTAssertEqual(outcome, .completed, "The search-owned result must be enabled and visible.")
        return app.coordinate(withNormalizedOffset: .zero).withOffset(try XCTUnwrap(point))
    }

    private func visibleTouchCenter(
        of element: XCUIElement,
        clippedTo bounds: CGRect? = nil,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUICoordinate {
        // SwiftUI glass controls can accept touch without a native AX hit point.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.hasVisibleTouchTarget(element, clippedTo: bounds, in: app)
        }, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed,
                       "The intended control must be enabled and visibly reachable.", file: file, line: line)
        let visibleFrame = element.frame.intersection(bounds ?? app.frame).intersection(app.frame)
        let point = try XCTUnwrap(
            visibleFrame.isNull || visibleFrame.isEmpty
                ? nil : CGPoint(x: visibleFrame.midX, y: visibleFrame.midY),
            "The intended touch target must intersect its visible container.",
            file: file, line: line
        )
        return app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)
        )
    }

    private func hasVisibleTouchTarget(
        _ element: XCUIElement,
        within viewport: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        guard viewport.exists else { return false }
        return hasVisibleTouchTarget(element, clippedTo: viewport.frame, in: app)
    }

    private func hasVisibleTouchTarget(
        _ element: XCUIElement,
        clippedTo bounds: CGRect? = nil,
        in app: XCUIApplication
    ) -> Bool {
        guard element.exists, element.isEnabled else { return false }
        let frame = element.frame
        let visible = frame.intersection(bounds ?? app.frame).intersection(app.frame)
        return !visible.isNull && !visible.isEmpty
    }

    private func ensureOnscreenKeyboard(
        for element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // XCTest text entry can leave the software keyboard offscreen until the next touch.
        var inputBounds = app.frame
        if let state = try? app.snapshot(), let keyboard = keyboardObservation(in: state).visibleFrame {
            inputBounds.size.height = max(0, keyboard.minY - inputBounds.minY)
        }
        try visibleTouchCenter(
            of: element, clippedTo: inputBounds, in: app, file: file, line: line
        ).tap()
        let identifier = element.identifier
        var lastObservation = "No input and keyboard snapshot was captured."
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let state = try? app.snapshot() else { return false }
            let inputs = self.matchingSnapshots(identifiedBy: identifier, in: state)
            let keyboard = self.keyboardObservation(in: state)
            let inputVisible = inputs.contains { $0.isEnabled && !$0.frame.isEmpty && state.frame.intersects($0.frame) }
            lastObservation = "input=\(identifier), visible=\(inputVisible), app=\(state.frame), keyboard=\(keyboard)"
            return inputVisible && keyboard.visibleFrame != nil
        }, object: nil)
        let ready = XCTWaiter.wait(for: [visible], timeout: 3)
        if ready != .completed { attachUIState("Keyboard after focusing input", in: app) }
        XCTAssertEqual(ready, .completed, lastObservation, file: file, line: line)
    }

    private struct KeyboardObservation {
        let rawFrames: [CGRect]
        let visibleFrame: CGRect?
    }

    private func keyboardObservation(in state: any XCUIElementSnapshot) -> KeyboardObservation {
        func frames(in node: any XCUIElementSnapshot) -> [CGRect] {
            (node.elementType == .keyboard ? [node.frame] : []) + node.children.flatMap { frames(in: $0) }
        }
        let rawFrames = frames(in: state)
        let bounds = state.frame
        let visibleFrames = rawFrames.compactMap { frame -> CGRect? in
            guard !frame.isEmpty else { return nil }
            if bounds.contains(frame) { return frame }
            // XCTest sometimes reports a landscape keyboard in portrait screen coordinates.
            let portraitBounds = CGRect(origin: bounds.origin, size: CGSize(width: bounds.height, height: bounds.width))
            guard bounds.width > bounds.height, portraitBounds.contains(frame) else { return nil }
            let local = frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            let rotated: CGRect
            switch XCUIDevice.shared.orientation {
            case .landscapeLeft:
                rotated = CGRect(x: local.minY, y: bounds.height - local.maxX,
                                 width: local.height, height: local.width)
            case .landscapeRight:
                rotated = CGRect(x: bounds.width - local.maxY, y: local.minX,
                                 width: local.height, height: local.width)
            default:
                return nil
            }
            let normalized = rotated.offsetBy(dx: bounds.minX, dy: bounds.minY)
            return bounds.contains(normalized) ? normalized : nil
        }
        return KeyboardObservation(rawFrames: rawFrames, visibleFrame: visibleFrames.count == 1 ? visibleFrames[0] : nil)
    }

    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
            "The intended control must be enabled and hittable before continuing.",
            file: file, line: line
        )
    }

    private func tapVisibleSelectorTab(
        _ tab: XCUIElement,
        in app: XCUIApplication,
        reselect: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if tab.exists, tab.isSelected, !reselect { return }
        guard !app.descendants(matching: .any)["list-management-panel"].exists,
              !app.textFields["list-name"].exists else {
            XCTFail("Selecting a list must not tap through a manager or list editor.", file: file, line: line)
            return
        }
        let selector = app.descendants(matching: .any)["list-selector"]
        guard selector.exists else {
            waitForHittable(tab, file: file, line: line)
            tab.tap()
            return
        }
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard tab.exists, tab.isEnabled, selector.exists else { return false }
            let target = tab.frame.intersection(selector.frame.insetBy(dx: 4, dy: 4))
            return target.width >= 12 && target.height >= 32
        }, object: tab)
        guard XCTWaiter.wait(for: [visible], timeout: 5) == .completed else {
            XCTFail("The intended tab must be visible inside the selector.", file: file, line: line)
            return
        }
        // Neighboring tabs keep full accessibility frames beyond the clipped
        // strip. Their centers can overlap Paste or Search; tap the visible part.
        let target = tab.frame.intersection(selector.frame.insetBy(dx: 4, dy: 4))
        selector.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: target.midX - selector.frame.minX,
            dy: target.midY - selector.frame.minY
        )).tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: tab
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [selected], timeout: 5), .completed,
            "The tapped selector tab must become the selected destination.",
            file: file, line: line
        )
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

    private func attachUIState(_ name: String, in app: XCUIApplication) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func closeSearch(in app: XCUIApplication) {
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Cancel Search", "close"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        let closeIsVisible = cancel.isHittable
        if !closeIsVisible { attachUIState("Search Close unavailable", in: app) }
        XCTAssertTrue(closeIsVisible, "Search Close must be visible before tapping it.")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
    }

    private func activeSnipViewport(in app: XCUIApplication) -> XCUIElement {
        app.collectionViews.matching(NSPredicate(format: "enabled == true")).firstMatch
    }

    private func activeSnipRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            format: "identifier MATCHES %@ AND enabled == true",
            "snip-[0-9A-Fa-f-]{36}"
        ))
    }

    private func row(named text: String, in app: XCUIApplication) -> XCUIElement {
        let row = activeSnipRows(in: app).matching(
            NSPredicate(format: "label BEGINSWITH %@", text)
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        return row
    }

    private func selectedListContents(in app: XCUIApplication) -> XCUIElement {
        let contents = app.collectionViews.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND enabled == true", "snip-list-"
        )).element
        XCTAssertTrue(contents.waitForExistence(timeout: 3))
        // Keep this list's identity when navigation makes its page inactive.
        return app.collectionViews[contents.identifier]
    }

    private func listContents(for tab: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(tab.waitForExistence(timeout: 3))
        let identifier = tab.identifier
        XCTAssertTrue(identifier.hasPrefix("list-tab-"))
        let listID = identifier.dropFirst("list-tab-".count)
        return app.collectionViews["snip-list-\(listID)"]
    }

    private func collectionRow(named text: String, in container: XCUIElement) -> XCUIElement {
        collectionRows(named: text, in: container).firstMatch
    }

    private func collectionRows(named text: String, in container: XCUIElement) -> XCUIElementQuery {
        container.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text))
    }

    private func requireCompactSelector(in app: XCUIApplication) throws {
        if app.descendants(matching: .any)["list-selector"].waitForExistence(timeout: 3) {
            return
        }
        guard app.navigationBars["Lists"].exists, app.buttons["list-Inbox"].exists else {
            XCTFail("The loaded library must expose either its compact selector or its sidebar.")
            return
        }
        throw XCTSkip("This workflow requires the compact library layout; the current window uses a sidebar.")
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
    private func revealCompactList(named name: String, in app: XCUIApplication, scrollLimit: Int = 24) {
        guard app.descendants(matching: .any)["list-selector"].exists else { return }
        var previousFrame: CGRect?
        for gesture in 0...scrollLimit {
            guard let state = try? app.snapshot() else {
                XCTFail("The selector snapshot was unavailable.")
                return
            }
            let manager = matchingSnapshots(identifiedBy: "list-management-panel", in: state)
                .filter { $0.isEnabled && $0.frame.intersects(state.frame) }
            let editor = matchingSnapshots(identifiedBy: "list-name", in: state)
                .filter { $0.isEnabled && $0.frame.intersects(state.frame) }
            let selectors = matchingSnapshots(identifiedBy: "list-selector", in: state)
            guard manager.isEmpty, editor.isEmpty, selectors.count == 1,
                  let selector = selectors.first, selector.isEnabled else {
                attachUIState("Selector ownership changed during reveal", in: app)
                XCTFail("List reveal must stop when a manager or editor replaces the selector.")
                return
            }
            func tabs(in node: any XCUIElementSnapshot) -> [any XCUIElementSnapshot] {
                (node.identifier.hasPrefix("list-tab-") || node.identifier == "clipboard-tab" ? [node] : [])
                    + node.children.flatMap { tabs(in: $0) }
            }
            let capturedTabs = tabs(in: selector)
            let targets = capturedTabs.filter { $0.label == name }
            let owners = capturedTabs.filter(\.isSelected)
            guard targets.count == 1, let target = targets.first, !target.frame.isEmpty,
                  owners.count == 1 else {
                attachUIState("Ambiguous selector during reveal", in: app)
                XCTFail("Reveal needs one destination and one selected owner in the same snapshot.")
                return
            }
            let clip = selector.frame.intersection(state.frame).insetBy(dx: 4, dy: 4)
            guard !clip.isEmpty, !clip.isNull else {
                XCTFail("The selector must have a visible gesture area.")
                return
            }
            let frame = target.frame
            if frame.minX >= clip.minX, frame.maxX <= clip.maxX,
               frame.intersection(clip).height >= 32 { return }
            guard gesture < scrollLimit, frame != previousFrame else {
                attachUIState("List reveal stopped making progress", in: app)
                XCTFail("List reveal stopped at gesture \(gesture)/\(scrollLimit): target=\(frame), previous=\(String(describing: previousFrame)), selector=\(selector.frame), owner=\(owners[0].identifier).")
                return
            }
            previousFrame = frame
            let towardRight = frame.minX < clip.minX
            // The selector contracts before XCTest dispatches; its center remains inside both widths.
            let startX = clip.midX
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: startX - state.frame.minX, dy: clip.midY - state.frame.minY
            ))
            let screen = state.frame.insetBy(dx: 4, dy: 4)
            let availableTravel = towardRight ? screen.maxX - startX : startX - screen.minX
            let dx = (towardRight ? 1 : -1) * min(clip.width * 0.8, availableTravel)
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
        for _ in 0..<3 {
            if actions.exists { break }
            if app.buttons["Show Sidebar"].exists {
                app.buttons["Show Sidebar"].tap()
            } else if app.buttons["BackButton"].exists {
                app.buttons["BackButton"].tap()
            } else if app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
        XCTAssertTrue(actions.exists || actions.waitForExistence(timeout: 5))
        actions.tap()
        let settings = app.buttons["settings"]
        XCTAssertTrue(settings.exists || settings.waitForExistence(timeout: 3))
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
        if save.exists, save.isEnabled, !save.frame.isEmpty, app.frame.intersects(save.frame) {
            var savePoint: CGVector?
            var lastObservation = "No footer snapshot was captured."
            let footerReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let state = try? app.snapshot() else {
                    lastObservation = "The application snapshot was unavailable."
                    return false
                }
                let matches = self.matchingSnapshots(identifiedBy: "save-list", in: state)
                    .filter { $0.elementType == .button }
                guard matches.count == 1, let button = matches.first else {
                    lastObservation = "Save footer snapshot matches: \(matches.count)."
                    return false
                }
                let frame = button.frame
                let keyboard = self.keyboardObservation(in: state)
                let isAboveKeyboard = keyboard.visibleFrame.map { frame.maxY <= $0.minY }
                    ?? keyboard.rawFrames.isEmpty
                lastObservation = "app=\(state.frame), save=\(frame), enabled=\(button.isEnabled), keyboard=\(keyboard)"
                guard button.isEnabled, !frame.isEmpty, state.frame.contains(frame), isAboveKeyboard else { return false }
                savePoint = CGVector(dx: frame.midX - state.frame.minX, dy: frame.midY - state.frame.minY)
                return true
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [footerReady], timeout: 3), .completed, lastObservation)
            if let savePoint {
                app.coordinate(withNormalizedOffset: .zero).withOffset(savePoint).tap()
            }
        } else {
            let done = app.keyboards.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 3))
            done.tap()
        }
        let editorClosed = field.waitForNonExistence(timeout: 5)
        if !editorClosed { attachUIState("List editor after Save", in: app) }
        XCTAssertTrue(editorClosed)
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
