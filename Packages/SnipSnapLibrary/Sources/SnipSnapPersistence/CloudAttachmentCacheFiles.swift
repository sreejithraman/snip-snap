import CryptoKit
import Foundation

/// Owns the on-disk layout and durable file work for CloudKit attachment uploads and downloads.
struct CloudAttachmentCacheFiles {
  let attachmentRootURL: URL
  let lockURL: URL
  let cacheContainerURL: URL

  init(attachmentRootURL: URL, lockURL: URL, cacheContainerURL: URL? = nil) {
    self.attachmentRootURL = attachmentRootURL
    self.lockURL = lockURL
    self.cacheContainerURL = cacheContainerURL ?? attachmentRootURL
  }

  func cacheRoot(namespaceKey: String) throws -> URL {
    let root = cacheRootURL(namespaceKey: namespaceKey)
    try DurableFile.createDirectory(root)
    try DurableFile.excludeFromBackup(root)
    return root
  }

  private func cacheRootURL(namespaceKey: String) -> URL {
    cacheContainerURL
      .appendingPathComponent("CloudDownloads", isDirectory: true)
      .appendingPathComponent(Self.namespaceDigest(namespaceKey), isDirectory: true)
  }

  func cacheFileURL(relativePath: String, namespaceKey: String) throws -> URL {
    let preferredRoot = cacheRootURL(namespaceKey: namespaceKey)
    let legacyRoot = legacyCacheRoot(namespaceKey: namespaceKey)
    return try cacheFileURL(
      relativePath: relativePath,
      preferredRoot: preferredRoot,
      legacyRoot: legacyRoot
    )
  }

