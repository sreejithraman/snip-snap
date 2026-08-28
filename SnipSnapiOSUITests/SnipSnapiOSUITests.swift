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

        let snipRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "A useful thought")
        ).firstMatch
        XCTAssertTrue(snipRow.waitForExistence(timeout: 3))
        snipRow.tap()
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
        XCTAssertTrue(workList.waitForExistence(timeout: 3))
        workList.tap()
        app.buttons["new-snip"].tap()
        let editor = app.textViews["snip-text"]
        editor.tap()
        editor.typeText("Move this")
        app.buttons["save-snip"].tap()

        let moveRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Move this")
        ).firstMatch
        XCTAssertTrue(moveRow.waitForExistence(timeout: 3))
        moveRow.tap()
        app.buttons["move-snip"].tap()
        app.buttons["move-to-Inbox"].tap()
        if !app.navigationBars["Inbox"].waitForExistence(timeout: 1) {
            app.buttons["BackButton"].tap()
        }
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 3))

        XCTAssertTrue(moveRow.waitForExistence(timeout: 3))
        moveRow.tap()
        app.buttons["delete-snip-detail"].tap()
        XCTAssertTrue(app.staticTexts["Choose a Snip"].waitForExistence(timeout: 3))
    }
}
