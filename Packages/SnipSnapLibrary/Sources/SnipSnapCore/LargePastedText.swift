import Foundation

public enum LargePastedText {
    public static let attachmentCharacterLimit = 2_000

    public static func shouldAttach(_ text: String) -> Bool {
        text.count >= attachmentCharacterLimit
    }

    public static func largeInsertion(from old: String, to new: String) -> String? {
        let inserted = insertion(from: old, to: new)
        guard shouldAttach(inserted) else { return nil }
        return inserted
    }

    public static func insertion(from old: String, to new: String) -> String {
        if old.isEmpty { return new }
        if new.isEmpty { return "" }

        var oldPrefix = old.startIndex
        var newPrefix = new.startIndex
        while oldPrefix < old.endIndex, newPrefix < new.endIndex,
              old[oldPrefix] == new[newPrefix] {
            old.formIndex(after: &oldPrefix)
            new.formIndex(after: &newPrefix)
        }

        var oldSuffix = old.endIndex
        var newSuffix = new.endIndex
        while oldSuffix > oldPrefix, newSuffix > newPrefix {
            let previousOld = old.index(before: oldSuffix)
            let previousNew = new.index(before: newSuffix)
            guard old[previousOld] == new[previousNew] else { break }
            oldSuffix = previousOld
            newSuffix = previousNew
        }
        return String(new[newPrefix..<newSuffix])
    }

    public static func write(
        _ text: String,
        to directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "Pasted Text \(UUID().uuidString).txt"
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public static func foldingIntoAttachments(
        content: String,
        attachmentURLs: [URL]
    ) throws -> (content: String, attachmentURLs: [URL], stagedFileToRemove: URL?) {
        guard shouldAttach(content) else {
            return (content, attachmentURLs, nil)
        }
        let url = try write(content)
        return ("", attachmentURLs + [url], url)
    }
}
