import SwiftUI
import XCTest
@testable import SnipSnap

@MainActor
final class SnipMarkdownTests: XCTestCase {
    func testInlineFormattingHidesSyntaxAndPreservesCode() async {
        let rendered = await SnipMarkdown.prepare("**Rename Hot.** Update `HotCore`, *carefully*, ~~later~~.").fullText

        XCTAssertEqual(String(rendered.characters), "Rename Hot. Update HotCore, carefully, later.")
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
        XCTAssertEqual(rendered.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }?.font, .body.monospaced())
    }

    func testHeadingsStayBodySizedAndKeepSeparateLines() async {
        let rendered = await SnipMarkdown.prepare("# Main\nBody\n\n###### Small\nMore").fullText

        XCTAssertEqual(String(rendered.characters), "Main\nBody\n\nSmall\nMore")
        let headings = rendered.runs.filter { $0.font == .body.weight(.semibold) }
        XCTAssertEqual(headings.map { String(rendered[$0.range].characters) }, ["Main", "Small"])
    }

    func testListsKeepMarkersAndShallowNesting() async {
        await assertRendered("- one\n- two\n  - nested\n\n3. three\n4. four", equals: "• one\n• two\n  • nested\n\n3. three\n4. four")
    }

    func testCodeBlocksKeepLiteralContentAndUseMonospace() async {
        let rendered = await SnipMarkdown.prepare("```swift\n# literal\n\n**bold**\n```").fullText

        XCTAssertEqual(String(rendered.characters), "# literal\n\n**bold**\n")
        XCTAssertTrue(rendered.runs.allSatisfy { $0.font == .body.monospaced() })
    }

    func testQuotesKeepEachLineMarked() async {
        await assertRendered("> quoted\n> second", equals: "│ quoted\n│ second")
        await assertRendered("> quoted  \n> second", equals: "│ quoted\n│ second")
        await assertRendered("> quoted\\\n> second", equals: "│ quoted\n│ second")
    }

    func testQuotedCodeKeepsEachLineMarkedAndMonospaced() async {
        let content = await SnipMarkdown.prepare("> ```swift\n> let x = 1\n> let y = 2\n> ```")
        XCTAssertEqual(content.accessibilityText, "│ let x = 1\n│ let y = 2\n")
        let code = content.fullText.runs.filter { $0.font == .body.monospaced() }
            .map { String(content.fullText[$0.range].characters) }.joined()
        XCTAssertEqual(code, "let x = 1\nlet y = 2\n")
        await assertRendered(">     one\n>     two", equals: "│ one\n│ two\n")
    }

    func testPlainNotesKeepTheirLineBreaksAndBlankLines() async {
        let source = "Line one\nLine two\n\n\nLine three\n"
        await assertRendered(source, equals: source)
        await assertRendered("**First**\nSecond\n\nThird", equals: "First\nSecond\n\nThird")
        await assertRendered("A & B\nC\n\nD", equals: "A & B\nC\n\nD")
        await assertRendered("**First**  \nSecond", equals: "First\nSecond")
        await assertRendered("**First**\\\nSecond", equals: "First\nSecond")
    }

    func testLinksKeepLabelsWithoutTakingOverCardClicks() async {
        let rendered = await SnipMarkdown.prepare("See [the docs](https://example.com/docs) and <https://example.com>.").fullText

        XCTAssertEqual(String(rendered.characters), "See the docs and https://example.com.")
        XCTAssertTrue(rendered.runs.allSatisfy { $0.link == nil })
    }

    func testHTMLAndEscapedPunctuationStayReadable() async {
        await assertRendered("<div>raw</div>\n\nnext", equals: "<div>raw</div>\n\nnext")
        await assertRendered(#"\*literal\* &amp; x"#, equals: "*literal* & x")
        await assertRendered("**unfinished", equals: "**unfinished")
    }

    func testContinuationParagraphDoesNotBecomeAnotherListItem() async {
        await assertRendered("- first\n\n  continuation\n- next", equals: "• first\n\n  continuation\n• next")
    }

    func testParentListContinuationKeepsItsIdentityAfterNestedItems() async {
        await assertRendered("1. first\n   - nested\n\n   continuation\n2. next", equals: "1. first\n  • nested\n\n  continuation\n2. next")
        await assertRendered("- first\n  - nested\n\n  continuation\n- next", equals: "• first\n  • nested\n\n  continuation\n• next")
    }

    func testInlineCodeInHeadingKeepsBothStyles() async {
        let rendered = await SnipMarkdown.prepare("# `HotCore`").fullText

        XCTAssertEqual(String(rendered.characters), "HotCore")
        XCTAssertEqual(rendered.runs.first?.font, .body.monospaced().weight(.semibold))
    }

    func testThematicBreakStaysSeparateFromFollowingText() async {
        await assertRendered("---\nafter", equals: "⸻\nafter")
    }

    func testPendingSnapshotStaysBoundedEvenWhenFullTextIsRequested() async {
        let documents = SnipMarkdownDocuments()
        let source = String(repeating: "**line**\n", count: 2_500)
        let snapshot = documents.snapshot(for: source)
        let presentation = snapshot.presentation(lineLimit: nil)

        XCTAssertTrue(snapshot.isLoading)
        XCTAssertTrue(presentation.isLoading)
        XCTAssertTrue(presentation.isTruncated)
        XCTAssertLessThanOrEqual(presentation.preview.characters.count, 800)
        XCTAssertLessThanOrEqual(String(presentation.preview.characters).split(separator: "\n").count, SnipTextPresentation.previewLineLimit)
        XCTAssertEqual(snapshot.source, source)
        XCTAssertEqual(snapshot.accessibilityText, String(localized: "Loading snip"))
        XCTAssertEqual(snapshot.fullText, presentation.preview)
        await Task.yield()
        XCTAssertTrue(documents.snapshot(for: source).isLoading)
    }

    func testPreparedPreviewCutsFormattedCharactersWithoutExposingSyntax() async {
        let source = "**" + String(repeating: "👩🏽‍💻", count: 801) + "**"
        let content = await SnipMarkdown.prepare(source)
        let presentation = content.presentation(lineLimit: 5)

        XCTAssertEqual(presentation.preview.characters.count, 801)
        XCTAssertEqual(String(presentation.preview.characters), String(repeating: "👩🏽‍💻", count: 800) + "…")
        XCTAssertTrue(presentation.preview.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertEqual(content.source, source)
        XCTAssertEqual(content.accessibilityText, String(repeating: "👩🏽‍💻", count: 801))
        XCTAssertFalse(content.presentation(lineLimit: nil).isTruncated)
    }

    func testLiteralContentKeepsMarkdownAndDefersFullAttributedText() {
        let source = String(repeating: "**literal**\n", count: 100_000)
        let presentation = SnipTextContent.literal(source).presentation(lineLimit: 3)

        XCTAssertFalse(presentation.isLoading)
        XCTAssertTrue(presentation.isTruncated)
        XCTAssertEqual(String(presentation.preview.characters), "**literal**\n**literal**\n**literal**…")
        XCTAssertEqual(presentation.accessibilityText, source)
    }

    func testConcurrentConsumersShareTheDocumentAndCancellationKeepsPreparationAlive() async {
        let documents = SnipMarkdownDocuments()
        let source = "# Shared\n" + String(repeating: "**body** and `code`\n", count: 2_500)
        let first = documents.acquire(source)
        let second = documents.acquire(source)
        XCTAssertTrue(first === second)

        let cancelledConsumer = Task { await first.prepare() }
        let remainingConsumer = Task { await second.prepare() }
        cancelledConsumer.cancel()
        await remainingConsumer.value
        await cancelledConsumer.value

        XCTAssertFalse(first.content.isLoading)
        XCTAssertEqual(first.content.source, source)
        XCTAssertEqual(documents.snapshot(for: source).fullText, second.content.fullText)
    }

    func testFinishingAnOldSourceCannotReplaceTheNewSource() async {
        let documents = SnipMarkdownDocuments()
        let oldSource = String(repeating: "**Old** and `code`\n", count: 2_500)
        let oldDocument = documents.acquire(oldSource)
        let oldWork = Task { await oldDocument.prepare() }
        let newDocument = documents.acquire("# New")
        await newDocument.prepare()
        await oldWork.value

        XCTAssertFalse(oldDocument === newDocument)
        XCTAssertEqual(newDocument.content.accessibilityText, "New")
        XCTAssertEqual(documents.snapshot(for: "# New").accessibilityText, "New")
        XCTAssertEqual(documents.snapshot(for: oldSource).source, oldSource)
    }

    func testActiveOversizedDocumentSurvivesWarmCacheEvictionAndThenReleases() async {
        let documents = SnipMarkdownDocuments()
        let source = String(repeating: "**large** and `code`\n", count: 25_000)
        var document: SnipMarkdownDocument? = documents.acquire(source)
        await document?.prepare()
        documents.clearWarmCache()

        XCTAssertFalse(documents.snapshot(for: source).isLoading)
        XCTAssertEqual(documents.snapshot(for: source).accessibilityText, document?.content.accessibilityText)
        weak var releasedDocument: SnipMarkdownDocument?
        releasedDocument = document
        document = nil
        XCTAssertNil(releasedDocument)
        _ = documents.acquire("Prune dead documents")
        XCTAssertTrue(documents.snapshot(for: source).isLoading)
    }

    func testLargeFormattedPreparationKeepsTheMainActorResponsive() async throws {
        let source = (0..<2_500).map {
            "**Prompt \($0):** write a detailed SwiftUI clipboard manager with `Snip` lists, search, sync, attachments, and recovery. Include code samples and edge cases."
        }.joined(separator: "\n")
        XCTAssertEqual(source.utf8.count, 391_389)
        let documents = SnipMarkdownDocuments()
        let document = documents.acquire(source)
        let preparation = Task { await document.prepare() }
        var largestGap: TimeInterval = 0
        var heartbeats = 0
        while document.content.isLoading {
            let start = Date()
            try await Task.sleep(for: .milliseconds(1))
            largestGap = max(largestGap, Date().timeIntervalSince(start))
            heartbeats += 1
        }
        await preparation.value

        XCTAssertGreaterThan(heartbeats, 1)
        XCTAssertLessThan(largestGap, 0.25, "Main-actor heartbeat stalled while preparing formatted text")
        XCTAssertTrue(document.content.fullText.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    private func assertRendered(_ source: String, equals expected: String, file: StaticString = #filePath, line: UInt = #line) async {
        let content = await SnipMarkdown.prepare(source)
        XCTAssertFalse(content.isLoading, file: file, line: line)
        XCTAssertEqual(String(content.fullText.characters), expected, file: file, line: line)
        XCTAssertEqual(content.accessibilityText, expected, file: file, line: line)
    }
}
