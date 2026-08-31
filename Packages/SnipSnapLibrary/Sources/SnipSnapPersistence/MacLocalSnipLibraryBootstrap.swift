import Foundation
import SnipSnapCore

public enum LocalSnipLibraryMode: Equatable, Sendable {
  case swiftData
  case jsonFallback
  case unavailable
}

public struct LocalSnipLibraryOpenResult: Sendable {
  public let library: any SnipLibrary
  public let mode: LocalSnipLibraryMode
  public let errorMessage: String?
  public let backupURL: URL?

  init(
    library: any SnipLibrary,
    mode: LocalSnipLibraryMode,
    errorMessage: String? = nil,
    backupURL: URL? = nil
  ) {
    self.library = library
    self.mode = mode
    self.errorMessage = errorMessage
    self.backupURL = backupURL
  }
}

public struct LocalSnipStorePaths: Equatable, Sendable {
  public let jsonURL: URL
  public let rootDirectory: URL
  public let localDirectory: URL
  public let swiftDataStoreURL: URL
  public let markerURL: URL
  public let legacyAttachmentDirectory: URL
  public let backupRootDirectory: URL

  public init(jsonURL: URL) {
    self.jsonURL = jsonURL
    rootDirectory = jsonURL.deletingLastPathComponent()
    localDirectory = rootDirectory.appendingPathComponent("Local", isDirectory: true)
    swiftDataStoreURL = localDirectory.appendingPathComponent("snips.store", isDirectory: false)
    markerURL = localDirectory.appendingPathComponent("migration.json", isDirectory: false)
    legacyAttachmentDirectory = rootDirectory.appendingPathComponent(
      "Attachments", isDirectory: true)
    backupRootDirectory = rootDirectory.appendingPathComponent(
      "Migration Backups", isDirectory: true)
  }

  package func stagingDirectory(id: UUID) -> URL {
    rootDirectory.appendingPathComponent("Local.importing-\(id.uuidString)", isDirectory: true)
  }
}

package enum LocalStoreMigrationCheckpoint: Equatable, Sendable {
  case afterBackup
  case afterArchiveRead
  case afterStageImport
  case afterVerification
  case afterMarkerWrite
  case beforeActivation
}

private struct LocalStoreMigrationMarker: Codable, Equatable {
  static let currentVersion = 1

  let version: Int
  let schemaVersion: Int
  let sourceVersion: Int?
  let sourceJSONPath: String
  let backupPath: String?
  let storeDirectory: String
  let storeFile: String
  let completedAt: Date
}

private struct RawBackupManifest: Codable, Equatable {
  struct FileEntry: Codable, Equatable {
    let path: String
    let byteCount: Int64
    let sha256: String
  }

  static let currentVersion = 1
  let version: Int
  let files: [FileEntry]
}

private enum LocalStoreMigrationError: LocalizedError {
  case unmarkedLocalStore
  case invalidMarker
  case sourceChanged
  case missingAttachment(String)
  case changedAttachment(String)
  case importedRecordsDiffer

  var errorDescription: String? {
    switch self {
    case .unmarkedLocalStore:
      String(localized: "A Local store exists without a valid migration marker. Snip Snap left it in place.", bundle: .main)
    case .invalidMarker:
      String(localized: "The Local store migration marker is invalid. Snip Snap left the store in place.", bundle: .main)
    case .sourceChanged:
      String(localized: "The JSON store changed while Snip Snap was copying it.", bundle: .main)
    case .missingAttachment(let name):
      String(localized: "The JSON store refers to a missing attachment: \(name).", bundle: .main)
    case .changedAttachment(let name):
      String(localized: "An attachment did not match its copied file: \(name).", bundle: .main)
    case .importedRecordsDiffer:
      String(localized: "The SwiftData check did not match the JSON store.", bundle: .main)
    }
  }
}

