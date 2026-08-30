import Foundation

public struct SnipLibraryCollectionIdentity: Codable, Equatable, Hashable, Sendable {
  public let digest: Data

  public init(digest: Data) {
    self.digest = digest
  }
}

public struct SnipDeviceActionState: Equatable, Sendable {
  public let undoTitle: String
  public let redoTitle: String
  public let undoActionIDs: [UUID]
  public let redoActionIDs: [UUID]

  public var canUndo: Bool { !undoActionIDs.isEmpty }
  public var canRedo: Bool { !redoActionIDs.isEmpty }
  public var undoCount: Int { undoActionIDs.count }
  public var redoCount: Int { redoActionIDs.count }

  public init(
    undoTitle: String,
    redoTitle: String,
    undoActionIDs: [UUID] = [],
    redoActionIDs: [UUID] = []
  ) {
    self.undoTitle = undoTitle
    self.redoTitle = redoTitle
    self.undoActionIDs = undoActionIDs
    self.redoActionIDs = redoActionIDs
  }
}

public protocol SnipLibraryUserActions: Sendable {
  func perform(
    name: String,
    command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate

  func previewImport(backupURL: URL) async throws -> SnipImportPreview

  func applyImport(
    _ preview: SnipImportPreview,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipImportResult

  func state(sortedBy sortMode: SnipSortMode) async throws -> SnipDeviceActionState
  func undo(sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate?
  func redo(sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate?
  func clear(sortedBy sortMode: SnipSortMode) async throws
}

public actor DirectSnipLibraryUserActions: SnipLibraryUserActions {
  private let library: any SnipLibrary

  public init(library: any SnipLibrary) {
    self.library = library
  }

  public func perform(
    name: String,
    command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    _ = name
    let update = try await library.perform(command, sortedBy: sortMode)
    _ = try? await library.perform(.pruneAttachments(retaining: []), sortedBy: sortMode)
    return update
  }

  public func previewImport(backupURL: URL) async throws -> SnipImportPreview {
    _ = backupURL
    throw SnipLibraryError.transferUnsupported
  }

  public func applyImport(
    _ preview: SnipImportPreview,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipImportResult {
    let applied = try await library.applyImport(preview)
    let result = SnipImportResult(
      snapshot: try await library.checkedSnapshot(sortedBy: sortMode),
      addedSnipCount: applied.addedSnipCount,
      recoveredSnipCount: applied.recoveredSnipCount
    )
    _ = try? await library.perform(.pruneAttachments(retaining: []), sortedBy: sortMode)
    return result
  }

  public func state(sortedBy sortMode: SnipSortMode) async throws -> SnipDeviceActionState {
    _ = sortMode
    return SnipDeviceActionState(
      undoTitle: "Undo",
      redoTitle: "Redo"
    )
  }

  public func undo(sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate? {
    _ = sortMode
    return nil
  }

  public func redo(sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate? {
    _ = sortMode
    return nil
  }

  public func clear(sortedBy sortMode: SnipSortMode) async throws {
    _ = sortMode
  }
}
