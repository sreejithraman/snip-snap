import Foundation

public protocol SnipLibraryUserActions: Sendable {
  func perform(
    command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate

  func delete(
    ids: Set<UUID>,
    token: UUID,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate

  func restoreDeletion(
    token: UUID,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate?

  func discardDeletion(token: UUID, sortedBy sortMode: SnipSortMode) async

  func previewImport(backupURL: URL) async throws -> SnipImportPreview

  func applyImport(
    _ preview: SnipImportPreview,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipImportResult

}

public typealias SnipBackupImportPreviewer = @Sendable (
  _ backupURL: URL,
  _ target: any SnipLibrary
) async throws -> SnipImportPreview

public struct SnipLibraryUserActionsRebinder: Sendable {
  private let makeActions: @Sendable (any SnipLibrary) -> any SnipLibraryUserActions

  public init(
    _ makeActions: @escaping @Sendable (any SnipLibrary) -> any SnipLibraryUserActions
  ) {
    self.makeActions = makeActions
  }

  public static var direct: Self {
    Self { DirectSnipLibraryUserActions(library: $0) }
  }

  public func actions(for library: any SnipLibrary) -> any SnipLibraryUserActions {
    makeActions(library)
  }
}

public actor DirectSnipLibraryUserActions: SnipLibraryUserActions {
  private struct PendingDeletion: Sendable {
    let token: UUID
    let snips: [Snip]
  }

  private let library: any SnipLibrary
  private let previewBackupImport: SnipBackupImportPreviewer
  private var pendingDeletion: PendingDeletion?
  private var mutationInProgress = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    library: any SnipLibrary,
    previewBackupImport: @escaping SnipBackupImportPreviewer = { _, _ in
      throw SnipLibraryError.transferUnsupported
    }
  ) {
    self.library = library
    self.previewBackupImport = previewBackupImport
  }

  public func perform(
    command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    await acquireMutation()
    defer { releaseMutation() }
    let update = try await library.perform(command, sortedBy: sortMode)
    await discardPendingDeletion(sortedBy: sortMode)
    return update
  }

  public func delete(
    ids: Set<UUID>,
    token: UUID,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    await acquireMutation()
    defer { releaseMutation() }
    let before = try await library.checkedSnapshot(sortedBy: sortMode)
    let deleted = before.snips.filter { ids.contains($0.id) }
    let update = try await library.perform(.delete(ids: ids), sortedBy: sortMode)
    pendingDeletion = deleted.isEmpty ? nil : PendingDeletion(token: token, snips: deleted)
    await pruneAttachments(
      retaining: Set(deleted.flatMap(\.attachments).map(\.id)),
      sortedBy: sortMode
    )
    return update
  }

  public func restoreDeletion(
    token: UUID,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate? {
    await acquireMutation()
    defer { releaseMutation() }
    guard let pendingDeletion, pendingDeletion.token == token else { return nil }
    self.pendingDeletion = nil
    do {
      let update = try await library.perform(
        .restore(snips: pendingDeletion.snips),
        sortedBy: sortMode
      )
      await pruneAttachments(retaining: [], sortedBy: sortMode)
      return update
    } catch {
      if self.pendingDeletion == nil {
        self.pendingDeletion = pendingDeletion
      }
      throw error
    }
  }

  public func discardDeletion(token: UUID, sortedBy sortMode: SnipSortMode) async {
    await acquireMutation()
    defer { releaseMutation() }
    guard pendingDeletion?.token == token else { return }
    await discardPendingDeletion(sortedBy: sortMode)
  }

  public func previewImport(backupURL: URL) async throws -> SnipImportPreview {
    try await previewBackupImport(backupURL, library)
  }

  public func applyImport(
    _ preview: SnipImportPreview,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipImportResult {
    await acquireMutation()
    defer { releaseMutation() }
    let applied = try await library.applyImport(preview)
    await discardPendingDeletion(sortedBy: sortMode)
    return SnipImportResult(
      snapshot: try await library.checkedSnapshot(sortedBy: sortMode),
      addedSnipCount: applied.addedSnipCount,
      recoveredSnipCount: applied.recoveredSnipCount
    )
  }

  private func acquireMutation() async {
    guard mutationInProgress else {
      mutationInProgress = true
      return
    }
    await withCheckedContinuation { mutationWaiters.append($0) }
  }

  private func releaseMutation() {
    guard !mutationWaiters.isEmpty else {
      mutationInProgress = false
      return
    }
    mutationWaiters.removeFirst().resume()
  }

  private func discardPendingDeletion(sortedBy sortMode: SnipSortMode) async {
    pendingDeletion = nil
    await pruneAttachments(retaining: [], sortedBy: sortMode)
  }

  private func pruneAttachments(
    retaining ids: Set<UUID>,
    sortedBy sortMode: SnipSortMode
  ) async {
    _ = try? await library.perform(.pruneAttachments(retaining: ids), sortedBy: sortMode)
  }
}