/// Opens the Mac local store and performs the one-time JSON migration when needed.
public enum MacLocalSnipLibraryBootstrap {
  public static func open(
    jsonURL: URL = JSONSnipLibrary.defaultStoreURL()
  ) -> LocalSnipLibraryOpenResult {
    open(jsonURL: jsonURL, checkpoint: { _ in })
  }

  package static func open(
    jsonURL: URL,
    checkpoint: (LocalStoreMigrationCheckpoint) throws -> Void
  ) -> LocalSnipLibraryOpenResult {
    open(
      jsonURL: jsonURL,
      checkpoint: checkpoint,
      libraryFactory: { try SwiftDataSnipLibrary(storeURL: $0) }
    )
  }

  package static func open(
    jsonURL: URL,
    checkpoint: (LocalStoreMigrationCheckpoint) throws -> Void,
    libraryFactory: (URL) throws -> any SnipLibrary
  ) -> LocalSnipLibraryOpenResult {
    let fileManager = FileManager.default
    let paths = LocalSnipStorePaths(jsonURL: jsonURL)
    do {
      try fileManager.createDirectory(
        at: paths.rootDirectory,
        withIntermediateDirectories: true
      )
    } catch {
      return unavailableStoreRoot(paths: paths, error: error)
    }
    cleanupStaleWork(paths: paths, fileManager: fileManager)

    if fileManager.fileExists(atPath: paths.localDirectory.path) {
      do {
        try validateMarker(at: paths.markerURL, paths: paths)
      } catch {
        let backupURL = try? makeRawBackupIfPresent(paths: paths, fileManager: fileManager)
        return jsonFallback(
          paths: paths,
          backupURL: backupURL ?? nil,
          migrationError: error
        )
      }
      guard fileManager.fileExists(atPath: paths.swiftDataStoreURL.path) else {
        return unavailableSwiftData(paths: paths)
      }
      do {
        return LocalSnipLibraryOpenResult(
          library: try libraryFactory(paths.swiftDataStoreURL),
          mode: .swiftData
        )
      } catch {
        return unavailableSwiftData(paths: paths)
      }
    }

    let migrationID = UUID()
    let stagingDirectory = paths.stagingDirectory(id: migrationID)
    var backupDirectory: URL?
    do {
      let sourceJSONURL = sourceJSONURL(paths: paths, fileManager: fileManager)
      if sourceJSONURL != nil {
        backupDirectory = try makeRawBackupIfPresent(paths: paths, fileManager: fileManager)
        try checkpoint(.afterBackup)
      }

      let archive: JSONSnipArchive
      let backupJSONURL: URL?
      if let sourceJSONURL, let backupDirectory {
        backupJSONURL = backupDirectory.appendingPathComponent(
          sourceJSONURL.lastPathComponent, isDirectory: false)
        archive = try JSONSnipArchiveReader.read(from: backupJSONURL!)
      } else {
        backupJSONURL = nil
        archive = JSONSnipArchive(
          version: JSONSnipLibrary.currentVersion,
          snips: [],
          lists: [.inbox],
          seenRequestIDs: []
        )
      }
      try checkpoint(.afterArchiveRead)

      try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
      let stagingAttachments = stagingDirectory.appendingPathComponent(
        "Attachments", isDirectory: true)
      if let backupDirectory {
        let backupAttachments = backupDirectory.appendingPathComponent(
          "Attachments", isDirectory: true)
        if fileManager.fileExists(atPath: backupAttachments.path) {
          try fileManager.copyItem(at: backupAttachments, to: stagingAttachments)
        }
      }
      let stagingStore = stagingDirectory.appendingPathComponent("snips.store")
      try SwiftDataSnipLibrary.importArchive(archive, storeURL: stagingStore)
      try checkpoint(.afterStageImport)

      let reopened = try SwiftDataSnipLibrary.readArchive(storeURL: stagingStore)
      guard archivesMatch(archive, reopened) else {
        throw LocalStoreMigrationError.importedRecordsDiffer
      }
      try verifyAttachmentFiles(
        archive: archive,
        sourceRoot: paths.legacyAttachmentDirectory,
        backupRoot: backupDirectory?.appendingPathComponent("Attachments", isDirectory: true),
        stagingRoot: stagingAttachments
      )
      if let sourceJSONURL, let backupJSONURL,
        try hash(fileURL: sourceJSONURL) != hash(fileURL: backupJSONURL)
      {
        throw LocalStoreMigrationError.sourceChanged
      }
      try checkpoint(.afterVerification)

      let marker = LocalStoreMigrationMarker(
        version: LocalStoreMigrationMarker.currentVersion,
        schemaVersion: SnipSnapStoreSchemaContract.currentVersion,
        sourceVersion: sourceJSONURL == nil ? nil : archive.version,
        sourceJSONPath: try relativePath(
          from: paths.rootDirectory,
          to: sourceJSONURL ?? paths.jsonURL
        ),
        backupPath: try backupDirectory.map {
          try relativePath(from: paths.rootDirectory, to: $0)
        },
        storeDirectory: paths.localDirectory.lastPathComponent,
        storeFile: paths.swiftDataStoreURL.lastPathComponent,
        completedAt: Date()
      )
      try writeMarker(marker, to: stagingDirectory.appendingPathComponent("migration.json"))
      try checkpoint(.afterMarkerWrite)
      try checkpoint(.beforeActivation)
      try verifyAttachmentFiles(
        archive: archive,
        sourceRoot: paths.legacyAttachmentDirectory,
        backupRoot: backupDirectory?.appendingPathComponent("Attachments", isDirectory: true),
        stagingRoot: stagingAttachments
      )
      if let sourceJSONURL, let backupJSONURL,
        try hash(fileURL: sourceJSONURL) != hash(fileURL: backupJSONURL)
      {
        throw LocalStoreMigrationError.sourceChanged
      }
      try fileManager.moveItem(at: stagingDirectory, to: paths.localDirectory)
      do {
        try validateMarker(at: paths.markerURL, paths: paths)
        return LocalSnipLibraryOpenResult(
          library: try libraryFactory(paths.swiftDataStoreURL),
          mode: .swiftData,
          backupURL: backupDirectory
        )
      } catch let activationError {
        do {
          try fileManager.moveItem(at: paths.localDirectory, to: stagingDirectory)
        } catch {
          return unavailableAfterActivationRollbackFailure(
            paths: paths,
            activationError: activationError
          )
        }
        throw activationError
      }
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      return jsonFallback(
        paths: paths,
        backupURL: backupDirectory,
        migrationError: error
      )
    }
  }

