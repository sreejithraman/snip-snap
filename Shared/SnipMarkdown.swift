import Foundation
import SwiftUI

@MainActor
enum SnipMarkdown {
    static func snapshot(for source: String) -> SnipTextContent {
        SnipMarkdownDocuments.shared.snapshot(for: source)
    }

    static func prepare(_ source: String) async -> SnipTextContent {
        let document = SnipMarkdownDocuments.shared.acquire(source)
        await document.prepare()
        return document.content
    }
}

enum SnipMarkdownParser {
    static func prepare(_ source: String) async -> SnipTextContent {
        await Task.detached(priority: .userInitiated) {
            let attributed = render(source)
            let plain = String(attributed.characters)
            return SnipTextContent.prepared(source: source, text: attributed, accessibilityText: plain)
        }.value
    }

    private static let inlineSyntax = CharacterSet(charactersIn: "*_`~[<>\\&#")
    private static let blockSyntax = try! NSRegularExpression(
        pattern: #"(?m)^(?: {4}|\t| {0,3}(?:[-+](?:\s|$)|\d+[.)]\s|[=-]+\s*$))"#
    )

    private static func render(_ source: String) -> AttributedString {
        guard source.rangeOfCharacter(from: inlineSyntax) != nil
            || blockSyntax.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil else {
            return AttributedString(source)
        }
        guard let parsed = try? AttributedString(
            markdown: source,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible,
                appliesSourcePositionAttributes: true
            )
        ) else { return AttributedString(source) }

        var result = AttributedString()
        var previousBlock: Int?
        var emittedListItems: Set<Int> = []
        var previousEndLine = 1
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let listItem = components.first { if case .listItem = $0.kind { return true }; return false }?.identity
            let startsBlock = block != previousBlock || result.characters.isEmpty
            if block != previousBlock, !result.characters.isEmpty {
                let gap = max(1, min(2, (run.markdownSourcePosition?.startLine ?? previousEndLine + 1) - previousEndLine))
                let trailingNewlines = result.characters.reversed().prefix(while: { $0 == "\n" }).count
                if gap > trailingNewlines {
                    result += AttributedString(String(repeating: "\n", count: gap - trailingNewlines))
                }
            }
            if startsBlock {
                let isListContinuation = listItem.map { !emittedListItems.insert($0).inserted } ?? false
                result += AttributedString(blockPrefix(components, isListContinuation: isListContinuation))
            }
            var segment = AttributedString(parsed[run.range])
            segment.link = nil
            segment.presentationIntent = nil
            segment.markdownSourcePosition = nil
            if run.inlinePresentationIntent?.contains(.softBreak) == true
                || run.inlinePresentationIntent?.contains(.lineBreak) == true {
                segment = AttributedString("\n")
            }
            let isHeading = components.contains { if case .header = $0.kind { return true }; return false }
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
                || components.contains { if case .codeBlock = $0.kind { return true }; return false }
            if isCode {
                segment.font = .body.monospaced()
                if isHeading { segment.font = .body.monospaced().weight(.semibold) }
            } else if isHeading {
                segment.font = .body.weight(.semibold)
            }
            if components.contains(where: { if case .blockQuote = $0.kind { return true }; return false }) {
                appendQuoted(segment, to: &result)
            } else {
                result += segment
            }
            previousBlock = block
            previousEndLine = run.markdownSourcePosition?.endLine ?? previousEndLine
        }
        return result
    }

    private static func appendQuoted(_ text: AttributedString, to result: inout AttributedString) {
        var start = text.startIndex
        while start < text.endIndex {
            if result.characters.last?.isNewline != false {
                result += AttributedString("│ ")
            }
            let newline = text.characters[start...].firstIndex(where: \.isNewline)
            let end = newline.map { text.characters.index(after: $0) } ?? text.endIndex
            result += AttributedString(text[start..<end])
            start = end
        }
    }

    private static func blockPrefix(_ components: [PresentationIntent.IntentType], isListContinuation: Bool) -> String {
        var prefix = components.contains(where: { if case .blockQuote = $0.kind { return true }; return false }) ? "│ " : ""
        let listCount = components.filter {
            switch $0.kind {
            case .orderedList, .unorderedList: true
            default: false
            }
        }.count
        if let itemIndex = components.firstIndex(where: { if case .listItem = $0.kind { return true }; return false }),
           case .listItem(let ordinal) = components[itemIndex].kind {
            prefix += listCount > 1 ? "  " : ""
            let isOrdered = components.dropFirst(itemIndex + 1).first.map { component in
                if case .orderedList = component.kind { return true }
                return false
            } ?? false
            prefix += isListContinuation ? "  " : (isOrdered ? "\(ordinal). " : "• ")
        }
        return prefix
    }
}
