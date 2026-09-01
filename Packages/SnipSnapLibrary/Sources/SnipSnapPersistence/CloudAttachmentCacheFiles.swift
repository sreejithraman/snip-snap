import CryptoKit
import Foundation

/// Owns the on-disk layout and durable file work for CloudKit attachment uploads and downloads.
struct CloudAttachmentCacheFiles {
  let attachmentRootURL: URL
  let lockURL: URL

  func cacheRoot(namespaceKey: String) throws -> URL {
    let root =
      attachmentRootURL
      .appendingPathComponent("CloudDownloads", isDirectory: true)
      .appendingPathComponent(Self.namespaceDigest(namespaceKey), isDirectory: true)
    try DurableFile.createDirectory(root)
    try DurableFile.excludeFromBackup(root)
    return root
  }

  func uploadRoot(namespaceKey: String) throws -> URL {
    let root = lockURL.deletingPathExtension().deletingLastPathComponent()
      .appendingPathComponent("CloudAttachmentUploads", isDirectory: true)
      .appendingPathComponent(Self.namespaceDigest(namespaceKey), isDirectory: true)
    try DurableFile.createDirectory(root)
    try DurableFile.excludeFromBackup(root)
    return root
  }

  func stagingRoot(namespaceKey: String) throws -> URL {
    let root = try cacheRoot(namespaceKey: namespaceKey)
      .appendingPathComponent("Staging", isDirectory: true)
    try DurableFile.createDirectory(root)
    return root
  }