  private static func sourceJSONURL(
    paths: LocalSnipStorePaths,
    fileManager: FileManager
  ) -> URL? {
    if fileManager.fileExists(atPath: paths.jsonURL.path) { return paths.jsonURL }
    guard paths.jsonURL.lastPathComponent == "snips.json" else { return nil }
    let legacyURL = paths.rootDirectory.appendingPathComponent("items.json", isDirectory: false)
    return fileManager.fileExists(atPath: legacyURL.path) ? legacyURL : nil
  }

  private static func makeRawBackupIfPresent(
    paths: LocalSnipStorePaths,
    fileManager: FileManager
  ) throws -> URL? {
    guard let sourceURL = sourceJSONURL(paths: paths, fileManager: fileManager) else { return nil }
    try fileManager.createDirectory(
      at: paths.backupRootDirectory,
      withIntermediateDirectories: true
    )
    let backupID = UUID()
    let backupDirectory = paths.backupRootDirectory.appendingPathComponent(
      "JSON-to-SwiftData-\(backupID.uuidString)", isDirectory: true)
    let buildingDirectory = paths.backupRootDirectory.appendingPathComponent(
      "JSON-to-SwiftData-\(backupID.uuidString).building", isDirectory: true)
    do {
      try fileManager.createDirectory(at: buildingDirectory, withIntermediateDirectories: false)
      try fileManager.copyItem(
        at: sourceURL,
        to: buildingDirectory.appendingPathComponent(sourceURL.lastPathComponent)
      )
      if fileManager.fileExists(atPath: paths.legacyAttachmentDirectory.path) {
        try fileManager.copyItem(
          at: paths.legacyAttachmentDirectory,
          to: buildingDirectory.appendingPathComponent("Attachments", isDirectory: true)
        )
      }
      let manifest = try makeBackupManifest(at: buildingDirectory, fileManager: fileManager)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(manifest).write(
        to: buildingDirectory.appendingPathComponent("manifest.json"),
        options: .atomic
      )
      try verifyBackupManifest(at: buildingDirectory, fileManager: fileManager)
      try fileManager.moveItem(at: buildingDirectory, to: backupDirectory)
      return backupDirectory
    } catch {
      try? fileManager.removeItem(at: buildingDirectory)
      throw error
    }
  }

