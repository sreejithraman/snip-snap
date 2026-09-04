import SnipSnapCore
import XCTest

final class SnipTextPreviewTests: XCTestCase {
    func testShortTextIsUnchanged() {
        XCTAssertEqual(
            SnipTextPreview.displayText("Keep this snip", lineLimit: 5),
            "Keep this snip"
        )
    }

    func testStopsAfterTheRequestedNumberOfLines() {
        let text = "one\ntwo\nthree\nfour"
        XCTAssertEqual(
            SnipTextPreview.displayText(text, lineLimit: 2),
            "one\ntwo"
        )
    }

    func testStopsAtTheCharacterLimitOnOneLongLine() {
        let text = String(repeating: "a", count: 50)
        XCTAssertEqual(
            SnipTextPreview.displayText(text, lineLimit: 5, characterLimit: 12),
            String(repeating: "a", count: 12)
        )
    }

    func testTreatsCRLFAsOneLineBreak() {
        let text = "one\r\ntwo\r\nthree"
        XCTAssertEqual(
            SnipTextPreview.displayText(text, lineLimit: 2),
            "one\r\ntwo"
        )
    }

    func testLargePromptPreviewStaysBounded() {
        let prompt = hugePrompt()
        let start = CFAbsoluteTimeGetCurrent()
        let preview = SnipTextPreview.displayText(prompt, lineLimit: 5)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(prompt.hasPrefix(preview))
        XCTAssertLessThan(preview.count, prompt.count)
        XCTAssertLessThanOrEqual(preview.filter(\.isNewline).count, 4)
        XCTAssertLessThanOrEqual(
            preview.filter { !$0.isNewline }.count,
            SnipTextPreview.characterLimit
        )
        XCTAssertLessThan(elapsed, 0.01)
    }

    private func hugePrompt() -> String {
        var lines: [String] = []
        lines.reserveCapacity(2_500)
        for index in 0..<2_500 {
            lines.append(
                "Prompt \(index): write a detailed SwiftUI clipboard manager with lists, search, sync, attachments, and recovery."
            )
        }
        return lines.joined(separator: "\n")
    }
}
