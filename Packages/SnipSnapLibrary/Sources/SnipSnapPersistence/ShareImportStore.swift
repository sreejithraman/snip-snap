import Darwin
import Foundation
import SnipSnapCore

public enum ShareImportError: Error, Equatable, LocalizedError, Sendable {
  case invalidStaging
  case noSharedContainer

  public var errorDescription: String? {
    switch self {
    case .invalidStaging:
      String(localized: "Snip Snap could not keep the shared files.", bundle: .main)
    case .noSharedContainer:
      String(localized: "This build does not have access to the shared Snip Snap container.", bundle: .main)
    }
  }
}

public struct ShareImportAttachment: Codable, Equatable, Sendable {
  public let fileName: String
  public let contentType: String?
  public let byteCount: Int64
  public let relativePath: String

  public init(
    fileName: String,
    contentType: String?,
    byteCount: Int64,
    relativePath: String
  ) {
    self.fileName = fileName
    self.contentType = contentType
    self.byteCount = byteCount
    self.relativePath = relativePath
  }
}

public struct ShareImportRequest: Codable, Equatable, Sendable {
  public let content: String
  public let source: SnipSource?
  public let destinationListID: UUID
  public let attachments: [ShareImportAttachment]
  public let requestID: UUID
  public let createdAt: Date

  public init(
    content: String,
    source: SnipSource? = nil,
    destinationListID: UUID,
    attachments: [ShareImportAttachment] = [],
    requestID: UUID = UUID(),
    createdAt: Date = Date()
  ) {
    self.content = content
    self.source = source
    self.destinationListID = destinationListID
    self.attachments = attachments
    self.requestID = requestID
    self.createdAt = createdAt
  }
}

public enum ShareImportSaveResult: Equatable, Sendable {
  case pending(requestID: UUID)
}

public struct ShareImportSummary: Equatable, Sendable {
  public let imported: Int
  public let failed: Int

  public init(imported: Int, failed: Int) {
    self.imported = imported
    self.failed = failed
  }
}

/// Copies item-provider files into the shared container before provider callbacks return.
public struct ShareImportStagingArea: Sendable {
  public let requestID: UUID
  private let paths: ShareImportPaths
  private let directoryURL: URL

  public init(sharedRootURL: URL, requestID: UUID = UUID()) throws {
    self.requestID = requestID
    paths = ShareImportPaths(rootURL: sharedRootURL)
    directoryURL = paths.intakeDirectory(requestID: requestID)
    try DurableFile.createDirectory(directoryURL)
  }

  public func copyProviderFile(
    at sourceURL: URL,
    suggestedName: String? = nil,
    contentType: String? = nil
  ) throws -> ShareImportAttachment {
    let didAccess = sourceURL.startAccessingSecurityScopedResource()
    defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
    let sourceValues = try sourceURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
      throw ShareImportError.invalidStaging
    }

    let proposedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fileName = Self.safeFileName(
      (proposedName?.isEmpty == false ? proposedName : nil) ?? sourceURL.lastPathComponent
    )
    let relativeDirectory = "Files/\(UUID().uuidString)"
    let relativePath = "\(relativeDirectory)/\(fileName)"
    let fileDirectory = directoryURL.appendingPathComponent(relativeDirectory, isDirectory: true)
    let destinationURL = fileDirectory.appendingPathComponent(fileName, isDirectory: false)
    do {
      try DurableFile.createDirectory(fileDirectory)
      _ = try AttachmentFileIO.copyRegularFile(from: sourceURL, to: destinationURL)
      let values = try destinationURL.resourceValues(
        forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ShareImportError.invalidStaging
      }
      try DurableFile.syncFile(destinationURL)
      try DurableFile.syncDirectory(fileDirectory)
      try DurableFile.syncDirectory(directoryURL)
      return ShareImportAttachment(
        fileName: fileName,
        contentType: contentType,
        byteCount: Int64(values.fileSize ?? 0),
        relativePath: relativePath
      )
    } catch {
      try? FileManager.default.removeItem(at: fileDirectory)
      throw error
    }
  }

  private static func safeFileName(_ value: String) -> String {
    let name = URL(fileURLWithPath: value).lastPathComponent
    return name.isEmpty || name == "." || name == ".." ? "Attachment" : name
  }

  public func discard() {
    try? FileManager.default.removeItem(at: directoryURL)
    try? DurableFile.syncDirectory(paths.intakeRootURL)
  }
}