  private static func cleanupStaleWork(
    paths: LocalSnipStorePaths,
    fileManager: FileManager
  ) {
    if let rootItems = try? fileManager.contentsOfDirectory(
      at: paths.rootDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) {
      let prefix = "Local.importing-"
      for item in rootItems {
        let name = item.lastPathComponent
        guard name.hasPrefix(prefix),
          UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        else { continue }
        try? fileManager.removeItem(at: item)
      }
    }
    if let backupItems = try? fileManager.contentsOfDirectory(
      at: paths.backupRootDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) {
      let prefix = "JSON-to-SwiftData-"
      let suffix = ".building"
      for item in backupItems {
        let name = item.lastPathComponent
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard UUID(uuidString: String(name[start..<end])) != nil else { continue }
        try? fileManager.removeItem(at: item)
      }
    }
  }

  private static func jsonFallback(
    paths: LocalSnipStorePaths,
    backupURL: URL?,
    migrationError: Error
  ) -> LocalSnipLibraryOpenResult {
    let detail = (migrationError as? LocalizedError)?.errorDescription
      ?? migrationError.localizedDescription
    let message = String(localized: "Snip Snap could not finish its storage upgrade. It kept the JSON store active. \(detail)", bundle: .main)
    do {
      let recovered = try JSONSnipLibrary.openRecoveringCorruptStore(fileURL: paths.jsonURL)
      let recoveryMessage: String
      if let corruptBackup = recovered.backupURL {
        recoveryMessage = String(localized: "Snip Snap kept the unreadable JSON as \(corruptBackup.lastPathComponent) and started a new JSON store. \(detail)", bundle: .main)
      } else {
        recoveryMessage = message
      }
      return LocalSnipLibraryOpenResult(
        library: recovered.repository,
        mode: .jsonFallback,
        errorMessage: recoveryMessage,
        backupURL: backupURL
      )
    } catch {
      return LocalSnipLibraryOpenResult(
        library: JSONSnipLibrary.unavailable(fileURL: paths.jsonURL),
        mode: .unavailable,
        errorMessage: String(localized: "\(message) Snip Snap also could not open the JSON store, so it cannot save new snips.", bundle: .main),
        backupURL: backupURL
      )
    }
  }

  private static func unavailableSwiftData(
    paths: LocalSnipStorePaths
  ) -> LocalSnipLibraryOpenResult {
    LocalSnipLibraryOpenResult(
      library: SwiftDataSnipLibrary.unavailable(storeURL: paths.swiftDataStoreURL),
      mode: .unavailable,
      errorMessage: String(localized: "Snip Snap could not open its SwiftData store. It left the Local and JSON stores unchanged, so it cannot save new snips.", bundle: .main)
    )
  }

