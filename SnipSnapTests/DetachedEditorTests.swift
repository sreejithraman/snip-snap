import XCTest
@testable import SnipSnap

final class DetachedEditorTests: XCTestCase {
    @MainActor
    func testDetachedEditorSessionKeepsSaveErrorVisible() throws {
        let session = DetachedEditorSession(text: "Draft")

        XCTAssertEqual(try XCTUnwrap(session.beginSave()), "Draft")
        session.finishSave(errorMessage: "This snip changed in another window.")

        XCTAssertFalse(session.isSaving)
        XCTAssertEqual(session.errorMessage, "This snip changed in another window.")
        XCTAssertEqual(session.text, "Draft")
    }
}
