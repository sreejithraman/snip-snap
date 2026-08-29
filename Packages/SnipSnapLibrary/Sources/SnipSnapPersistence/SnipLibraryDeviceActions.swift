import Foundation
import SnipSnapCore

public struct SnipDeviceActionState: Equatable, Sendable {
  public let undoTitle: String
  public let redoTitle: String
  public let canUndo: Bool
  public let canRedo: Bool
  public let undoCount: Int
  public let redoCount: Int

  public init(
    undoTitle: String,
    redoTitle: String,
    canUndo: Bool,
    canRedo: Bool,
    undoCount: Int,
    redoCount: Int
  ) {
    self.undoTitle = undoTitle
    self.redoTitle = redoTitle
    self.canUndo = canUndo
    self.canRedo = canRedo
    self.undoCount = undoCount
    self.redoCount = redoCount
  }
}

public actor SnipLibraryDeviceActions {
  private struct Entry: Codable, Equatable, Sendable {
    let name: String
    let patch: SnipLibraryDevicePatch
  }

  private struct Journal: Codable, Equatable, Sendable {
    var version = 1
    var undo: [Entry] = []
    var redo: [Entry] = []
  }

  private static let historyLimit = 100

  private let library: any SnipLibrary
  private let journalURL: URL
  private let now: @Sendable () -> Date
  private var journal: Journal

  public init(
    library: any SnipLibrary,
    journalURL: URL,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.library = library
    self.journalURL = journalURL
    self.now = now
    journal = Self.readJournal(at: journalURL)
  }

  public func perform(
    name: String,
    command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    let fallbackBefore = try await library.checkedSnapshot(sortedBy: sortMode)
    let update = try await library.perform(command, sortedBy: sortMode)
    let patch = update.devicePatch ?? .between(fallbackBefore, update.snapshot)
    let touchesAttachments = record(name: name, patch: patch)
    persistOrClear()
    if touchesAttachments { await reconcileAttachmentStorage(sortMode: sortMode) }
    return update
  }

  public func applyImport(
    _ preview: SnipImportPreview,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipImportResult {
    let before = try await library.checkedSnapshot(sortedBy: sortMode)
    let result = try await library.applyImport(preview)
    let touchesAttachments = record(
      name: "Import Backup",
      before: before,
      after: result.snapshot
    )
    persistOrClear()
    if touchesAttachments { await reconcileAttachmentStorage(sortMode: sortMode) }
    return result
  }

  public func state(sortedBy sortMode: SnipSortMode) async throws -> SnipDeviceActionState {
    let snapshot = try await library.checkedSnapshot(sortedBy: sortMode)
    reconcile(with: snapshot)
    persistOrClear()
    return currentState
  }

  public func undo(sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate? {
    while true {
      let snapshot = try await library.checkedSnapshot(sortedBy: sortMode)
      reconcileUndo(with: snapshot)
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
        if entry.patch.touchesAttachments {
          await reconcileAttachmentStorage(sortMode: sortMode)
        }
        return update
      } catch SnipLibraryError.deviceActionChanged {
        journal.undo.removeLast()
      }
    }
  }

  public func redo(sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate? {
    while true {
      let snapshot = try await library.checkedSnapshot(sortedBy: sortMode)
      reconcileRedo(with: snapshot)
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
        if entry.patch.touchesAttachments {
          await reconcileAttachmentStorage(sortMode: sortMode)
        }
        return update
      } catch SnipLibraryError.deviceActionChanged {
        journal.redo.removeLast()
      }
    }
  }

  public func clear(sortedBy sortMode: SnipSortMode) async {
    journal = Journal()
    persistOrClear()
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
      canUndo: !journal.undo.isEmpty,
      canRedo: !journal.redo.isEmpty,
      undoCount: journal.undo.count,
      redoCount: journal.redo.count
    )
  }

  private func record(
    name: String,
    before: SnipLibrarySnapshot,
    after: SnipLibrarySnapshot
  ) -> Bool {
    record(name: name, patch: .between(before, after))
  }

  private func record(name: String, patch: SnipLibraryDevicePatch) -> Bool {
    guard !patch.isEmpty else { return false }
    journal.undo.append(Entry(name: name, patch: patch))
    trim(&journal.undo)
    journal.redo = []
    return patch.touchesAttachments
  }

  private func reconcile(with snapshot: SnipLibrarySnapshot) {
    reconcileUndo(with: snapshot)
    reconcileRedo(with: snapshot)
  }

  private func reconcileUndo(with snapshot: SnipLibrarySnapshot) {
    while let entry = journal.undo.last,
      !entry.patch.reversed.canApply(to: snapshot)
    {
      journal.undo.removeLast()
    }
  }

  private func reconcileRedo(with snapshot: SnipLibrarySnapshot) {
    while let entry = journal.redo.last,
      !entry.patch.canApply(to: snapshot)
    {
      journal.redo.removeLast()
    }
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
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try DurableFile.write(try encoder.encode(journal), to: journalURL)
    } catch {
      journal = Journal()
      try? DurableFile.write(try JSONEncoder().encode(journal), to: journalURL)
    }
  }

  private static func readJournal(at url: URL) -> Journal {
    guard let data = try? Data(contentsOf: url),
      let value = try? JSONDecoder().decode(Journal.self, from: data),
      value.version == 1
    else { return Journal() }
    return value
  }
}

private extension SnipLibraryDevicePatch {
  var touchesAttachments: Bool {
    snips.contains {
      ($0.before?.attachments ?? []) != ($0.after?.attachments ?? [])
    }
  }
}
