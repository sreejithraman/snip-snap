import AppKit
import Darwin
import Foundation

final class SnipPasteboardMarkdownFile: @unchecked Sendable {
    static let privateType = NSPasteboard.PasteboardType(
        "world.sree.snipsnap.generated-markdown"
    )

    let directory: URL
    let url: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private var isRemoved = false
    private var isPasteboardRetentionArmed = false
    private var cleanupTask: Task<Void, Never>?

    init(markdown: String, fileManager: FileManager = .default) throws {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("SnipSnapPasteboard", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("Snip Snap Snip.md", isDirectory: false)
        self.directory = directory
        self.url = url
        self.fileManager = fileManager
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(markdown.utf8).write(to: url, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(Data(), forType: Self.privateType)
        return item
    }

    func retainUntilPasteboardChanges(
        _ pasteboard: NSPasteboard,
        changeCount: Int
    ) {
        let pasteboardName = pasteboard.name
        let task = Task { @MainActor [self] in
            let observedPasteboard = NSPasteboard(name: pasteboardName)
            while !Task.isCancelled, observedPasteboard.changeCount == changeCount {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            remove()
        }
        let shouldCancel = lock.withLock {
            guard !isRemoved, cleanupTask == nil else { return true }
            isPasteboardRetentionArmed = true
            cleanupTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func remove() {
        let removal = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            guard !isRemoved else { return (false, nil) }
            isRemoved = true
            let task = cleanupTask
            cleanupTask = nil
            return (true, task)
        }
        guard removal.0 else { return }
        removal.1?.cancel()
        try? fileManager.removeItem(at: directory)
    }

    deinit {
        let shouldRemove = lock.withLock { !isPasteboardRetentionArmed }
        if shouldRemove {
            remove()
        }
    }
}

private final class SnipRichTextPasteboardProvider: NSObject,
    NSPasteboardItemDataProvider,
    @unchecked Sendable {
    private let attributedText: NSAttributedString
    private let sources: [SnipPasteboardExport.RichTextSource]

    init(text: String, sources: [SnipPasteboardExport.RichTextSource]) {
        attributedText = NSAttributedString(string: text)
        self.sources = sources
    }

    init(attributedText: NSAttributedString, sources: [SnipPasteboardExport.RichTextSource]) {
        self.attributedText = NSAttributedString(attributedString: attributedText)
        self.sources = sources
    }

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .rtfd else { return }
        let data = SnipPasteboardExport.richTextDataForEligibleExport(
            attributedText: attributedText,
            sources: sources
        )
        if let data {
            item.setData(data, forType: type)
        }
    }
}

struct SnipPasteboardExport {
    static let richTextSourceByteLimit = 64 * 1024 * 1024

    struct FileSnapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    fileprivate struct RichTextSource {
        let url: URL
        let snapshot: FileSnapshot
    }

    private enum RichText {
        case deferred
        case prepared(Data?)
    }

    let text: String
    let attachmentURLs: [URL]
    private let richText: RichText
    private let markdownFile: SnipPasteboardMarkdownFile?

    init(text: String, attachmentURLs: [URL]) {
        self.text = text
        self.attachmentURLs = attachmentURLs
        richText = .deferred
        markdownFile = nil
    }

    static func preparingClipboardExport(
        text: String,
        attachmentURLs: [URL]
    ) async throws -> Self {
        guard let sources = eligibleRichTextSources(
            text: text,
            attachmentURLs: attachmentURLs
        ) else {
            return Self(
                text: text,
                attachmentURLs: attachmentURLs,
                richText: .prepared(nil),
                markdownFile: try stagedMarkdownFile(
                    text: text,
                    attachmentURLs: attachmentURLs
                )
            )
        }
        let task: Task<Data?, Never> = Task.detached(priority: .userInitiated) {
            richTextDataForEligibleExport(text: text, sources: sources)
        }
        let data = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        let markdownFile = try stagedMarkdownFile(
            text: text,
            attachmentURLs: attachmentURLs
        )
        return Self(
            text: text,
            attachmentURLs: attachmentURLs,
            richText: .prepared(data),
            markdownFile: markdownFile
        )
    }

    private init(
        text: String,
        attachmentURLs: [URL],
        richText: RichText,
        markdownFile: SnipPasteboardMarkdownFile? = nil
    ) {
        self.text = text
        self.attachmentURLs = attachmentURLs
        self.richText = richText
        self.markdownFile = markdownFile
    }

    func pasteboardWriters(
        filesAfterPrimary: [NSPasteboardWriting] = [],
        additionalRepresentations: [NSPasteboard.PasteboardType: Data] = [:]
    ) -> [NSPasteboardWriting] {
        var writers: [NSPasteboardWriting] = []
        if !text.isEmpty {
            let primary = NSPasteboardItem()
            primary.setString(text, forType: .string)
            addRichText(to: primary)
            for (type, data) in additionalRepresentations {
                primary.setData(data, forType: type)
            }
            writers.append(primary)
        }
        writers.append(contentsOf: filesAfterPrimary)
        if let markdownFile {
            writers.append(markdownFile.pasteboardItem())
        }
        writers.append(contentsOf: attachmentURLs.map { $0 as NSURL })

        if text.isEmpty, !additionalRepresentations.isEmpty {
            let privateItem = NSPasteboardItem()
            for (type, data) in additionalRepresentations {
                privateItem.setData(data, forType: type)
            }
            writers.append(privateItem)
        }
        return writers
    }

    func retainStagedResources(
        untilPasteboardChanges pasteboard: NSPasteboard,
        from changeCount: Int
    ) {
        markdownFile?.retainUntilPasteboardChanges(
            pasteboard,
            changeCount: changeCount
        )
    }

    static func markdown(text: String, attachmentURLs: [URL]) -> String {
        var result = text
        if !result.hasSuffix("\n") {
            result.append("\n")
        }
        result.append("\n## Attachments\n\n")
        for url in attachmentURLs {
            result.append("- \(markdownCodeSpan(url.lastPathComponent))\n")
        }
        return result
    }

    private static func markdownCodeSpan(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        var longestBacktickRun = 0
        var currentBacktickRun = 0
        for character in normalized {
            if character == "`" {
                currentBacktickRun += 1
                longestBacktickRun = max(longestBacktickRun, currentBacktickRun)
            } else {
                currentBacktickRun = 0
            }
        }
        let delimiter = String(repeating: "`", count: longestBacktickRun + 1)
        let needsPadding = !normalized.allSatisfy(\.isWhitespace)
            && (normalized.first?.isWhitespace == true
                || normalized.last?.isWhitespace == true
                || normalized.first == "`"
                || normalized.last == "`")
        let padding = needsPadding ? " " : ""
        return "\(delimiter)\(padding)\(normalized)\(padding)\(delimiter)"
    }

    private static func stagedMarkdownFile(
        text: String,
        attachmentURLs: [URL]
    ) throws -> SnipPasteboardMarkdownFile? {
        guard !text.isEmpty, !attachmentURLs.isEmpty else { return nil }
        return try SnipPasteboardMarkdownFile(
            markdown: markdown(text: text, attachmentURLs: attachmentURLs)
        )
    }

    static func addDeferredRichText(
        to item: NSPasteboardItem,
        text: String,
        attachmentURLs: [URL]
    ) {
        guard let sources = eligibleRichTextSources(
            text: text,
            attachmentURLs: attachmentURLs
        ) else { return }
        let provider = SnipRichTextPasteboardProvider(
            text: text,
            sources: sources
        )
        item.setDataProvider(provider, forTypes: [.rtfd])
    }

    static func addDeferredRichText(
        to item: NSPasteboardItem,
        attributedText: NSAttributedString,
        attachmentURLs: [URL]
    ) {
        guard let sources = eligibleRichTextSources(
            text: attributedText.string,
            attachmentURLs: attachmentURLs
        ) else { return }
        let provider = SnipRichTextPasteboardProvider(
            attributedText: attributedText,
            sources: sources
        )
        item.setDataProvider(provider, forTypes: [.rtfd])
    }

    private func addRichText(to item: NSPasteboardItem) {
        switch richText {
        case .prepared(let data):
            if let data {
                item.setData(data, forType: .rtfd)
            }
        case .deferred:
            Self.addDeferredRichText(
                to: item,
                text: text,
                attachmentURLs: attachmentURLs
            )
        }
    }

    fileprivate static func richTextData(text: String, sources: [RichTextSource]) -> Data? {
        richTextData(attributedText: NSAttributedString(string: text), sources: sources)
    }

    fileprivate static func richTextData(
        attributedText: NSAttributedString,
        sources: [RichTextSource]
    ) -> Data? {
        var remainingBytes = richTextSourceByteLimit - attributedText.string.utf8.count
        var wrappers: [FileWrapper] = []
        for source in sources {
            guard !Task.isCancelled,
                  let data = boundedFileData(
                    at: source.url,
                    expected: source.snapshot,
                    maximumBytes: remainingBytes
                  ) else {
                return nil
            }
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = source.url.lastPathComponent
            wrappers.append(wrapper)
            remainingBytes -= data.count
        }

        guard !Task.isCancelled else { return nil }
        let richText = NSMutableAttributedString(attributedString: attributedText)
        for wrapper in wrappers {
            richText.append(NSAttributedString(string: "\n"))
            richText.append(
                NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
            )
        }
        let range = NSRange(location: 0, length: richText.length)
        return try? richText.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
    }

    static func boundedFileData(
        at url: URL,
        expected: FileSnapshot? = nil,
        maximumBytes: Int,
        afterReadChunk: ((Int) -> Void)? = nil
    ) -> Data? {
        guard maximumBytes >= 0,
              let pathBefore = fileSnapshot(at: url),
              expected == nil || expected == pathBefore,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let descriptorBefore = fileSnapshot(fileDescriptor: handle.fileDescriptor),
              descriptorBefore == pathBefore,
              descriptorBefore.size >= 0,
              descriptorBefore.size <= Int64(maximumBytes) else { return nil }

        var data = Data()
        while data.count < descriptorBefore.size {
            guard !Task.isCancelled else { return nil }
            let readCount = min(Int(descriptorBefore.size) - data.count, 1024 * 1024)
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: readCount)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { return nil }
            data.append(chunk)
            afterReadChunk?(data.count)
        }
        guard !Task.isCancelled else { return nil }
        guard let descriptorAfter = fileSnapshot(fileDescriptor: handle.fileDescriptor),
              let pathAfter = fileSnapshot(at: url),
              descriptorAfter == descriptorBefore,
              pathAfter == descriptorBefore,
              Int64(data.count) == descriptorBefore.size else { return nil }
        return data
    }

    static func richTextDataForEligibleExport(
        text: String,
        attachmentURLs: [URL]
    ) -> Data? {
        guard !Task.isCancelled else { return nil }
        if let sources = eligibleRichTextSources(text: text, attachmentURLs: attachmentURLs),
           let data = richTextData(text: text, sources: sources) {
            return data
        }
        guard !Task.isCancelled else { return nil }
        return textOnlyRichTextData(text: text)
    }

    fileprivate static func textOnlyRichTextData(text: String) -> Data? {
        textOnlyRichTextData(attributedText: NSAttributedString(string: text))
    }

    private static func textOnlyRichTextData(attributedText: NSAttributedString) -> Data? {
        try? attributedText.data(
            from: NSRange(location: 0, length: attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
    }

    fileprivate static func richTextDataForEligibleExport(
        text: String,
        sources: [RichTextSource]
    ) -> Data? {
        richTextDataForEligibleExport(
            attributedText: NSAttributedString(string: text),
            sources: sources
        )
    }

    fileprivate static func richTextDataForEligibleExport(
        attributedText: NSAttributedString,
        sources: [RichTextSource]
    ) -> Data? {
        guard !Task.isCancelled else { return nil }
        if let data = richTextData(attributedText: attributedText, sources: sources) {
            return data
        }
        guard !Task.isCancelled else { return nil }
        return textOnlyRichTextData(attributedText: attributedText)
    }

    private static func eligibleRichTextSources(
        text: String,
        attachmentURLs: [URL]
    ) -> [RichTextSource]? {
        guard !text.isEmpty, !attachmentURLs.isEmpty else { return nil }
        let limit = richTextSourceByteLimit
        var byteCount = text.utf8.count
        guard byteCount <= limit else { return nil }
        var sources: [RichTextSource] = []
        for url in attachmentURLs {
            guard let snapshot = fileSnapshot(at: url),
                  snapshot.size >= 0,
                  snapshot.size <= Int64(limit - byteCount) else { return nil }
            byteCount += Int(snapshot.size)
            sources.append(RichTextSource(url: url, snapshot: snapshot))
        }
        return sources
    }

    private static func fileSnapshot(at url: URL) -> FileSnapshot? {
        var info = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard result == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return fileSnapshot(info)
    }

    private static func fileSnapshot(fileDescriptor: Int32) -> FileSnapshot? {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return fileSnapshot(info)
    }

    private static func fileSnapshot(_ info: stat) -> FileSnapshot {
        FileSnapshot(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }
}
