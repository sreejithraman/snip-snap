import Foundation
import SnipSnapCore

package enum ImportedAttachmentPreparer {
  package struct Result {
    let snips: [Snip]
    let createdFiles: [URL]
  }

  package static func prepare(
    snips: [Snip],
    sourceURLs: [UUID: URL],
    currentSnips: [Snip],
    destinationRoot: URL
  ) throws -> Result {
    let currentByID = Dictionary(
      currentSnips.flatMap(\.attachments).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let currentByPath = Dictionary(
      currentSnips.flatMap(\.attachments).map { ($0.relativePath, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var importedByID: [UUID: SnipAttachment] = [:]
    for attachment in snips.flatMap(\.attachments) {
      if let existing = importedByID[attachment.id], existing != attachment {
        throw SnipLibraryError.invalidStore
      }
      importedByID[attachment.id] = attachment
    }
    var createdFiles: [URL] = []
    do {
      for attachment in importedByID.values {
        if let current = currentByID[attachment.id] {
          guard current == attachment else { throw SnipLibraryError.invalidStore }
          continue
        }
        if let current = currentByPath[attachment.relativePath], current.id != attachment.id {
          throw SnipLibraryError.invalidStore
        }
        guard JSONSnipArchiveReader.isSafeRelativePath(attachment.relativePath),
          let sourceURL = sourceURLs[attachment.id]
        else { throw SnipLibraryError.attachmentCopyFailed }
        let destination = destinationRoot.appendingPathComponent(attachment.relativePath)
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
          !isDirectory.boolValue
        else { throw SnipLibraryError.attachmentCopyFailed }
        if FileManager.default.fileExists(atPath: destination.path) {
          guard FileManager.default.contentsEqual(atPath: sourceURL.path, andPath: destination.path)
          else { throw SnipLibraryError.invalidStore }
          continue
        }
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        createdFiles.append(destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == attachment.byteCount else {
          throw SnipLibraryError.invalidStore
        }
      }
      return Result(snips: snips, createdFiles: createdFiles)
    } catch {
      remove(createdFiles: createdFiles)
      throw error
    }
  }

  package static func remove(createdFiles: [URL]) {
    for fileURL in createdFiles.reversed() {
      try? FileManager.default.removeItem(at: fileURL)
      try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
  }
}
