import Foundation
import SnipSnapCore

public actor SnipLibraryDeviceActions: SnipLibraryUserActions {
  private struct Entry: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let patch: SnipLibraryDevicePatch

    init(id: UUID = UUID(), name: String, patch: SnipLibraryDevicePatch) {
      self.id = id
      self.name = name
      self.patch = patch
    }
  }

  private struct Journal: Codable, Equatable, Sendable {
    var version = 2
    var collectionIdentity: SnipLibraryCollectionIdentity?
    var undo: [Entry] = []
    var redo: [Entry] = []
  }

  private static let historyLimit = 100

  private let library: any SnipLibrary
  private let journalURL: URL
  private let now: @Sendable () -> Date
  private let collectionIdentity: @Sendable () async -> SnipLibraryCollectionIdentity
  private var journal: Journal

  public init(
    library: any SnipLibrary,
    journalURL: URL,
    now: @escaping @Sendable () -> Date = Date.init,
    collectionIdentity: @escaping @Sendable () async -> SnipLibraryCollectionIdentity = {
      SnipLibraryCollectionIdentity(digest: Data("snipsnap-unscoped-library".utf8))
    }
  ) {
    self.library = library
    self.journalURL = journalURL
    self.now = now
    self.collectionIdentity = collectionIdentity
    journal = Self.readJournal(at: journalURL)
  }

  public func perform(
    name: String,
    command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    if try await prepareCollection() {
      await reconcileAttachmentStorage(sortMode: sortMode)
    }
    let fallbackBefore = try await library.checkedSnapshot(sortedBy: sortMode)
    let update = try await library.perform(command, sortedBy: sortMode)
    let patch = update.devicePatch ?? .between(fallbackBefore, update.snapshot)
    record(name: name, patch: patch)
    persistOrClear()
    await reconcileAttachmentStorage(sortMode: sortMode)
    return update
  }

  public func previewImport(backupURL: URL) async throws -> SnipImportPreview {
    if try await prepareCollection() {
      await reconcileAttachmentStorage(sortMode: .chronological)
    }
    return try await SnipLibraryImport.preview(backupURL: backupURL, target: library)
  }

  public func applyImport(
    _ preview: SnipImportPreview,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipImportResult {
    if try await prepareCollection() {
      await reconcileAttachmentStorage(sortMode: sortMode)
    }
    let applied = try await library.applyImport(preview)
    let result = SnipImportResult(
      snapshot: try await library.checkedSnapshot(sortedBy: sortMode),
      addedSnipCount: applied.addedSnipCount,
      recoveredSnipCount: applied.recoveredSnipCount
    )
    record(
      name: "Import Backup",
      patch: applied.devicePatch ?? preview.devicePatch
    )
    persistOrClear()
    await reconcileAttachmentStorage(sortMode: sortMode)
    return result
  }

  public func state(sortedBy sortMode: SnipSortMode) async throws -> SnipDeviceActionState {
    if try await prepareCollection() {
      await reconcileAttachmentStorage(sortMode: sortMode)
    }
    let snapshot = try await library.checkedSnapshot(sortedBy: sortMode)
    let removedEntries = reconcile(with: snapshot)
    persistOrClear()
    if removedEntries { await reconcileAttachmentStorage(sortMode: sortMode) }
    return currentState
  }

  public func undo(sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate? {
    while true {
      if try await prepareCollection() {
        await reconcileAttachmentStorage(sortMode: sortMode)
      }
      let snapshot = try await library.checkedSnapshot(sortedBy: sortMode)
      let removedEntries = reconcileUndo(with: snapshot)
      if removedEntries {
        persistOrClear()
        await reconcileAttachmentStorage(sortMode: sortMode)
      }
      guard let entry = journal.undo.last else {
        persistOrClear()
        return nil
      }
      do {
        let update = try await library.perform(
          .applyDevicePatch(entry.patch.reversed, now: now()),
          sortedBy: sortMode
        )
        journal.undo.removeLast()
        journal.redo.append(entry)
        trim(&journal.redo)
        persistOrClear()
        await reconcileAttachmentStorage(sortMode: sortMode)
        return update
      } catch SnipLibraryError.deviceActionChanged {
        journal.undo.removeLast()
        persistOrClear()
        await reconcileAttachmentStorage(sortMode: sortMode)
      }
    }
  }

  public func redo(sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate? {
    while true {
      if try await prepareCollection() {
        await reconcileAttachmentStorage(sortMode: sortMode)
      }
      let snapshot = try await library.checkedSnapshot(sortedBy: sortMode)
      let removedEntries = reconcileRedo(with: snapshot)
      if removedEntries {
        persistOrClear()
        await reconcileAttachmentStorage(sortMode: sortMode)
      }
      guard let entry = journal.redo.last else {
        persistOrClear()
        return nil
      }
      do {
        let update = try await library.perform(
          .applyDevicePatch(entry.patch, now: now()),
          sortedBy: sortMode
        )
        journal.redo.removeLast()
        journal.undo.append(entry)
        trim(&journal.undo)
        persistOrClear()
        await reconcileAttachmentStorage(sortMode: sortMode)
        return update
      } catch SnipLibraryError.deviceActionChanged {
        journal.redo.removeLast()
        persistOrClear()
        await reconcileAttachmentStorage(sortMode: sortMode)
      }
    }
  }

  public func clear(sortedBy sortMode: SnipSortMode) async throws {
    _ = try await prepareCollection()
    journal = Journal(collectionIdentity: journal.collectionIdentity)
    try persist()
    await reconcileAttachmentStorage(sortMode: sortMode)
  }

  public static func defaultJournalURL(nextTo storeURL: URL) -> URL {
    storeURL.deletingLastPathComponent()
      .appendingPathComponent("DeviceActions.json", isDirectory: false)
  }

  private var currentState: SnipDeviceActionState {
    SnipDeviceActionState(
      undoTitle: journal.undo.last.map { "Undo \($0.name)" } ?? "Undo",
      redoTitle: journal.redo.last.map { "Redo \($0.name)" } ?? "Redo",
      undoActionIDs: journal.undo.map(\.id),
      redoActionIDs: journal.redo.map(\.id)
    )
  }

  private func prepareCollection() async throws -> Bool {
    let current = await collectionIdentity()
    guard journal.collectionIdentity != current else { return false }
    journal = Journal(collectionIdentity: current)
    try persist()
    return true
  }

  private func record(
    name: String,
    before: SnipLibrarySnapshot,
    after: SnipLibrarySnapshot
  ) {
    record(name: name, patch: .between(before, after))
  }

  private func record(name: String, patch: SnipLibraryDevicePatch) {
    guard !patch.isEmpty else { return }
    journal.undo.append(Entry(name: name, patch: patch))
    trim(&journal.undo)
    journal.redo = []
  }

  private func reconcile(with snapshot: SnipLibrarySnapshot) -> Bool {
    let removedUndo = reconcileUndo(with: snapshot)
    let removedRedo = reconcileRedo(with: snapshot)
    return removedUndo || removedRedo
  }

  private func reconcileUndo(with snapshot: SnipLibrarySnapshot) -> Bool {
    var simulated = snapshot
    var keptNewestFirst: [Entry] = []
    for entry in journal.undo.reversed() {
      guard let next = entry.patch.reversed.applying(to: simulated) else { continue }
      keptNewestFirst.append(entry)
      simulated = next
    }
    let kept = Array(keptNewestFirst.reversed())
    guard kept != journal.undo else { return false }
    journal.undo = kept
    return true
  }

  private func reconcileRedo(with snapshot: SnipLibrarySnapshot) -> Bool {
    var simulated = snapshot
    var keptNewestFirst: [Entry] = []
    for entry in journal.redo.reversed() {
      guard let next = entry.patch.applying(to: simulated) else { continue }
      keptNewestFirst.append(entry)
      simulated = next
    }
    let kept = Array(keptNewestFirst.reversed())
    guard kept != journal.redo else { return false }
    journal.redo = kept
    return true
  }

  private func trim(_ entries: inout [Entry]) {
    if entries.count > Self.historyLimit {
      entries.removeFirst(entries.count - Self.historyLimit)
    }
  }

  private func retainedAttachmentIDs() -> Set<UUID> {
    Set((journal.undo + journal.redo).flatMap { entry in
      (entry.patch.snips.compactMap(\.before) + entry.patch.snips.compactMap(\.after))
        .flatMap(\.attachments).map(\.id)
    })
  }

  private func reconcileAttachmentStorage(sortMode: SnipSortMode) async {
    _ = try? await library.perform(
      .pruneAttachments(retaining: retainedAttachmentIDs()),
      sortedBy: sortMode
    )
  }

  private func persistOrClear() {
    do {
      try persist()
    } catch {
      journal = Journal(collectionIdentity: journal.collectionIdentity)
      try? DurableFile.write(try JSONEncoder().encode(journal), to: journalURL)
    }
  }

  private func persist() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try DurableFile.write(try encoder.encode(journal), to: journalURL)
  }

  private static func readJournal(at url: URL) -> Journal {
    guard let data = try? Data(contentsOf: url),
      let value = try? JSONDecoder().decode(Journal.self, from: data),
      value.version == 2
    else { return Journal(collectionIdentity: nil) }
    return value
  }
}
