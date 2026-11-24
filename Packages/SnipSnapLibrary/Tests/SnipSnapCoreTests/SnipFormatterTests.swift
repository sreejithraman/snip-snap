import XCTest
import SnipSnapCore

final class SnipFormatterTests: XCTestCase {
    func testCopyFormattingUsesChronologicalOrderAndSourceContext() {
        let old = Snip(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            requestID: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            content: "First thought",
            origin: .quickEntry
        )
        let new = Snip(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            requestID: UUID(),
            createdAt: Date(timeIntervalSince1970: 200),
            content: "Second snippet",
            origin: .selection,
            source: SnipSource(
                applicationName: "Safari",
                windowTitle: "Docs",
                url: "https://example.com/docs"
            )
        )

        XCTAssertEqual(
            SnipFormatter.format(snips: [new, old]),
            "First thought\n\n---\n\nSecond snippet\nSource: Safari — Docs\nURL: https://example.com/docs"
        )
        XCTAssertEqual(SnipFormatter.formatForClipboard(snips: [old]), "First thought")
        XCTAssertEqual(
            SnipFormatter.formatForClipboard(snips: [new, old]),
            "- First thought\n- Second snippet\n  Source: Safari — Docs\n  URL: https://example.com/docs"
        )
    }
}
