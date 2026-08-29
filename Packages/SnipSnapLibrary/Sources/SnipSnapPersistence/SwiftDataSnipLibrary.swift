import Darwin
import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData
import UniformTypeIdentifiers

@Model
final class StoredSnipRecord {
  @Attribute(.unique) var id: UUID
  var requestID: UUID
  var createdAt: Date
  var updatedAt: Date
  var content: String
  var origin: String
  var sourceApplicationName: String?
  var sourceWindowTitle: String?
  var sourceURL: String?
  var listID: UUID
  var isDone: Bool
  var manualPosition: Int64

  init(_ snip: Snip) {
    id = snip.id
    requestID = snip.requestID
    createdAt = snip.createdAt
    updatedAt = snip.updatedAt
    content = snip.content
    origin = snip.origin.rawValue
    sourceApplicationName = snip.source?.applicationName
    sourceWindowTitle = snip.source?.windowTitle
    sourceURL = snip.source?.url
    listID = snip.listID
    isDone = snip.isDone
    manualPosition = snip.manualPosition
  }

  func update(from snip: Snip) {
    requestID = snip.requestID
    createdAt = snip.createdAt
    updatedAt = snip.updatedAt
    content = snip.content
    origin = snip.origin.rawValue
    sourceApplicationName = snip.source?.applicationName
    sourceWindowTitle = snip.source?.windowTitle
    sourceURL = snip.source?.url
    listID = snip.listID
    isDone = snip.isDone
    manualPosition = snip.manualPosition
  }
}

@Model
final class StoredListRecord {
  @Attribute(.unique) var id: UUID
  var name: String
  var systemImage: String
  var position: Int

  init(_ list: SnipList) {
    id = list.id
    name = list.name
    systemImage = list.systemImage
    position = list.position
  }

  func update(from list: SnipList) {
    name = list.name
    systemImage = list.systemImage
    position = list.position
  }
}

@Model
final class StoredAttachmentRecord {
  @Attribute(.unique) var id: UUID
  var fileName: String
  var relativePath: String
  var contentType: String?
  var byteCount: Int64

  init(_ attachment: SnipAttachment) {
    id = attachment.id
    fileName = attachment.fileName
    relativePath = attachment.relativePath
    contentType = attachment.contentType
    byteCount = attachment.byteCount
  }

  func update(from attachment: SnipAttachment) {
    fileName = attachment.fileName
    relativePath = attachment.relativePath
    contentType = attachment.contentType
    byteCount = attachment.byteCount
  }
}

@Model
final class StoredSnipAttachmentReference {
  @Attribute(.unique) var id: String
  var snipID: UUID
  var attachmentID: UUID
  var position: Int

  init(snipID: UUID, attachmentID: UUID, position: Int) {
    id = Self.identifier(snipID: snipID, attachmentID: attachmentID)
    self.snipID = snipID
    self.attachmentID = attachmentID
    self.position = position
  }

  static func identifier(snipID: UUID, attachmentID: UUID) -> String {
    "\(snipID.uuidString)/\(attachmentID.uuidString)"
  }

  func update(position: Int) {
    self.position = position
  }
}

@Model
package final class StoredRequestRecord {
  @Attribute(.unique) package var id: UUID

  package init(id: UUID) {
    self.id = id
  }
}

package enum StoredLibraryMetadataKind: String, Codable {
  case snip, list
}

package enum LibraryMetadataBackfillPoint: CaseIterable {
  case beforeSave, afterSave
}

package enum CloudFullRecordBackfillPoint: CaseIterable {
  case beforeSave, afterSave
}

@Model
final class StoredLibraryMetadataRecord {
  @Attribute(.unique) var id: String
  var kind: String
  var domainID: UUID
  var orderKeyData: Data
  var desiredName: String?
  var legacyPosition: Int64?
  var legacyOrderKeyData: Data?

  init(
    kind: StoredLibraryMetadataKind,
    domainID: UUID,
    orderKey: SnipOrderKey,
    desiredName: String? = nil,
    legacyPosition: Int64? = nil,
    legacyOrderKey: SnipOrderKey? = nil
  ) {
    id = Self.identifier(kind: kind, domainID: domainID)
    self.kind = kind.rawValue
    self.domainID = domainID
    orderKeyData = orderKey.data
    self.desiredName = desiredName
    self.legacyPosition = legacyPosition
    legacyOrderKeyData = legacyOrderKey?.data
  }

