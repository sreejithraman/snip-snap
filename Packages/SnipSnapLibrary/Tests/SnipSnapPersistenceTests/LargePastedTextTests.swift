import SnipSnapCore
import XCTest

final class LargePastedTextTests: XCTestCase {
    func testDoesNotAttachShortPaste() {
        XCTAssertFalse(LargePastedText.shouldAttach(String(repeating: "a", count: 1_999)))
    }

    func testAttachesAtTwoThousandCharacters() {
        XCTAssertTrue(LargePastedText.shouldAttach(String(repeating: "a", count: 2_000)))
    }

    func testInsertionInTheMiddleKeepsSurroundingText() {
        XCTAssertEqual(
            LargePastedText.insertion(from: "ac", to: "abc"),
            "b"
        )
    }

    func testReplacingAllTextCountsAsTheInsertion() {
        let pasted = String(repeating: "p", count: 2_000)
        XCTAssertEqual(
            LargePastedText.largeInsertion(from: "old", to: pasted),
            pasted
        )
    }

    func testTypingOneCharacterIsNotALargeInsertion() {
        XCTAssertNil(
            LargePastedText.largeInsertion(
                from: String(repeating: "a", count: 1_999),
                to: String(repeating: "a", count: 2_000)
            )
        )
    }

    func testFoldingMovesLargeContentIntoATextFile() throws {
        let existing = URL(fileURLWithPath: "/tmp/existing.png")
        let text = String(repeating: "p", count: LargePastedText.attachmentCharacterLimit)

        let folded = try LargePastedText.foldingIntoAttachments(
            content: text,
            attachmentURLs: [existing]
        )
        defer {
            if let staged = folded.stagedFileToRemove {
                try? FileManager.default.removeItem(at: staged)
            }
        }

        XCTAssertEqual(folded.content, "")
        XCTAssertEqual(folded.attachmentURLs.first, existing)
        let staged = try XCTUnwrap(folded.stagedFileToRemove)
        XCTAssertEqual(folded.attachmentURLs.last, staged)
        XCTAssertEqual(String(data: try Data(contentsOf: staged), encoding: .utf8), text)
    }

    func testFoldingLeavesShortContentInPlace() throws {
        let folded = try LargePastedText.foldingIntoAttachments(
            content: "short",
            attachmentURLs: []
        )

        XCTAssertEqual(folded.content, "short")
        XCTAssertTrue(folded.attachmentURLs.isEmpty)
        XCTAssertNil(folded.stagedFileToRemove)
    }

    func testWritesPastedTextAsUTF8() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LargePastedTextTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "Prompt café ✂️"

        let url = try LargePastedText.write(text, to: directory)

        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Pasted Text "))
        XCTAssertEqual(String(data: try Data(contentsOf: url), encoding: .utf8), text)
    }
}
