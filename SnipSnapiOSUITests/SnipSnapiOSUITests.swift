import XCTest

@MainActor
final class SnipSnapiOSUITests: XCTestCase {
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SNIP_SNAP_UI_TESTING"] = "1"
        app.launchEnvironment["SNIP_SNAP_UI_TEST_STORE"] = "ui-\(UUID().uuidString)"
        app.launch()
        return app
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
            app.buttons["BackButton"].tap()
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
        app.buttons["new-snip"].tap()
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