  static func identifier(kind: StoredLibraryMetadataKind, domainID: UUID) -> String {
    "\(kind.rawValue)|\(domainID.uuidString.lowercased())"
  }

  func update(orderKey: SnipOrderKey, desiredName: String? = nil) {
    orderKeyData = orderKey.data
    self.desiredName = desiredName
  }
}

package enum SnipSnapSchemaV1: VersionedSchema {
  package static let versionIdentifier = Schema.Version(1, 0, 0)
  package static var models: [any PersistentModel.Type] {
    [
      StoredSnipRecord.self,
      StoredListRecord.self,
      StoredAttachmentRecord.self,
      StoredSnipAttachmentReference.self,
      StoredRequestRecord.self,
    ]
  }
}

package enum SnipSnapSchemaV2: VersionedSchema {
  package static let versionIdentifier = Schema.Version(2, 0, 0)
  package static var models: [any PersistentModel.Type] {
    [
      StoredSnipRecord.self,
      StoredListRecord.self,
      StoredAttachmentRecord.self,
      StoredSnipAttachmentReference.self,
      StoredRequestRecord.self,
      StoredCloudTextRecord.self,
      StoredCloudEngineState.self,
      StoredCloudStagedBatch.self,
      StoredCloudRecoveryEvent.self,
      StoredCloudNamespaceState.self,
    ]
  }
}

package enum SnipSnapSchemaV3: VersionedSchema {
  package static let versionIdentifier = Schema.Version(3, 0, 0)
  package static var models: [any PersistentModel.Type] {
    SnipSnapSchemaV2.models + [
      StoredLibraryMetadataRecord.self,
      StoredCloudEntityRecord.self,
      StoredCloudFullConflict.self,
      StoredCloudFullEnrollment.self,
      StoredCloudDormantBaseRecord.self,
      StoredCloudMappingQuarantine.self,
      StoredCloudFullBatchReceipt.self,
    ]
  }
}

package enum SnipSnapSchemaV4: VersionedSchema {
  package static let versionIdentifier = Schema.Version(4, 0, 0)
  package static var models: [any PersistentModel.Type] {
    SnipSnapSchemaV3.models + [StoredCloudPendingDelete.self]
  }
}

package enum SnipSnapSchemaMigrationPlan: SchemaMigrationPlan {
  package static var schemas: [any VersionedSchema.Type] {
    [SnipSnapSchemaV1.self, SnipSnapSchemaV2.self, SnipSnapSchemaV3.self, SnipSnapSchemaV4.self]
  }
  package static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: SnipSnapSchemaV1.self, toVersion: SnipSnapSchemaV2.self),
      .lightweight(fromVersion: SnipSnapSchemaV2.self, toVersion: SnipSnapSchemaV3.self),
      .lightweight(fromVersion: SnipSnapSchemaV3.self, toVersion: SnipSnapSchemaV4.self),
    ]
  }
}

final class SnipStoreFileLock {
  private let descriptor: Int32

  init(url: URL) throws {
    descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
      if descriptor >= 0 { Darwin.close(descriptor) }
      throw SnipLibraryError.storeUnavailable
    }
  }

  deinit {
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}