  func stageUpload(
    sourceURL: URL,
    namespaceKey: String,
    payloadRecordName: String
  ) throws -> (relativePath: String, url: URL) {
    let root = try uploadRoot(namespaceKey: namespaceKey)
    let relativePath = "\(payloadRecordName)/payload"
    let destination = try Self.validatedChild(relativePath: relativePath, root: root)
    let directory = destination.deletingLastPathComponent()
    try DurableFile.createDirectory(directory)
    if FileManager.default.fileExists(atPath: destination.path) {
      let sourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      let stagedValues = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if sourceValues.isRegularFile == true, stagedValues.isRegularFile == true,
        sourceValues.fileSize == stagedValues.fileSize,
        try Self.digest(at: sourceURL) == Self.digest(at: destination)
      {
        return (relativePath, destination)
      }
      try FileManager.default.removeItem(at: destination)
    }
    do {
      _ = try AttachmentFileIO.copyRegularFile(from: sourceURL, to: destination)
      try DurableFile.syncFile(destination)
      try DurableFile.syncDirectory(directory)
      try DurableFile.syncDirectory(root)
      return (relativePath, destination)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  /// Moves a verified staging file into its durable cache path and syncs every new level.
  func installStagedFile(
    _ stagedURL: URL,
    namespaceKey: String,
    relativePath: String
  ) throws -> URL {
    let cacheRoot = try cacheRoot(namespaceKey: namespaceKey)
    try Self.requireChild(stagedURL, of: try stagingRoot(namespaceKey: namespaceKey))
    let filesRoot = cacheRoot.appendingPathComponent("Files", isDirectory: true)
    try DurableFile.createDirectory(filesRoot)
    let destination = try Self.validatedChild(relativePath: relativePath, root: cacheRoot)
    try DurableFile.createDirectory(destination.deletingLastPathComponent())
    try FileManager.default.moveItem(at: stagedURL, to: destination)
    do {
      // A move can reset the resource value inherited from CloudDownloads.
      try DurableFile.excludeFromBackup(destination)
      try DurableFile.syncFile(destination)
      try DurableFile.syncDirectory(destination.deletingLastPathComponent())
      try DurableFile.syncDirectory(filesRoot)
      return destination
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  func validateStagedFile(
    _ stagedURL: URL,
    namespaceKey: String,
    expectedByteCount: Int64,
    expectedSHA256: Data
  ) throws {
    try Self.requireChild(stagedURL, of: try stagingRoot(namespaceKey: namespaceKey))
    let values = try stagedURL.resourceValues(
      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      Int64(values.fileSize ?? -1) == expectedByteCount
    else {
      throw CloudAttachmentStorageError.sizeMismatch
    }
    guard try Self.digest(at: stagedURL) == expectedSHA256 else {
      throw CloudAttachmentStorageError.hashMismatch
    }
  }

  func cacheFileIsValid(
    _ url: URL,
    expectedByteCount: Int64,
    expectedSHA256: Data
  ) -> Bool {
    guard
      let values = try? url.resourceValues(
        forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
      )
    else { return false }
    return values.isRegularFile == true
      && values.isSymbolicLink != true
      && Int64(values.fileSize ?? -1) == expectedByteCount
      && (try? Self.digest(at: url)) == expectedSHA256
  }

  func clearCacheDirectories(namespaceKey: String) throws {
    let root = try cacheRoot(namespaceKey: namespaceKey)
    for directoryName in ["Files", "Staging"] {
      let directory = root.appendingPathComponent(directoryName, isDirectory: true)
      if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
      }
    }
  }

  func clearStaging(namespaceKey: String) throws {
    let staging = try cacheRoot(namespaceKey: namespaceKey)
      .appendingPathComponent("Staging", isDirectory: true)
    if FileManager.default.fileExists(atPath: staging.path) {
      try FileManager.default.removeItem(at: staging)
    }
  }

  func removeNamespaceFiles(namespaceKey: String) throws {
    for root in [
      try cacheRoot(namespaceKey: namespaceKey),
      try uploadRoot(namespaceKey: namespaceKey),
    ] where FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
  }

  static func remove(_ url: URL, includingParentDirectory: Bool = false) {
    try? FileManager.default.removeItem(at: url)
    if includingParentDirectory {
      try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
  }

  /// Removes only direct, unowned upload directories so recovery work stays bounded.
  func sweepUploads(namespaceKey: String, keeping recordNames: Set<String>) throws {
    let root = try uploadRoot(namespaceKey: namespaceKey)
    for child in try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) {
      let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true, values.isDirectory == true,
        recordNames.contains(child.lastPathComponent)
      else {
        try FileManager.default.removeItem(at: child)
        continue
      }
      for item in try FileManager.default.contentsOfDirectory(
        at: child,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      ) where item.lastPathComponent != "payload" {
        try FileManager.default.removeItem(at: item)
      }
    }
  }

  static func removeOrphans(under root: URL, keeping paths: Set<String>) throws {
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
    else { return }
    var emptyDirectories: [URL] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      )
      if values.isSymbolicLink == true {
        enumerator.skipDescendants()
        try FileManager.default.removeItem(at: url)
      } else if values.isDirectory == true {
        emptyDirectories.append(url)
      } else if values.isRegularFile == true,
        !paths.contains(url.standardizedFileURL.path)
      {
        try FileManager.default.removeItem(at: url)
      }
    }
    for directory in emptyDirectories.reversed()
    where (try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty {
      try FileManager.default.removeItem(at: directory)
    }
  }

  static func cacheRelativePath(
    namespaceKey: String,
    attachmentID: UUID,
    fileName: String
  ) -> String {
    "CloudDownloads/\(namespaceDigest(namespaceKey))/Files/"
      + "\(attachmentID.uuidString.lowercased())/\(safeFileName(fileName))"
  }

  static func cacheEntryRelativePath(attachmentID: UUID, fileName: String) -> String {
    "Files/\(attachmentID.uuidString.lowercased())/"
      + "\(UUID().uuidString.lowercased())-\(safeFileName(fileName))"
  }

  static func namespaceDigest(_ namespaceKey: String) -> String {
    Data(SHA256.hash(data: Data(namespaceKey.utf8)))
      .map { String(format: "%02x", $0) }.joined()
  }

  static func digest(at url: URL) throws -> Data {
    try AttachmentFileIO.digest(at: url)
  }

  static func safeFileName(_ fileName: String) -> String {
    let value = URL(fileURLWithPath: fileName).lastPathComponent
    return value.isEmpty || value == "." || value == ".." ? "Attachment" : value
  }

  static func validatedChild(relativePath: String, root: URL) throws -> URL {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
      !relativePath.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    else { throw CloudAttachmentStorageError.invalidPath }
    let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
    try requireChild(candidate, of: root)
    try requireNoSymlinkComponents(candidate, root: root)
    return candidate
  }

  static func requireChild(_ candidate: URL, of root: URL) throws {
    let rootPath = root.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    guard candidatePath.hasPrefix(rootPath + "/") else {
      throw CloudAttachmentStorageError.invalidPath
    }
  }

  private static func requireNoSymlinkComponents(_ candidate: URL, root: URL) throws {
    let root = root.standardizedFileURL
    let candidate = candidate.standardizedFileURL
    let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard rootValues.isSymbolicLink != true else {
      throw CloudAttachmentStorageError.invalidPath
    }
    let suffix = candidate.path.dropFirst(root.path.count)
    var current = root
    for component in suffix.split(separator: "/") {
      current.appendPathComponent(String(component))
      guard FileManager.default.fileExists(atPath: current.path) else { continue }
      let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw CloudAttachmentStorageError.invalidPath
      }
    }
  }
}
