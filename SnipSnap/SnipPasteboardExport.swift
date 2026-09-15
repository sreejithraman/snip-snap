import AppKit
import Darwin
import Foundation

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

    init(text: String, attachmentURLs: [URL]) {
        self.text = text
        self.attachmentURLs = attachmentURLs
        richText = .deferred
    }

    static func preparingRichText(
        text: String,
        attachmentURLs: [URL]
    ) async -> Self {
        guard let sources = eligibleRichTextSources(
            text: text,
            attachmentURLs: attachmentURLs
        ) else {
            return Self(
                text: text,
                attachmentURLs: attachmentURLs,
                richText: .prepared(nil)
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
        return Self(
            text: text,
            attachmentURLs: attachmentURLs,
            richText: .prepared(data)
        )
    }

    private init(
        text: String,
        attachmentURLs: [URL],
        richText: RichText
    ) {
        self.text = text
        self.attachmentURLs = attachmentURLs
        self.richText = richText
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