/// A durable local snip library backed by record-based SwiftData storage.
public actor SwiftDataSnipLibrary: SnipLibrary {
  struct LoadedStore {
    let state: SnipLibraryState
    let snips: [StoredSnipRecord]
    let lists: [StoredListRecord]
    let attachments: [StoredAttachmentRecord]
    let references: [StoredSnipAttachmentReference]
    let requests: [StoredRequestRecord]
    let metadata: [StoredLibraryMetadataRecord]

    var isEmpty: Bool {
      snips.isEmpty && lists.isEmpty && attachments.isEmpty && references.isEmpty
        && requests.isEmpty && metadata.isEmpty
    }
  }

  private struct PreparedAttachments {
    var attachments: [SnipAttachment]
    var createdDirectories: [URL]
  }

  let lockURL: URL
  let attachmentRootURL: URL
  let readOnlyRecoveryMarkerURL: URL
  let recoveryQuarantineCompleteMarkerURL: URL
  let container: ModelContainer?
  let isAvailable: Bool
  let afterMutationBeforeSave: @Sendable () throws -> Void
  var seenRequestIDs: Set<UUID>
  var knownAttachmentPaths: [UUID: String]
  var lastKnownState: SnipLibraryState

  public init(storeURL: URL = SwiftDataSnipLibrary.defaultStoreURL()) throws {
    try self.init(storeURL: storeURL, afterMutationBeforeSave: {})
  }

  package init(
    storeURL: URL,
    afterMutationBeforeSave: @escaping @Sendable () throws -> Void = {},
    metadataBackfillHook: @escaping @Sendable (LibraryMetadataBackfillPoint) throws -> Void = { _ in },
    cloudFullRecordBackfillHook: @escaping @Sendable (CloudFullRecordBackfillPoint) throws -> Void = { _ in }
  ) throws {
    let directory = storeURL.deletingLastPathComponent()
    try DurableFile.createDirectory(directory)
    let lockURL = storeURL.appendingPathExtension("lock")
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let schema = Schema(versionedSchema: SnipSnapSchemaV4.self)
    let configuration = ModelConfiguration(
      "SnipSnapLocal",
      schema: schema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    let container: ModelContainer
    do {
      container = try ModelContainer(
        for: schema,
        migrationPlan: SnipSnapSchemaMigrationPlan.self,
        configurations: [configuration]
      )
    } catch {
      throw SnipLibraryError.invalidStore
    }

    self.lockURL = lockURL
    attachmentRootURL = Self.attachmentRootURL(forStoreURL: storeURL)
    readOnlyRecoveryMarkerURL = Self.readOnlyRecoveryMarkerURL(forStoreURL: storeURL)
    recoveryQuarantineCompleteMarkerURL = Self.recoveryQuarantineCompleteMarkerURL(
      forStoreURL: storeURL
    )
    self.container = container
    isAvailable = true
    self.afterMutationBeforeSave = afterMutationBeforeSave
    seenRequestIDs = []
    knownAttachmentPaths = [:]
    lastKnownState = SnipLibraryState(snips: [], lists: [.inbox], seenRequestIDs: [])

    let context = Self.makeContext(container: container)
    var loaded = try Self.load(context: context, seenRequestIDs: [])
    if loaded.lists.isEmpty {
      guard loaded.isEmpty else { throw SnipLibraryError.invalidStore }
      context.insert(StoredListRecord(.inbox))
      try context.save()
      loaded = try Self.load(context: Self.makeContext(container: container), seenRequestIDs: [])
    }
    if try Self.backfillLibraryMetadata(loaded, context: context) {
      try metadataBackfillHook(.beforeSave)
      try context.save()
      try metadataBackfillHook(.afterSave)
      loaded = try Self.load(context: Self.makeContext(container: container), seenRequestIDs: [])
    }
    if try Self.backfillCloudFullRecords(context: context) {
      try cloudFullRecordBackfillHook(.beforeSave)
      try context.save()
      try cloudFullRecordBackfillHook(.afterSave)
    }
    try Self.validate(loaded.state)
    seenRequestIDs = loaded.state.seenRequestIDs
    lastKnownState = loaded.state
    knownAttachmentPaths = Dictionary(
      loaded.attachments.map { ($0.id, $0.relativePath) },
      uniquingKeysWith: { first, _ in first }
    )
    Self.removeUnreferencedAttachmentDirectories(
      at: attachmentRootURL,
      keeping: Set(loaded.attachments.map(\.relativePath))
    )
    try? Self.publishShareDestinations(loaded.state.lists, storeURL: storeURL)
  }

  private init(unavailableAt storeURL: URL) {
    lockURL = storeURL.appendingPathExtension("lock")
    attachmentRootURL = Self.attachmentRootURL(forStoreURL: storeURL)
    readOnlyRecoveryMarkerURL = Self.readOnlyRecoveryMarkerURL(forStoreURL: storeURL)
    recoveryQuarantineCompleteMarkerURL = Self.recoveryQuarantineCompleteMarkerURL(
      forStoreURL: storeURL
    )
    container = nil
    isAvailable = false
    afterMutationBeforeSave = {}
    seenRequestIDs = []
    knownAttachmentPaths = [:]
    lastKnownState = SnipLibraryState(snips: [], lists: [.inbox], seenRequestIDs: [])
  }

  public static func unavailable(
    storeURL: URL = SwiftDataSnipLibrary.defaultStoreURL()
  ) -> SwiftDataSnipLibrary {
    SwiftDataSnipLibrary(unavailableAt: storeURL)
  }

  public static func defaultStoreURL(fileManager: FileManager = .default) -> URL {
    defaultStoreURL(
      fileManager: fileManager,
      environment: ProcessInfo.processInfo.environment
    )
  }

  package static func defaultStoreURL(
    fileManager: FileManager,
    environment: [String: String]
  ) -> URL {
    if let jsonOverride = environment["SNIP_SNAP_STORE_PATH"],
      !jsonOverride.isEmpty
    {
      return URL(fileURLWithPath: jsonOverride)
        .deletingLastPathComponent()
        .appendingPathComponent("Local", isDirectory: true)
        .appendingPathComponent("snips.store", isDirectory: false)
    }
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return
      base
      .appendingPathComponent("Snip Snap", isDirectory: true)
      .appendingPathComponent("Local", isDirectory: true)
      .appendingPathComponent("snips.store", isDirectory: false)
  }

  package static func attachmentRootURL(forStoreURL storeURL: URL) -> URL {
    storeURL.deletingLastPathComponent()
      .appendingPathComponent("Attachments", isDirectory: true)
  }

  package static func readOnlyRecoveryMarkerURL(forStoreURL storeURL: URL) -> URL {
    storeURL.deletingLastPathComponent()
      .appendingPathComponent(".snipsnap-read-only-recovery", isDirectory: false)
  }

  package static func recoveryQuarantineCompleteMarkerURL(forStoreURL storeURL: URL) -> URL {
    storeURL.deletingLastPathComponent()
      .appendingPathComponent(".snipsnap-recovery-quarantine-complete", isDirectory: false)
  }

  package func markReadOnlyRecovery() throws {
    try DurableFile.write(Data("1".utf8), to: readOnlyRecoveryMarkerURL)
  }

  package func removeReadOnlyRecoveryMarker() throws {
    guard FileManager.default.fileExists(atPath: readOnlyRecoveryMarkerURL.path) else { return }
    try FileManager.default.removeItem(at: readOnlyRecoveryMarkerURL)
  }

  package func isRecoveryQuarantineComplete() -> Bool {
    FileManager.default.fileExists(atPath: recoveryQuarantineCompleteMarkerURL.path)
  }

  package func markRecoveryQuarantineComplete() throws {
    try DurableFile.write(Data("1".utf8), to: recoveryQuarantineCompleteMarkerURL)
  }

  package func removeRecoveryQuarantineCompleteMarker() throws {
    guard FileManager.default.fileExists(atPath: recoveryQuarantineCompleteMarkerURL.path)
    else { return }
    try FileManager.default.removeItem(at: recoveryQuarantineCompleteMarkerURL)
  }

  private static func publishShareDestinations(_ lists: [SnipList], storeURL: URL) throws {
    guard let rootURL = ShareImportPaths.sharedRoot(forStoreURL: storeURL) else { return }
    try ShareDestinationCatalog.write(
      lists,
      to: ShareImportPaths(rootURL: rootURL).catalogURL
    )
  }

  public func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
    _ = try? checkedSnapshot(sortedBy: sortMode)
    return makeSnapshot(state: lastKnownState, sortedBy: sortMode)
  }

  public func checkedSnapshot(sortedBy sortMode: SnipSortMode) throws -> SnipLibrarySnapshot {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let loaded = try Self.load(
      context: Self.makeContext(container: container),
      seenRequestIDs: seenRequestIDs
    )
    lastKnownState = loaded.state
    seenRequestIDs = loaded.state.seenRequestIDs
    rememberAttachments(in: loaded.state)
    return makeSnapshot(state: loaded.state, sortedBy: sortMode)
  }

  public func perform(
    _ command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) throws -> SnipLibraryUpdate {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    guard !FileManager.default.fileExists(atPath: readOnlyRecoveryMarkerURL.path) else {
      throw SnipLibraryError.readOnlyRecovery
    }
    let context = Self.makeContext(container: container)
    let loaded = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
    try Self.validate(loaded.state)
    knownAttachmentPaths.merge(
      loaded.attachments.map { ($0.id, $0.relativePath) },
      uniquingKeysWith: { _, latest in latest }
    )
    var state = loaded.state
    var createdDirectories: [URL] = []

    do {
      let outcome = try state.perform(
        command,
        prepareAttachments: { sourceURLs, currentSnips in
          let prepared = try self.prepareAttachments(sourceURLs, currentSnips: currentSnips)
          createdDirectories.append(contentsOf: prepared.createdDirectories)
          return prepared.attachments
        },
        pruneAttachments: { retainedIDs, currentSnips in
          let liveIDs = Set(currentSnips.flatMap(\.attachments).map(\.id)).union(retainedIDs)
          let retainedPaths = Set(liveIDs.compactMap { self.knownAttachmentPaths[$0] })
          Self.removeUnreferencedAttachmentDirectories(
            at: self.attachmentRootURL,
            keeping: retainedPaths.union(currentSnips.flatMap(\.attachments).map(\.relativePath))
          )
          self.knownAttachmentPaths = self.knownAttachmentPaths.filter {
            liveIDs.contains($0.key)
          }
        }
      )
      let storedRequestIDs = Set(loaded.requests.map(\.id))
      let hasNewRequestIDs = !state.seenRequestIDs.subtracting(storedRequestIDs).isEmpty
      if state.snips != loaded.state.snips || state.lists != loaded.state.lists
        || hasNewRequestIDs
      {
        try Self.applyChanges(from: loaded, to: state, context: context)
        try afterMutationBeforeSave()
        try context.save()
      }
      seenRequestIDs = state.seenRequestIDs
      lastKnownState = state
      rememberAttachments(in: state)
      try? Self.publishShareDestinations(
        state.lists,
        storeURL: lockURL.deletingPathExtension()
      )
      if command.editsAttachments {
        let liveIDs = Set(state.snips.flatMap(\.attachments).map(\.id))
        Self.removeUnreferencedAttachmentDirectories(
          at: attachmentRootURL,
          keeping: Set(state.snips.flatMap(\.attachments).map(\.relativePath))
        )
        knownAttachmentPaths = knownAttachmentPaths.filter { liveIDs.contains($0.key) }
      }
      return SnipLibraryUpdate(
        snapshot: makeSnapshot(state: state, sortedBy: sortMode),
        outcome: outcome
      )
    } catch {
      context.rollback()
      removeAttachmentDirectories(createdDirectories)
      throw error
    }
  }


  static func makeContext(container: ModelContainer) -> ModelContext {
    let context = ModelContext(container)
    context.autosaveEnabled = false
    return context
  }

  private func makeSnapshot(
    state: SnipLibraryState,
    sortedBy sortMode: SnipSortMode
  ) -> SnipLibrarySnapshot {
    let orderedSnips = state.allSnips(sortMode: sortMode)
    return SnipLibrarySnapshot(
      snips: orderedSnips,
      lists: state.allLists(),
      attachmentURLs: Dictionary(
        orderedSnips.flatMap(\.attachments).map {
          ($0.id, attachmentRootURL.appendingPathComponent($0.relativePath))
        },
        uniquingKeysWith: { first, _ in first }
      )
    )
  }

  private func prepareAttachments(
    _ sourceURLs: [URL],
    currentSnips: [Snip]
  ) throws -> PreparedAttachments {
    guard !sourceURLs.isEmpty else {
      return PreparedAttachments(attachments: [], createdDirectories: [])
    }
    let existingByPath = Dictionary(
      currentSnips.flatMap(\.attachments).map { attachment in
        (
          attachmentRootURL.appendingPathComponent(attachment.relativePath).standardizedFileURL
            .path,
          attachment
        )
      },
      uniquingKeysWith: { first, _ in first }
    )
    var prepared: [SnipAttachment] = []
    var createdDirectories: [URL] = []
    do {
      for sourceURL in sourceURLs {
        if let existing = existingByPath[sourceURL.standardizedFileURL.path] {
          if !prepared.contains(where: { $0.id == existing.id }) { prepared.append(existing) }
          continue
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
          !isDirectory.boolValue
        else { throw SnipLibraryError.attachmentCopyFailed }
        let id = UUID()
        let relativePath = "\(id.uuidString)/\(sourceURL.lastPathComponent)"
        let destination = attachmentRootURL.appendingPathComponent(relativePath)
        let destinationDirectory = destination.deletingLastPathComponent()
        try DurableFile.createDirectory(destinationDirectory)
        createdDirectories.append(destinationDirectory)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        try DurableFile.syncFile(destination)
        try DurableFile.syncDirectory(destinationDirectory)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        let contentType = (try? destination.resourceValues(forKeys: [.contentTypeKey]))?
          .contentType?.identifier
          ?? UTType(filenameExtension: destination.pathExtension)?.identifier
        prepared.append(
          SnipAttachment(
            id: id,
            fileName: sourceURL.lastPathComponent,
            relativePath: relativePath,
            contentType: contentType,
            byteCount: Int64(values.fileSize ?? 0)
          ))
      }
      return PreparedAttachments(attachments: prepared, createdDirectories: createdDirectories)
    } catch {
      removeAttachmentDirectories(createdDirectories)
      throw error
    }
  }

  func rememberAttachments(in state: SnipLibraryState) {
    knownAttachmentPaths.merge(
      state.snips.flatMap(\.attachments).map { ($0.id, $0.relativePath) },
      uniquingKeysWith: { _, latest in latest }
    )
  }

  func removeAttachmentDirectories(_ directories: [URL]) {
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
  }

  static func removeUnreferencedAttachmentDirectories(
    at rootURL: URL,
    keeping relativePaths: Set<String>
  ) {
    let keptDirectories = Set(
      relativePaths.compactMap {
        $0.split(separator: "/", maxSplits: 1).first.map(String.init)
      })
    guard
      let directories = try? FileManager.default.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return }
    for directory in directories where !keptDirectories.contains(directory.lastPathComponent) {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  static func load(
    context: ModelContext,
    seenRequestIDs: Set<UUID>
  ) throws -> LoadedStore {
    let storedSnips = try context.fetch(FetchDescriptor<StoredSnipRecord>())
    let storedLists = try context.fetch(FetchDescriptor<StoredListRecord>())
    let storedAttachments = try context.fetch(FetchDescriptor<StoredAttachmentRecord>())
    let storedReferences = try context.fetch(FetchDescriptor<StoredSnipAttachmentReference>())
    let storedRequests = try context.fetch(FetchDescriptor<StoredRequestRecord>())
    let storedMetadata = try context.fetch(FetchDescriptor<StoredLibraryMetadataRecord>())
    let metadataByID = Dictionary(uniqueKeysWithValues: storedMetadata.map { ($0.id, $0) })
    let attachmentsByID = Dictionary(uniqueKeysWithValues: storedAttachments.map { ($0.id, $0) })
    let referencesBySnip = Dictionary(grouping: storedReferences, by: \.snipID)
    let snips = try storedSnips.map { record -> Snip in
      guard let origin = SnipOrigin(rawValue: record.origin) else {
        throw SnipLibraryError.invalidStore
      }
      let source = record.sourceApplicationName.map {
        SnipSource(
          applicationName: $0, windowTitle: record.sourceWindowTitle, url: record.sourceURL)
      }
      return Snip(
        id: record.id,
        requestID: record.requestID,
        createdAt: record.createdAt,
        updatedAt: record.updatedAt,
        content: record.content,
        origin: origin,
        source: source,
        listID: record.listID,
        isDone: record.isDone,
        manualPosition: record.manualPosition,
        manualSortKey: try metadataByID[
          StoredLibraryMetadataRecord.identifier(kind: .snip, domainID: record.id)
        ].map { try SnipOrderKey(data: $0.orderKeyData) },
        attachments: try (referencesBySnip[record.id] ?? []).sorted { $0.position < $1.position }
          .map { reference in
            guard let attachment = attachmentsByID[reference.attachmentID] else {
              throw SnipLibraryError.invalidStore
            }
            return SnipAttachment(
              id: attachment.id,
              fileName: attachment.fileName,
              relativePath: attachment.relativePath,
              contentType: attachment.contentType,
              byteCount: attachment.byteCount
            )
          }
      )
    }
    let lists = try storedLists.map { record in
      let metadata = metadataByID[
        StoredLibraryMetadataRecord.identifier(kind: .list, domainID: record.id)
      ]
      return SnipList(
        id: record.id,
        desiredName: metadata?.desiredName ?? record.name,
        resolvedName: record.name,
        systemImage: record.systemImage,
        sortKey: try metadata.map { try SnipOrderKey(data: $0.orderKeyData) }
          ?? .legacy(Int64(record.position))
      )
    }
    return LoadedStore(
      state: SnipLibraryState(
        snips: snips,
        lists: lists,
        seenRequestIDs: seenRequestIDs
          .union(storedRequests.map(\.id))
          .union(snips.map(\.requestID))
      ),
      snips: storedSnips,
      lists: storedLists,
      attachments: storedAttachments,
      references: storedReferences,
      requests: storedRequests,
      metadata: storedMetadata
    )
  }

  private static func backfillLibraryMetadata(
    _ loaded: LoadedStore,
    context: ModelContext
  ) throws -> Bool {
    var known = Set(loaded.metadata.map(\.id))
    var changed = false
    let listByID = Dictionary(uniqueKeysWithValues: loaded.state.lists.map { ($0.id, $0) })
    for record in loaded.lists {
      let id = StoredLibraryMetadataRecord.identifier(kind: .list, domainID: record.id)
      if known.insert(id).inserted {
        guard let list = listByID[record.id] else { throw SnipLibraryError.invalidStore }
        context.insert(
          StoredLibraryMetadataRecord(
            kind: .list,
            domainID: record.id,
            orderKey: list.sortKey,
            desiredName: list.desiredName
          )
        )
        changed = true
      }
    }
    let snipByID = Dictionary(uniqueKeysWithValues: loaded.state.snips.map { ($0.id, $0) })
    for record in loaded.snips {
      let id = StoredLibraryMetadataRecord.identifier(kind: .snip, domainID: record.id)
      if known.insert(id).inserted {
        guard let snip = snipByID[record.id] else { throw SnipLibraryError.invalidStore }
        context.insert(
          StoredLibraryMetadataRecord(
            kind: .snip,
            domainID: record.id,
            orderKey: snip.manualSortKey,
            legacyPosition: record.manualPosition,
            legacyOrderKey: snip.manualSortKey
          )
        )
        changed = true
      }
    }
    return changed
  }

  package static func validate(_ state: SnipLibraryState) throws {
    guard !state.lists.isEmpty,
      Set(state.lists.map(\.id)).count == state.lists.count,
      Set(state.lists.map { SnipListNameAllocator.normalized($0.name) }).count
        == state.lists.count,
      state.lists.contains(where: { $0.id == SnipList.inboxID }),
      Set(state.snips.map(\.listID)).isSubset(of: Set(state.lists.map(\.id)))
    else { throw SnipLibraryError.invalidStore }
  }

  static func applyChanges(
    from loaded: LoadedStore,
    to state: SnipLibraryState,
    context: ModelContext
  ) throws {
    let storedRequestIDs = Set(loaded.requests.map(\.id))
    for id in state.seenRequestIDs.subtracting(storedRequestIDs) {
      context.insert(StoredRequestRecord(id: id))
    }

    let oldSnips = Dictionary(uniqueKeysWithValues: loaded.state.snips.map { ($0.id, $0) })
    let newSnips = Dictionary(uniqueKeysWithValues: state.snips.map { ($0.id, $0) })
    let snipRecords = Dictionary(uniqueKeysWithValues: loaded.snips.map { ($0.id, $0) })
    for id in Set(oldSnips.keys).subtracting(newSnips.keys) {
      if let record = snipRecords[id] { context.delete(record) }
    }
    for (id, snip) in newSnips where oldSnips[id] != snip {
      if let record = snipRecords[id] {
        record.update(from: snip)
      } else {
        context.insert(StoredSnipRecord(snip))
      }
    }

    let oldLists = Dictionary(uniqueKeysWithValues: loaded.state.lists.map { ($0.id, $0) })
    let newLists = Dictionary(uniqueKeysWithValues: state.lists.map { ($0.id, $0) })
    let listRecords = Dictionary(uniqueKeysWithValues: loaded.lists.map { ($0.id, $0) })
    for id in Set(oldLists.keys).subtracting(newLists.keys) {
      if let record = listRecords[id] { context.delete(record) }
    }
    for (id, list) in newLists where oldLists[id] != list {
      if let record = listRecords[id] {
        record.update(from: list)
      } else {
        context.insert(StoredListRecord(list))
      }
    }

    let metadataRecords = Dictionary(uniqueKeysWithValues: loaded.metadata.map { ($0.id, $0) })
    let liveMetadataIDs = Set(
      state.snips.map {
        StoredLibraryMetadataRecord.identifier(kind: .snip, domainID: $0.id)
      } + state.lists.map {
        StoredLibraryMetadataRecord.identifier(kind: .list, domainID: $0.id)
      }
    )
    for record in loaded.metadata where !liveMetadataIDs.contains(record.id) {
      context.delete(record)
    }
    for snip in state.snips {
      let id = StoredLibraryMetadataRecord.identifier(kind: .snip, domainID: snip.id)
      if let record = metadataRecords[id] {
        record.update(orderKey: snip.manualSortKey)
      } else {
        context.insert(
          StoredLibraryMetadataRecord(
            kind: .snip,
            domainID: snip.id,
            orderKey: snip.manualSortKey
          )
        )
      }
    }
    for list in state.lists {
      let id = StoredLibraryMetadataRecord.identifier(kind: .list, domainID: list.id)
      if let record = metadataRecords[id] {
        record.update(orderKey: list.sortKey, desiredName: list.desiredName)
      } else {
        context.insert(
          StoredLibraryMetadataRecord(
            kind: .list,
            domainID: list.id,
            orderKey: list.sortKey,
            desiredName: list.desiredName
          )
        )
      }
    }

    let oldAttachments = attachmentMap(loaded.state.snips)
    let newAttachments = attachmentMap(state.snips)
    let attachmentRecords = Dictionary(uniqueKeysWithValues: loaded.attachments.map { ($0.id, $0) })
    for id in Set(oldAttachments.keys).subtracting(newAttachments.keys) {
      if let record = attachmentRecords[id] { context.delete(record) }
    }
    for (id, attachment) in newAttachments where oldAttachments[id] != attachment {
      if let record = attachmentRecords[id] {
        record.update(from: attachment)
      } else {
        context.insert(StoredAttachmentRecord(attachment))
      }
    }

    let oldReferences = referenceMap(loaded.state.snips)
    let newReferences = referenceMap(state.snips)
    let referenceRecords = Dictionary(uniqueKeysWithValues: loaded.references.map { ($0.id, $0) })
    for id in Set(oldReferences.keys).subtracting(newReferences.keys) {
      if let record = referenceRecords[id] { context.delete(record) }
    }
    for (id, value) in newReferences where oldReferences[id] != value {
      if let record = referenceRecords[id] {
        record.update(position: value.position)
      } else {
        context.insert(
          StoredSnipAttachmentReference(
            snipID: value.snipID,
            attachmentID: value.attachmentID,
            position: value.position
          ))
      }
    }
  }

  private struct AttachmentReferenceValue: Equatable {
    let snipID: UUID
    let attachmentID: UUID
    let position: Int
  }

  private static func attachmentMap(_ snips: [Snip]) -> [UUID: SnipAttachment] {
    Dictionary(
      snips.flatMap(\.attachments).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  private static func referenceMap(_ snips: [Snip]) -> [String: AttachmentReferenceValue] {
    Dictionary(
      uniqueKeysWithValues: snips.flatMap { snip in
        snip.attachments.enumerated().map { position, attachment in
          let value = AttachmentReferenceValue(
            snipID: snip.id,
            attachmentID: attachment.id,
            position: position
          )
          return (
            StoredSnipAttachmentReference.identifier(
              snipID: snip.id,
              attachmentID: attachment.id
            ), value
          )
        }
      })
  }
}


private extension SnipLibraryCommand {
  var editsAttachments: Bool {
    if case .editAttachments = self { return true }
    return false
  }
}
