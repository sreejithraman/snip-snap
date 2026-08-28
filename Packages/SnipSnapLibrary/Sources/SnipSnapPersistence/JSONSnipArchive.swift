import Foundation
import SnipSnapCore

/// The portable contents of a supported Snip Snap JSON document.
public struct JSONSnipArchive: Equatable, Sendable {
  public let version: Int
  public let snips: [Snip]
  public let lists: [SnipList]
  public let seenRequestIDs: Set<UUID>

  public init(
    version: Int,
    snips: [Snip],
    lists: [SnipList],
    seenRequestIDs: Set<UUID>
  ) {
    self.version = version
    self.snips = snips
    self.lists = lists
    self.seenRequestIDs = seenRequestIDs
  }
}

/// Reads supported JSON without moving, rewriting, or pruning the source store.
public enum JSONSnipArchiveReader {
  private struct Document: Decodable {
    let version: Int
    let snips: [Snip]
    let lists: [SnipList]
    let seenRequestIDs: Set<UUID>

    private enum CodingKeys: String, CodingKey {
      case version
      case snips
      case lists
      case seenRequestIDs
      case legacyItems = "items"
      case legacySections = "sections"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      version = try container.decode(Int.self, forKey: .version)
      snips = try container.decodeIfPresent([Snip].self, forKey: .snips)
        ?? container.decode([Snip].self, forKey: .legacyItems)
      lists = try container.decodeIfPresent([SnipList].self, forKey: .lists)
        ?? container.decode([SnipList].self, forKey: .legacySections)
      let storedRequestIDs = try container.decodeIfPresent([UUID].self, forKey: .seenRequestIDs)
        ?? []
      seenRequestIDs = Set(storedRequestIDs).union(snips.map(\.requestID))
    }
  }

  public static func read(from fileURL: URL) throws -> JSONSnipArchive {
    do {
      let data = try Data(contentsOf: fileURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let document = try decoder.decode(Document.self, from: data)
      guard document.version == JSONSnipLibrary.currentVersion
        || document.version == JSONSnipLibrary.legacyVersion
      else { throw SnipLibraryError.invalidStore }
      let lists = try validatedLists(document.lists, snips: document.snips)
      try validateAttachments(in: document.snips)
      return JSONSnipArchive(
        version: document.version,
        snips: document.snips,
        lists: lists,
        seenRequestIDs: document.seenRequestIDs
      )
    } catch let error as SnipLibraryError {
      throw error
    } catch {
      throw SnipLibraryError.invalidStore
    }
  }

  private static func validatedLists(_ stored: [SnipList], snips: [Snip]) throws -> [SnipList] {
    guard Set(stored.map(\.id)).count == stored.count,
      Set(stored.map { $0.name.lowercased() }).count == stored.count,
      stored.contains(where: { $0.id == SnipList.inboxID }),
      Set(snips.map(\.id)).count == snips.count,
      Set(snips.map(\.listID)).isSubset(of: Set(stored.map(\.id)))
    else { throw SnipLibraryError.invalidStore }

    var result = stored.filter { $0.id != SnipList.inboxID }
    result.insert(.inbox, at: 0)
    for index in result.indices { result[index].position = index }
    return result
  }

  private static func validateAttachments(in snips: [Snip]) throws {
    var attachmentsByID: [UUID: SnipAttachment] = [:]
    for snip in snips {
      guard Set(snip.attachments.map(\.id)).count == snip.attachments.count else {
        throw SnipLibraryError.invalidStore
      }
      for attachment in snip.attachments {
        guard isSafeRelativePath(attachment.relativePath) else {
          throw SnipLibraryError.invalidStore
        }
        if let existing = attachmentsByID[attachment.id], existing != attachment {
          throw SnipLibraryError.invalidStore
        }
        attachmentsByID[attachment.id] = attachment
      }
    }
  }

  package static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/") else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !components.isEmpty
      && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

public enum JSONSnipArchiveTransfer {
  private struct Document: Encodable {
    let version: Int
    let snips: [Snip]
    let lists: [SnipList]
    let seenRequestIDs: Set<UUID>
  }

  public static func read(from selectedURL: URL) throws -> SnipLibraryArchive {
    let documentURL = try documentURL(from: selectedURL)
    let archive = try JSONSnipArchiveReader.read(from: documentURL)
    let attachmentRoot = documentURL.deletingLastPathComponent()
      .appendingPathComponent("Attachments", isDirectory: true)
    return SnipLibraryArchive(
      snips: archive.snips,
      lists: archive.lists,
      seenRequestIDs: archive.seenRequestIDs,
      attachmentURLs: Dictionary(
        archive.snips.flatMap(\.attachments).map {
          ($0.id, attachmentRoot.appendingPathComponent($0.relativePath))
        },
        uniquingKeysWith: { first, _ in first }
      )
    )
  }

  public static func write(
    _ archive: SnipLibraryArchive,
    to destinationDirectory: URL
  ) throws {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: destinationDirectory.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    let parent = destinationDirectory.deletingLastPathComponent()
    let staging = parent.appendingPathComponent(
      ".\(destinationDirectory.lastPathComponent).exporting-\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
      let attachmentRoot = staging.appendingPathComponent("Attachments", isDirectory: true)
      var copied: Set<UUID> = []
      for attachment in archive.snips.flatMap(\.attachments) where copied.insert(attachment.id).inserted {
        guard JSONSnipArchiveReader.isSafeRelativePath(attachment.relativePath),
          let sourceURL = archive.attachmentURLs[attachment.id]
        else { throw SnipLibraryError.attachmentCopyFailed }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
          !isDirectory.boolValue
        else { throw SnipLibraryError.attachmentCopyFailed }
        let destination = attachmentRoot.appendingPathComponent(attachment.relativePath)
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == attachment.byteCount else {
          throw SnipLibraryError.invalidStore
        }
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(
        Document(
          version: JSONSnipLibrary.currentVersion,
          snips: archive.snips,
          lists: archive.lists,
          seenRequestIDs: archive.seenRequestIDs
        )
      )
      try data.write(to: staging.appendingPathComponent("snips.json"), options: .atomic)
      _ = try read(from: staging)
      try fileManager.moveItem(at: staging, to: destinationDirectory)
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  private static func documentURL(from selectedURL: URL) throws -> URL {
    let values = try selectedURL.resourceValues(forKeys: [.isDirectoryKey])
    if values.isDirectory == true {
      return selectedURL.appendingPathComponent("snips.json", isDirectory: false)
    }
    return selectedURL
  }
}
