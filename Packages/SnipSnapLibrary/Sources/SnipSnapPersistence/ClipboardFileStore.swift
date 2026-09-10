import Foundation
import SnipSnapCore

public struct ClipboardFileStore: Sendable {
    public let rootURL: URL
    public enum Failure: Error, LocalizedError {
        case missingFile(String), invalidPath, unsupportedDirectory, tooLarge
        public var errorDescription: String? {
            switch self {
            case .missingFile(let name): String(localized: "The file \(name) is missing or unreadable.", bundle: .main)
            case .invalidPath: String(localized: "The clipboard file path is invalid.", bundle: .main)
            case .unsupportedDirectory: String(localized: "Folders can’t be added to clipboard history yet.", bundle: .main)
            case .tooLarge: String(localized: "Clipboard content must be 32 MB or less.", bundle: .main)
            }
        }
    }
    public init(rootURL: URL) { self.rootURL = rootURL }

    public func url(for file: ClipboardOwnedFile) throws -> URL {
        guard !file.relativePath.hasPrefix("/"),
              !file.relativePath.split(separator: "/").contains("..") else { throw Failure.invalidPath }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(file.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(root.path + "/") else { throw Failure.invalidPath }
        return target
    }

    public func resolvedFileURLs(for entry: ClipboardEntry) -> [URL] {
        if !entry.ownedFiles.isEmpty { return entry.ownedFiles.compactMap { try? url(for: $0) } }
        return entry.fileURLs
    }

    public func validateSize(of entry: ClipboardEntry) throws {
        var total = entry.byteCount
        guard total <= ClipboardHistoryState.entryByteLimit else { throw Failure.tooLarge }
        for url in resolvedFileURLs(for: entry) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw Failure.unsupportedDirectory }
            guard let count = values.fileSize, count <= ClipboardHistoryState.entryByteLimit - total else { throw Failure.tooLarge }
            total += count
        }
    }

    public func preserveFiles(of entry: ClipboardEntry) throws -> ClipboardEntry {
        if entry.fileURLs.isEmpty { return entry }
        if entry.ownedFiles.count == entry.fileURLs.count,
           try entry.ownedFiles.allSatisfy({ FileManager.default.isReadableFile(atPath: try url(for: $0).path) }) {
            try validateSize(of: entry)
            var result = entry
            result.ownedFiles = try entry.ownedFiles.map { file in
                var file = file
                file.byteCount = try url(for: file).resourceValues(forKeys: [.fileSizeKey]).fileSize
                return file
            }
            return result
        }
        let fileManager = FileManager.default
        var totalBytes = entry.byteCount
        guard totalBytes <= ClipboardHistoryState.entryByteLimit else { throw Failure.tooLarge }
        for source in entry.fileURLs {
            guard source.isFileURL, fileManager.isReadableFile(atPath: source.path) else { throw Failure.missingFile(source.lastPathComponent) }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw Failure.unsupportedDirectory }
            guard let count = values.fileSize, count <= ClipboardHistoryState.entryByteLimit - totalBytes else { throw Failure.tooLarge }
            totalBytes += count
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let directoryName = UUID().uuidString
        let staging = rootURL.appendingPathComponent(".staging-" + directoryName, isDirectory: true)
        let destination = rootURL.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var files: [ClipboardOwnedFile] = []
        do {
            for source in entry.fileURLs {
                guard source.isFileURL, fileManager.isReadableFile(atPath: source.path) else { throw Failure.missingFile(source.lastPathComponent) }
                let values = try source.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw Failure.unsupportedDirectory }
                let id = UUID()
                let leaf = id.uuidString + "-" + source.lastPathComponent
                try fileManager.copyItem(at: source, to: staging.appendingPathComponent(leaf))
                files.append(ClipboardOwnedFile(id: id, name: source.lastPathComponent, relativePath: directoryName + "/" + leaf,
                    byteCount: try staging.appendingPathComponent(leaf).resourceValues(forKeys: [.fileSizeKey]).fileSize))
            }
            var copiedBytes = entry.byteCount
            for file in files {
                let copied = staging.appendingPathComponent(URL(fileURLWithPath: file.relativePath).lastPathComponent)
                let values = try copied.resourceValues(forKeys: [.fileSizeKey])
                guard let count = values.fileSize, count <= ClipboardHistoryState.entryByteLimit - copiedBytes else { throw Failure.tooLarge }
                copiedBytes += count
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        var result = entry; result.ownedFiles = files; return result
    }

    /// Store downloaded bytes using validated app-relative metadata.
    public func importOwnedFile(_ file: ClipboardOwnedFile, data: Data) throws {
        guard data.count <= ClipboardHistoryState.entryByteLimit else { throw Failure.tooLarge }
        let target = try url(for: file)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

}