  private static func unavailableStoreRoot(
    paths: LocalSnipStorePaths,
    error: Error
  ) -> LocalSnipLibraryOpenResult {
    LocalSnipLibraryOpenResult(
      library: JSONSnipLibrary.unavailable(fileURL: paths.jsonURL),
      mode: .unavailable,
      errorMessage: String(localized: "Snip Snap could not create its local storage folder, so it cannot save new snips. \(error.localizedDescription)", bundle: .main)
    )
  }

  private static func unavailableAfterActivationRollbackFailure(
    paths: LocalSnipStorePaths,
    activationError: Error
  ) -> LocalSnipLibraryOpenResult {
    let detail = (activationError as? LocalizedError)?.errorDescription
      ?? activationError.localizedDescription
    return LocalSnipLibraryOpenResult(
      library: SwiftDataSnipLibrary.unavailable(storeURL: paths.swiftDataStoreURL),
      mode: .unavailable,
      errorMessage: String(localized: "Snip Snap could not open its migrated SwiftData store and could not safely move Local back to staging. It left Local and JSON in place and will not save new snips. \(detail)", bundle: .main)
    )
  }

  private static func archivesMatch(_ expected: JSONSnipArchive, _ actual: JSONSnipArchive) -> Bool {
    let normalizedExpected = SnipLibraryState(
      snips: expected.snips,
      lists: expected.lists,
      seenRequestIDs: expected.seenRequestIDs
    )
    guard normalizedExpected.seenRequestIDs == actual.seenRequestIDs,
      Dictionary(uniqueKeysWithValues: normalizedExpected.lists.map { ($0.id, $0) })
        == Dictionary(uniqueKeysWithValues: actual.lists.map { ($0.id, $0) }),
      Dictionary(uniqueKeysWithValues: normalizedExpected.snips.map { ($0.id, $0) })
        == Dictionary(uniqueKeysWithValues: actual.snips.map { ($0.id, $0) })
    else { return false }
    return true
  }

  private static func verifyAttachmentFiles(
    archive: JSONSnipArchive,
    sourceRoot: URL,
    backupRoot: URL?,
    stagingRoot: URL
  ) throws {
    let attachments = Dictionary(
      archive.snips.flatMap(\.attachments).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    ).values
    for attachment in attachments {
      guard let backupRoot else {
        throw LocalStoreMigrationError.missingAttachment(attachment.fileName)
      }
      let source = try checkedAttachmentURL(root: sourceRoot, relativePath: attachment.relativePath)
      let backup = try checkedAttachmentURL(root: backupRoot, relativePath: attachment.relativePath)
      let staging = try checkedAttachmentURL(root: stagingRoot, relativePath: attachment.relativePath)
      let sourceHash = try hashAndSize(fileURL: source, name: attachment.fileName)
      let backupHash = try hashAndSize(fileURL: backup, name: attachment.fileName)
      let stagingHash = try hashAndSize(fileURL: staging, name: attachment.fileName)
      guard sourceHash == backupHash, backupHash == stagingHash,
        stagingHash.size == attachment.byteCount
      else { throw LocalStoreMigrationError.changedAttachment(attachment.fileName) }
    }
  }