  /// Resolves a stored `CloudDownloads/<namespace digest>/...` path without exposing
  /// cache-root alias policy to the library's general attachment reader.
  func cacheFileURL(domainRelativePath: String) throws -> URL {
    let components = domainRelativePath.split(
      separator: "/",
      omittingEmptySubsequences: false
    )
    guard components.count >= 4, components[0] == "CloudDownloads",
      components[1].count == 64,
      components[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else { throw CloudAttachmentStorageError.invalidPath }
    let namespaceDigest = String(components[1])
    let relativePath = components.dropFirst(2).joined(separator: "/")
    let preferredRoot = cacheContainerURL
      .appendingPathComponent("CloudDownloads", isDirectory: true)
      .appendingPathComponent(namespaceDigest, isDirectory: true)
    let legacyRoot = attachmentRootURL
      .appendingPathComponent("CloudDownloads", isDirectory: true)
      .appendingPathComponent(namespaceDigest, isDirectory: true)
    return try cacheFileURL(
      relativePath: relativePath,
      preferredRoot: preferredRoot,
      legacyRoot: legacyRoot
    )
  }

  private func cacheFileURL(
    relativePath: String,
    preferredRoot: URL,
    legacyRoot: URL
  ) throws -> URL {
    let preferred = try Self.validatedCacheChild(relativePath: relativePath, root: preferredRoot)
    guard cacheContainerURL.standardizedFileURL != attachmentRootURL.standardizedFileURL,
      !FileManager.default.fileExists(atPath: preferred.path)
    else { return preferred }
    guard FileManager.default.fileExists(atPath: legacyRoot.path) else { return preferred }
    let legacy = try Self.validatedCacheChild(relativePath: relativePath, root: legacyRoot)
    return FileManager.default.fileExists(atPath: legacy.path) ? legacy : preferred
  }

  /// Returns verified cached bytes, preferring the purgeable location and opportunistically
  /// migrating a valid legacy file without allowing crash residue to mask it.
  func verifiedCacheFileURL(
    relativePath: String,
    namespaceKey: String,
    expectedByteCount: Int64,
    expectedSHA256: Data,
    migrateLegacy: Bool
  ) throws -> URL? {
    let preferredRoot = cacheRootURL(namespaceKey: namespaceKey)
    let preferred: URL
    do {
      preferred = try Self.validatedCacheChild(relativePath: relativePath, root: preferredRoot)
    } catch CloudAttachmentStorageError.symbolicLinkDescendant {
      guard try Self.removeCacheLeafSymlink(relativePath: relativePath, root: preferredRoot)
      else { return nil }
      preferred = try Self.validatedCacheChild(relativePath: relativePath, root: preferredRoot)
    }
    if FileManager.default.fileExists(atPath: preferred.path) {
      if cacheFileIsValid(
        preferred,
        expectedByteCount: expectedByteCount,
        expectedSHA256: expectedSHA256
      ) {
        return preferred
      }
      try FileManager.default.removeItem(at: preferred)
    }

    let legacyRoot = legacyCacheRoot(namespaceKey: namespaceKey)
    let legacy: URL
    do {
      legacy = try Self.validatedCacheChild(relativePath: relativePath, root: legacyRoot)
    } catch CloudAttachmentStorageError.symbolicLinkDescendant {
      guard try Self.removeCacheLeafSymlink(relativePath: relativePath, root: legacyRoot)
      else { return nil }
      legacy = try Self.validatedCacheChild(relativePath: relativePath, root: legacyRoot)
    }
    guard cacheFileIsValid(
      legacy,
      expectedByteCount: expectedByteCount,
      expectedSHA256: expectedSHA256
    ) else { return nil }
    guard migrateLegacy else { return legacy }

    do {
      return try migrateCacheFile(
        from: legacy,
        to: preferred,
        preferredRoot: preferredRoot,
        expectedByteCount: expectedByteCount,
        expectedSHA256: expectedSHA256
      )
    } catch {
      return legacy
    }
  }

  private func migrateCacheFile(
    from source: URL,
    to destination: URL,
    preferredRoot: URL,
    expectedByteCount: Int64,
    expectedSHA256: Data
  ) throws -> URL {
    try DurableFile.createDirectory(preferredRoot)
    try DurableFile.excludeFromBackup(preferredRoot)
    let directory = destination.deletingLastPathComponent()
    try DurableFile.createDirectory(directory)
    let staging = directory.appendingPathComponent(
      "migration-\(UUID().uuidString.lowercased()).tmp",
      isDirectory: false
    )
    defer { try? FileManager.default.removeItem(at: staging) }
    let copied = try AttachmentFileIO.copyRegularFile(
      from: source,
      to: staging,
      expectedByteCount: expectedByteCount
    )
    guard copied.byteCount == expectedByteCount, copied.digest == expectedSHA256 else {
      throw CloudAttachmentStorageError.hashMismatch
    }
    try DurableFile.excludeFromBackup(staging)
    try DurableFile.syncFile(staging)
    try FileManager.default.moveItem(at: staging, to: destination)
    try DurableFile.syncDirectory(directory)
    try FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    return destination
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
    let namespaceRoot = try cacheRoot(namespaceKey: namespaceKey)
    let root = try Self.validatedCacheChild(relativePath: "Staging", root: namespaceRoot)
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
    try requireValidStagedFile(stagedURL, namespaceKey: namespaceKey, cacheRoot: cacheRoot)
    let filesRoot = try Self.validatedCacheChild(relativePath: "Files", root: cacheRoot)
    try DurableFile.createDirectory(filesRoot)
    let destination = try Self.validatedCacheChild(relativePath: relativePath, root: cacheRoot)
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
    try requireValidStagedFile(stagedURL, namespaceKey: namespaceKey)
    let values = try stagedURL.resourceValues(
      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      Int64(values.fileSize ?? -1) == expectedByteCount
    else {
      throw CloudAttachmentStorageError.sizeMismatch
    }
    guard try AttachmentFileIO.digestGrantedRegularFile(at: stagedURL) == expectedSHA256 else {
      throw CloudAttachmentStorageError.hashMismatch
    }
  }

  /// Removes a staging leaf only after proving that its lexical path stays inside the
  /// namespace cache root and no component below that permitted root alias is a symlink.
  func discardStagedFileIfSafe(_ stagedURL: URL, namespaceKey: String) {
    guard (try? requireValidStagedFile(stagedURL, namespaceKey: namespaceKey)) != nil else {
      return
    }
    guard let values = try? stagedURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    ), values.isRegularFile == true, values.isSymbolicLink != true
    else { return }
    try? FileManager.default.removeItem(at: stagedURL)
  }

  private func requireValidStagedFile(
    _ stagedURL: URL,
    namespaceKey: String,
    cacheRoot suppliedCacheRoot: URL? = nil
  ) throws {
    let namespaceRoot = suppliedCacheRoot ?? cacheRootURL(namespaceKey: namespaceKey)
    let stagingRoot = try Self.validatedCacheChild(
      relativePath: "Staging",
      root: namespaceRoot
    )
    try Self.requireChild(stagedURL, of: stagingRoot)
    try Self.requireNoSymlinkComponents(
      stagedURL,
      root: namespaceRoot,
      checkingRoot: false
    )
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
    for root in try cacheRoots(namespaceKey: namespaceKey) {
      let files = try Self.validatedCacheChild(relativePath: "Files", root: root)
      if FileManager.default.fileExists(atPath: files.path) {
        try FileManager.default.removeItem(at: files)
      }
      let staging = try Self.validatedCacheChild(relativePath: "Staging", root: root)
      if FileManager.default.fileExists(atPath: staging.path) {
        try FileManager.default.removeItem(at: staging)
      }
    }
  }

  func clearStaging(namespaceKey: String) throws {
    for root in try cacheRoots(namespaceKey: namespaceKey) {
      let staging = try Self.validatedCacheChild(relativePath: "Staging", root: root)
      if FileManager.default.fileExists(atPath: staging.path) {
        try FileManager.default.removeItem(at: staging)
      }
    }
  }

  func removeNamespaceFiles(namespaceKey: String) throws {
    for root in try cacheRoots(namespaceKey: namespaceKey) {
      try Self.removeTrustedCacheRoot(root)
    }
    let uploadRoot = try uploadRoot(namespaceKey: namespaceKey)
    if FileManager.default.fileExists(atPath: uploadRoot.path) {
      try FileManager.default.removeItem(at: uploadRoot)
    }
  }

  static func remove(_ url: URL, includingParentDirectory: Bool = false) {
    try? FileManager.default.removeItem(at: url)
    if includingParentDirectory {
      try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
  }

  /// Removes a per-store cache container while following only its app-owned namespace roots.
  static func removeCacheContainer(_ root: URL) throws {
    let downloads = root.appendingPathComponent("CloudDownloads", isDirectory: true)
    if let namespaces = try? FileManager.default.contentsOfDirectory(
      at: downloads,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) {
      for namespace in namespaces where namespace.lastPathComponent.count == 64
        && namespace.lastPathComponent.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
      {
        try removeTrustedCacheRoot(namespace)
      }
    }
    if FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
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

  func removeCacheOrphans(namespaceKey: String, keeping paths: Set<String>) throws {
    for cacheRoot in try cacheRoots(namespaceKey: namespaceKey) {
      let filesRoot = try Self.validatedCacheChild(relativePath: "Files", root: cacheRoot)
      try Self.removeOrphans(under: filesRoot, keeping: paths)
    }
  }

  private static func removeOrphans(under root: URL, keeping paths: Set<String>) throws {
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    let resolvedPaths = Set(paths.map {
      URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
    })
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
        !resolvedPaths.contains(url.resolvingSymlinksInPath().standardizedFileURL.path)
      {
        try FileManager.default.removeItem(at: url)
      }
    }
    for directory in emptyDirectories.reversed()
    where (try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty {
      try FileManager.default.removeItem(at: directory)
    }
  }

  /// The cache namespace root is app-owned and may itself be a container alias. Remove the
  /// resolved directory and, when the last component is a symlink, its now-dangling alias.
  private static func removeTrustedCacheRoot(_ root: URL) throws {
    let root = root.standardizedFileURL
    let rootValues = try? root.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard FileManager.default.fileExists(atPath: root.path)
      || rootValues?.isSymbolicLink == true
    else { return }
    let rootIsSymlink = rootValues?.isSymbolicLink == true
    let resolved = root.resolvingSymlinksInPath().standardizedFileURL
    if FileManager.default.fileExists(atPath: resolved.path) {
      try FileManager.default.removeItem(at: resolved)
    }
    if rootIsSymlink {
      try FileManager.default.removeItem(at: root)
    }
  }

  private func cacheRoots(namespaceKey: String) throws -> [URL] {
    let preferred = cacheRootURL(namespaceKey: namespaceKey)
    let legacy = legacyCacheRoot(namespaceKey: namespaceKey)
    return preferred.standardizedFileURL == legacy.standardizedFileURL
      ? [preferred] : [preferred, legacy]
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

  private func legacyCacheRoot(namespaceKey: String) -> URL {
    attachmentRootURL
      .appendingPathComponent("CloudDownloads", isDirectory: true)
      .appendingPathComponent(Self.namespaceDigest(namespaceKey), isDirectory: true)
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
    try validatedRootedChild(relativePath: relativePath, root: root, checkingRoot: true)
  }

  /// Validates a relative path beneath a cache root returned by `cacheRoot(namespaceKey:)`.
  /// The app-owned root may resolve through a permitted container alias; descendants may not.
  private static func validatedCacheChild(relativePath: String, root: URL) throws -> URL {
    try validatedRootedChild(relativePath: relativePath, root: root, checkingRoot: false)
  }

  /// Unlinks only a symlink at the cache entry leaf. Parent validation still rejects
  /// every descendant symlink, so cleanup can never follow an entry outside the cache.
  private static func removeCacheLeafSymlink(relativePath: String, root: URL) throws -> Bool {
    let components = try relativePathComponents(relativePath)
    let leaf = components[components.index(before: components.endIndex)]
    let parent: URL
    if components.count == 1 {
      parent = root
    } else {
      parent = try validatedCacheChild(
        relativePath: components.dropLast().joined(separator: "/"),
        root: root
      )
    }
    let candidate = parent.appendingPathComponent(leaf)
    let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink == true else { return false }
    try FileManager.default.removeItem(at: candidate)
    return true
  }

  /// Constructs an app-owned child from validated relative components. Containment follows
  /// from that construction, so this preserves the root URL exactly as iOS supplied it.
  private static func validatedRootedChild(
    relativePath: String,
    root: URL,
    checkingRoot: Bool
  ) throws -> URL {
    let components = try relativePathComponents(relativePath)
    try requireNoSymlinkComponents(
      root: root,
      components: components[...],
      checkingRoot: checkingRoot
    )
    return components.reduce(root) { $0.appendingPathComponent($1) }
  }

  private static func relativePathComponents(_ relativePath: String) throws -> [String] {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.utf8.contains(0),
      !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    else { throw CloudAttachmentStorageError.invalidRelativePath }
    return components.map(String.init)
  }

  static func requireChild(_ candidate: URL, of root: URL) throws {
    _ = try childPath(candidate, of: root)
  }

  private static func requireNoSymlinkComponents(
    _ candidate: URL,
    root: URL,
    checkingRoot: Bool = true
  ) throws {
    let childPath = try childPath(candidate, of: root)
    try requireNoSymlinkComponents(
      root: childPath.root,
      components: childPath.components,
      checkingRoot: checkingRoot
    )
  }

  private static func requireNoSymlinkComponents(
    root: URL,
    components: ArraySlice<String>,
    checkingRoot: Bool
  ) throws {
    if checkingRoot {
      let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard rootValues.isSymbolicLink != true else {
        throw CloudAttachmentStorageError.symbolicLinkRoot
      }
    }
    var current = root
    for component in components {
      current.appendPathComponent(component)
      let attributes: [FileAttributeKey: Any]
      do {
        attributes = try FileManager.default.attributesOfItem(atPath: current.path)
      } catch {
        guard pathDoesNotExist(error) else { throw error }
        return
      }
      guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
        throw CloudAttachmentStorageError.symbolicLinkDescendant
      }
    }
  }

  private static func pathDoesNotExist(_ error: Error) -> Bool {
    let error = error as NSError
    if error.domain == NSCocoaErrorDomain,
      error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
    {
      return true
    }
    guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlying.domain == NSPOSIXErrorDomain
    else { return false }
    return underlying.code == POSIXError.Code.ENOENT.rawValue
      || underlying.code == POSIXError.Code.ENOTDIR.rawValue
  }

  /// Returns the path to a descendant while allowing the app-owned root to be
  /// represented by either its container alias or its canonical filesystem path.
  private static func childPath(
    _ candidate: URL,
    of root: URL
  ) throws -> (root: URL, components: ArraySlice<String>) {
    if let components = relativeComponents(of: candidate, beneath: root) {
      return (root, components)
    }

    let root = root.standardizedFileURL
    let candidate = candidate.standardizedFileURL
    if let components = relativeComponents(of: candidate, beneath: root) {
      return (root, components)
    }

    // The cache root belongs to the app and iOS may report that container root
    // through an alias. Resolve only that trusted root. Resolving the candidate
    // would erase evidence of a symlink in an untrusted descendant before the
    // caller has a chance to reject it.
    let resolvedRoot = root.resolvingSymlinksInPath()
    guard let components = relativeComponents(of: candidate, beneath: resolvedRoot)
    else {
      throw CloudAttachmentStorageError.pathOutsideRoot
    }
    return (resolvedRoot, components)
  }

  private static func relativeComponents(
    of candidate: URL,
    beneath root: URL
  ) -> ArraySlice<String>? {
    let rootComponents = root.pathComponents
    let candidateComponents = candidate.pathComponents
    guard candidateComponents.count > rootComponents.count,
      candidateComponents.starts(with: rootComponents),
      !candidateComponents.dropFirst(rootComponents.count).contains(where: {
        $0 == "." || $0 == ".." || $0.isEmpty
      })
    else { return nil }
    return candidateComponents.dropFirst(rootComponents.count)
  }
}