/// Keeps an item-provider file before the provider's temporary URL expires.
public enum ShareProviderFileLoader {
  @MainActor
  public static func copyFileRepresentation(
    staging: ShareImportStagingArea,
    suggestedName: String? = nil,
    contentType: String? = nil,
    load: (@escaping @Sendable (URL?, Error?) -> Void) -> Void
  ) async throws -> ShareImportAttachment {
    try await withCheckedThrowingContinuation { continuation in
      load { url, error in
        do {
          if let error { throw error }
          guard let url else { throw ShareImportError.invalidStaging }
          let attachment = try staging.copyProviderFile(
            at: url,
            suggestedName: suggestedName,
            contentType: contentType
          )
          continuation.resume(returning: attachment)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

/// Publishes Share-extension saves to the atomic pending-import inbox.
public actor ShareImportStore {
  private let paths: ShareImportPaths
  private let afterPendingSaveBeforeCleanup: @Sendable () throws -> Void

  public init(sharedRootURL: URL) {
    paths = ShareImportPaths(rootURL: sharedRootURL)
    afterPendingSaveBeforeCleanup = {}
  }

  package init(
    sharedRootURL: URL,
    afterPendingSaveBeforeCleanup: @escaping @Sendable () throws -> Void
  ) {
    paths = ShareImportPaths(rootURL: sharedRootURL)
    self.afterPendingSaveBeforeCleanup = afterPendingSaveBeforeCleanup
  }

  public static func storeURL(in sharedRootURL: URL) -> URL {
    ShareImportPaths(rootURL: sharedRootURL).storeURL
  }

  public func availableLists() async -> [SnipList] {
    return ShareDestinationCatalog.read(from: paths.catalogURL)
  }

  public func save(_ request: ShareImportRequest) async throws -> ShareImportSaveResult {
    try validate(request)
    try publishPending(request)
    return .pending(requestID: request.requestID)
  }

  public func importPending(into library: any SnipLibrary) async -> ShareImportSummary {
    var imported = 0
    var failed = 0
    for directory in readyDirectories() {
      do {
        let request = try readRequest(in: directory)
        let snapshot = await library.snapshot(sortedBy: .chronological)
        let destinationID = SnipShareDestination.resolve(
          rememberedListID: request.destinationListID,
          in: snapshot.lists
        )
        _ = try await library.perform(
          .add(
            content: request.content,
            origin: .share,
            source: request.source,
            listID: destinationID,
            attachmentURLs: try request.attachments.map {
              try paths.attachmentURL($0, in: directory)
            },
            requestID: request.requestID,
            now: request.createdAt
          ),
          sortedBy: .chronological
        )
        try afterPendingSaveBeforeCleanup()
        try FileManager.default.removeItem(at: directory)
        try DurableFile.syncDirectory(paths.pendingRootURL)
        imported += 1
      } catch {
        failed += 1
      }
    }
    return ShareImportSummary(imported: imported, failed: failed)
  }

  public func pendingImportCount() -> Int {
    readyDirectories().count
  }

  @discardableResult
  public func removeAbandonedIntake(
    olderThan cutoff: Date = Date().addingTimeInterval(-86_400)
  ) -> Int {
    let candidates = (try? FileManager.default.contentsOfDirectory(
      at: paths.intakeRootURL,
      includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    var removed = 0
    for candidate in candidates {
      guard let values = try? candidate.resourceValues(
        forKeys: [.isDirectoryKey, .contentModificationDateKey]
      ),
        values.isDirectory == true,
        let modifiedAt = values.contentModificationDate,
        modifiedAt < cutoff,
        (try? FileManager.default.removeItem(at: candidate)) != nil
      else { continue }
      removed += 1
    }
    if removed > 0 { try? DurableFile.syncDirectory(paths.intakeRootURL) }
    return removed
  }

  private func validate(_ request: ShareImportRequest) throws {
    let requestDirectory = paths.intakeDirectory(requestID: request.requestID)
    for attachment in request.attachments {
      _ = try paths.attachmentURL(attachment, in: requestDirectory)
    }
  }

  private func publishPending(_ request: ShareImportRequest) throws {
    try DurableFile.createDirectory(paths.pendingRootURL)
    let stagingURL = paths.intakeDirectory(requestID: request.requestID)
    try DurableFile.createDirectory(stagingURL)
    let metadataURL = stagingURL.appendingPathComponent("import.json", isDirectory: false)
    let data = try JSONEncoder.shareImport.encode(request)
    try DurableFile.write(data, to: metadataURL)
    try DurableFile.syncDirectory(stagingURL)
    let readyURL = paths.pendingDirectory(requestID: request.requestID)
    if FileManager.default.fileExists(atPath: readyURL.path) {
      try? FileManager.default.removeItem(at: stagingURL)
      try? DurableFile.syncDirectory(paths.intakeRootURL)
      return
    }
    guard Darwin.rename(stagingURL.path, readyURL.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try DurableFile.syncDirectory(paths.pendingRootURL)
    try DurableFile.syncDirectory(paths.intakeRootURL)
  }

  private func readRequest(in directory: URL) throws -> ShareImportRequest {
    let metadataURL = directory.appendingPathComponent("import.json", isDirectory: false)
    let stored = try JSONDecoder.shareImport.decode(
      ShareImportRequest.self,
      from: Data(contentsOf: metadataURL)
    )
    for attachment in stored.attachments {
      _ = try paths.attachmentURL(attachment, in: directory)
    }
    return stored
  }

  private func readyDirectories() -> [URL] {
    let directories = (try? FileManager.default.contentsOfDirectory(
      at: paths.pendingRootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    return directories
      .filter(paths.isValidReadyDirectory)
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}

package struct ShareImportPaths: Sendable {
  let rootURL: URL

  var storeURL: URL {
    rootURL.appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Local", isDirectory: true)
      .appendingPathComponent("snips.store", isDirectory: false)
  }

  var shareRootURL: URL {
    rootURL.appendingPathComponent("Share", isDirectory: true)
  }

  var intakeRootURL: URL {
    shareRootURL.appendingPathComponent("Intake", isDirectory: true)
  }

  var pendingRootURL: URL {
    shareRootURL.appendingPathComponent("PendingImports", isDirectory: true)
  }

  var catalogURL: URL {
    shareRootURL.appendingPathComponent("destinations.json", isDirectory: false)
  }

  func intakeDirectory(requestID: UUID) -> URL {
    intakeRootURL.appendingPathComponent(requestID.uuidString, isDirectory: true)
  }

  func pendingDirectory(requestID: UUID) -> URL {
    pendingRootURL.appendingPathComponent("\(requestID.uuidString).ready", isDirectory: true)
  }

  func isValidReadyDirectory(_ directory: URL) -> Bool {
    guard directory.pathExtension == "ready",
      let values = try? directory.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      ),
      values.isDirectory == true,
      values.isSymbolicLink != true
    else { return false }

    let pendingRoot = pendingRootURL.standardizedFileURL
    let candidate = directory.standardizedFileURL
    guard Self.contains(candidate, in: pendingRoot) else { return false }
    let resolvedRoot = pendingRoot.resolvingSymlinksInPath().standardizedFileURL
    let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
    let expectedResolved = resolvedRoot.appendingPathComponent(candidate.lastPathComponent)
      .standardizedFileURL
    return resolved == expectedResolved && Self.contains(resolved, in: resolvedRoot)
  }

  static func sharedRoot(forStoreURL storeURL: URL) -> URL? {
    guard storeURL.lastPathComponent == "snips.store" else { return nil }
    let localDirectory = storeURL.deletingLastPathComponent()
    guard localDirectory.lastPathComponent == "Local" else { return nil }
    let libraryDirectory = localDirectory.deletingLastPathComponent()
    guard libraryDirectory.lastPathComponent == "Library" else { return nil }
    return libraryDirectory.deletingLastPathComponent()
  }

  func attachmentURL(
    _ attachment: ShareImportAttachment,
    in requestDirectory: URL
  ) throws -> URL {
    guard !attachment.relativePath.isEmpty,
      !attachment.relativePath.hasPrefix("/"),
      !attachment.relativePath.contains("\0")
    else { throw ShareImportError.invalidStaging }

    let requestRoot = requestDirectory.standardizedFileURL
    let candidate = requestRoot.appendingPathComponent(attachment.relativePath)
      .standardizedFileURL
    guard Self.contains(candidate, in: requestRoot) else {
      throw ShareImportError.invalidStaging
    }
    let unresolvedValues = try candidate.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard unresolvedValues.isRegularFile == true,
      unresolvedValues.isSymbolicLink != true
    else { throw ShareImportError.invalidStaging }

    let resolvedRoot = requestRoot.resolvingSymlinksInPath().standardizedFileURL
    let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
    let expectedResolved = resolvedRoot.appendingPathComponent(attachment.relativePath)
      .standardizedFileURL
    let resolvedValues = try resolved.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard resolved == expectedResolved,
      Self.contains(resolved, in: resolvedRoot),
      resolvedValues.isRegularFile == true,
      resolvedValues.isSymbolicLink != true
    else { throw ShareImportError.invalidStaging }
    return resolved
  }

  private static func contains(_ child: URL, in directory: URL) -> Bool {
    child.path.hasPrefix(directory.path + "/")
  }
}

package enum ShareDestinationCatalog {
  static func write(_ lists: [SnipList], to url: URL) throws {
    try DurableFile.write(JSONEncoder.shareImport.encode(lists), to: url)
  }

  static func read(from url: URL) -> [SnipList] {
    guard let data = try? Data(contentsOf: url),
      let lists = try? JSONDecoder.shareImport.decode([SnipList].self, from: data),
      lists.contains(where: { $0.id == SnipList.inboxID })
    else { return [.inbox] }
    return lists
  }
}

package enum DurableFile {
  static func createDirectory(_ url: URL) throws {
    var missing: [URL] = []
    var cursor = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: cursor.path) {
      missing.append(cursor)
      let parent = cursor.deletingLastPathComponent()
      guard parent.path != cursor.path else { break }
      cursor = parent
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try applyDataProtection(to: url)
    for directory in missing.reversed() {
      try syncDirectory(directory)
      try syncDirectory(directory.deletingLastPathComponent())
    }
  }

  package static func write(_ data: Data, to url: URL) throws {
    try createDirectory(url.deletingLastPathComponent())
    try data.write(to: url, options: .atomic)
    try applyDataProtection(to: url)
    try syncFile(url)
    try syncDirectory(url.deletingLastPathComponent())
  }

  static func syncFile(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  static func syncDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// Keeps re-creatable files out of device backups.
  package static func excludeFromBackup(_ url: URL) throws {
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  package static func applyDataProtection(to url: URL) throws {
#if os(iOS)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path
    )
#endif
  }
}

private extension JSONEncoder {
  static var shareImport: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

private extension JSONDecoder {
  static var shareImport: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
