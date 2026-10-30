import Foundation
import Observation
import SnipSnapCore
import SwiftUI

struct SnipTextContent: Sendable {
    private enum Storage: Sendable {
        case literal
        case loading
        case prepared(text: AttributedString, accessibilityText: String)
    }

    let source: String
    private let storage: Storage

    static func literal(_ source: String) -> Self { Self(source: source, storage: .literal) }
    static func loading(_ source: String) -> Self { Self(source: source, storage: .loading) }

    static func prepared(source: String, text: AttributedString, accessibilityText: String) -> Self {
        Self(source: source, storage: .prepared(text: text, accessibilityText: accessibilityText))
    }

    var isLoading: Bool {
        if case .loading = storage { return true }
        return false
    }

    var accessibilityText: String {
        switch storage {
        case .literal: source
        case .loading: String(localized: "Loading snip")
        case .prepared(_, let text): text
        }
    }

    var fullText: AttributedString {
        switch storage {
        case .literal: AttributedString(source)
        case .loading: presentation(lineLimit: SnipTextPresentation.previewLineLimit).preview
        case .prepared(let text, _): text
        }
    }

    func presentation(lineLimit: Int?) -> SnipTextPresentation {
        SnipTextPresentation(content: self, lineLimit: lineLimit)
    }

    fileprivate var preparedText: AttributedString? {
        if case .prepared(let text, _) = storage { return text }
        return nil
    }

    fileprivate var cacheCost: Int {
        source.utf8.count + accessibilityText.utf8.count * 5
    }
}

struct SnipTextPresentation {
    static var previewLineLimit: Int {
#if os(macOS)
        5
#else
        3
#endif
    }

    private let content: SnipTextContent
    let preview: AttributedString
    let isTruncated: Bool
    var isLoading: Bool { content.isLoading }
    var accessibilityText: String { content.accessibilityText }
    var fullText: AttributedString { content.fullText }

    fileprivate init(content: SnipTextContent, lineLimit: Int?) {
        self.content = content
        if !content.isLoading, lineLimit == nil {
            preview = content.fullText
            isTruncated = false
        } else {
            let limit = content.isLoading
                ? min(Self.previewLineLimit, max(1, lineLimit ?? Self.previewLineLimit))
                : max(1, lineLimit ?? Self.previewLineLimit)
            let displayText = content.preparedText == nil ? content.source : content.accessibilityText
            var prefix = SnipTextPreview.displayText(displayText, lineLimit: limit)
            var truncated = prefix != displayText
            if content.isLoading {
                let bounded = String(prefix.prefix(SnipTextPreview.characterLimit - 1))
                truncated = truncated || bounded != prefix
                prefix = bounded
            }
            isTruncated = truncated
            if let text = content.preparedText {
                let end = text.characters.index(text.startIndex, offsetBy: prefix.count)
                preview = AttributedString(text[..<end]) + AttributedString(truncated ? "…" : "")
            } else {
                preview = AttributedString(prefix + (truncated ? "…" : ""))
            }
        }
    }
}

@MainActor @Observable
final class SnipMarkdownDocument: NSObject {
    let source: String
    private(set) var content: SnipTextContent
    @ObservationIgnored private var preparation: Task<SnipTextContent, Never>?
    @ObservationIgnored private weak var documents: SnipMarkdownDocuments?

    fileprivate init(source: String, documents: SnipMarkdownDocuments) {
        self.source = source
        content = .loading(source)
        self.documents = documents
    }

    func prepare() async {
        guard content.isLoading else { return }
        let task: Task<SnipTextContent, Never>
        if let preparation {
            task = preparation
        } else {
            let source = source
            task = Task { await SnipMarkdownParser.prepare(source) }
            preparation = task
        }
        let prepared = await task.value
        guard content.isLoading else { return }
        content = prepared
        preparation = nil
        documents?.didPrepare(self)
    }
}

@MainActor
final class SnipMarkdownDocuments {
    static let shared = SnipMarkdownDocuments()
    private final class WeakDocument {
        weak var value: SnipMarkdownDocument?
        init(_ value: SnipMarkdownDocument) { self.value = value }
    }

    private var active: [Int: [WeakDocument]] = [:]
    private let warm = NSCache<SnipMarkdownDocument, SnipMarkdownDocument>()
    private let warmCostLimit = 2 * 1_024 * 1_024

    init() {
        warm.countLimit = 128
        warm.totalCostLimit = warmCostLimit
    }

    func acquire(_ source: String) -> SnipMarkdownDocument {
        prune()
        let hash = source.hashValue
        if let existing = active[hash]?.compactMap(\.value).first(where: { $0.source == source }) {
            return existing
        }
        let document = SnipMarkdownDocument(source: source, documents: self)
        active[hash, default: []].append(WeakDocument(document))
        return document
    }

    func snapshot(for source: String) -> SnipTextContent {
        active[source.hashValue]?.compactMap(\.value).first(where: { $0.source == source })?.content ?? .loading(source)
    }

    func clearWarmCache() { warm.removeAllObjects() }

    fileprivate func didPrepare(_ document: SnipMarkdownDocument) {
        if document.content.cacheCost <= warmCostLimit {
            warm.setObject(document, forKey: document, cost: document.content.cacheCost)
        }
        prune()
    }

    private func prune() {
        active = active.compactMapValues { bucket in
            let live = bucket.filter { $0.value != nil }
            return live.isEmpty ? nil : live
        }
    }
}

struct SnipMarkdownContent<Content: View>: View {
    let source: String
    @ViewBuilder let content: (SnipTextContent) -> Content
    @State private var document: SnipMarkdownDocument?

    var body: some View {
        let selected = document.flatMap { $0.source == source ? $0 : nil }
            ?? SnipMarkdownDocuments.shared.acquire(source)
        content(selected.content)
            .task(id: source) {
                guard !Task.isCancelled else { return }
                document = selected
                await selected.prepare()
            }
    }
}