  private static func checkedAttachmentURL(root: URL, relativePath: String) throws -> URL {
    guard JSONSnipArchiveReader.isSafeRelativePath(relativePath) else {
      throw SnipLibraryError.invalidStore
    }
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: candidate.path) else {
      throw LocalStoreMigrationError.missingAttachment(candidate.lastPathComponent)
    }
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
      throw SnipLibraryError.invalidStore
    }
    let values = try resolvedCandidate.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw LocalStoreMigrationError.missingAttachment(candidate.lastPathComponent)
    }
    return resolvedCandidate
  }

  private static func hashAndSize(fileURL: URL, name: String) throws -> (hash: Data, size: Int64) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw LocalStoreMigrationError.missingAttachment(name)
    }
    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
    return (try hash(fileURL: fileURL), Int64(values.fileSize ?? -1))
  }

  private static func hash(fileURL: URL) throws -> Data {
    try AttachmentFileIO.digest(at: fileURL)
  }

  private static func makeBackupManifest(
    at backupDirectory: URL,
    fileManager: FileManager
  ) throws -> RawBackupManifest {
    guard let enumerator = fileManager.enumerator(
      at: backupDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      options: []
    ) else { throw SnipLibraryError.invalidStore }
    var entries: [RawBackupManifest.FileEntry] = []
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isSymbolicLink != true else { throw SnipLibraryError.invalidStore }
      guard values.isRegularFile == true else { continue }
      let path = try relativePath(from: backupDirectory, to: fileURL)
      entries.append(
        RawBackupManifest.FileEntry(
          path: path,
          byteCount: Int64(values.fileSize ?? -1),
          sha256: try hash(fileURL: fileURL).hexString
        )
      )
    }
    return RawBackupManifest(
      version: RawBackupManifest.currentVersion,
      files: entries.sorted { $0.path < $1.path }
    )
  }

  private static func verifyBackupManifest(
    at backupDirectory: URL,
    fileManager: FileManager
  ) throws {
    let manifestURL = backupDirectory.appendingPathComponent("manifest.json")
    let manifest = try JSONDecoder().decode(
      RawBackupManifest.self,
      from: Data(contentsOf: manifestURL)
    )
    guard manifest.version == RawBackupManifest.currentVersion,
      !manifest.files.isEmpty,
      Set(manifest.files.map(\.path)).count == manifest.files.count
    else { throw SnipLibraryError.invalidStore }
    for entry in manifest.files {
      guard JSONSnipArchiveReader.isSafeRelativePath(entry.path) else {
        throw SnipLibraryError.invalidStore
      }
      let fileURL = backupDirectory.appendingPathComponent(entry.path)
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true,
        Int64(values.fileSize ?? -1) == entry.byteCount,
        try hash(fileURL: fileURL).hexString == entry.sha256
      else { throw SnipLibraryError.invalidStore }
    }
  }

  private static func relativePath(from root: URL, to target: URL) throws -> String {
    let rootPath = root.standardizedFileURL.path
    let targetPath = target.standardizedFileURL.path
    guard targetPath.hasPrefix(rootPath + "/") else { throw SnipLibraryError.invalidStore }
    let path = String(targetPath.dropFirst(rootPath.count + 1))
    guard JSONSnipArchiveReader.isSafeRelativePath(path) else {
      throw SnipLibraryError.invalidStore
    }
    return path
  }

  private static func writeMarker(_ marker: LocalStoreMigrationMarker, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(marker).write(to: url, options: .atomic)
  }

  private static func validateMarker(at markerURL: URL, paths: LocalSnipStorePaths) throws {
    guard FileManager.default.fileExists(atPath: markerURL.path) else {
      throw LocalStoreMigrationError.unmarkedLocalStore
    }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let marker = try decoder.decode(
        LocalStoreMigrationMarker.self,
        from: Data(contentsOf: markerURL)
      )
      guard marker.version == LocalStoreMigrationMarker.currentVersion,
        marker.schemaVersion == SnipSnapStoreSchemaContract.currentVersion,
        marker.storeDirectory == paths.localDirectory.lastPathComponent,
        marker.storeFile == paths.swiftDataStoreURL.lastPathComponent,
        JSONSnipArchiveReader.isSafeRelativePath(marker.sourceJSONPath),
        marker.backupPath.map(JSONSnipArchiveReader.isSafeRelativePath) ?? true
      else { throw LocalStoreMigrationError.invalidMarker }
    } catch let error as LocalStoreMigrationError {
      throw error
    } catch {
      throw LocalStoreMigrationError.invalidMarker
    }
  }
}

private extension Data {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
