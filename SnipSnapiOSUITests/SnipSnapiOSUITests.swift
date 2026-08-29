import XCTest

@MainActor
final class SnipSnapiOSUITests: XCTestCase {
    private func launchApp(
        storeName: String = "ui-\(UUID().uuidString)",
        withAttachments: Bool = false,
        withCopyShareFixtures: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SNIP_SNAP_UI_TESTING"] = "1"
        app.launchEnvironment["SNIP_SNAP_UI_TEST_STORE"] = storeName
        if withAttachments { app.launchEnvironment["SNIP_SNAP_UI_TEST_ATTACHMENTS"] = "1" }
        if withCopyShareFixtures {
            app.launchEnvironment["SNIP_SNAP_UI_TEST_COPY_SHARE"] = "1"
        }
        app.launch()
        return app
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
