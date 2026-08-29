import Foundation
import Observation

public enum SyncedContentMode: Equatable, Sendable {
  case localOnly
  case iCloudSync
}

public enum SyncedContentSettingsState: Equatable, Sendable {
  case ready
  case enabling
  case deleting
  case removalPending
  case deleted
  case failed(String)
}

public enum SyncedContentDeleteOutcome: Equatable, Sendable {
  case completed
  case removalPending
}

@MainActor
@Observable
public final class SyncedContentSettingsModel {
  public typealias EnableAction = @Sendable () async throws -> Void
  public typealias DeleteAction = @Sendable () async throws -> SyncedContentDeleteOutcome
  public typealias DeleteCompletionAction = @MainActor @Sendable () async throws -> Void

  public private(set) var mode: SyncedContentMode
  public private(set) var state: SyncedContentSettingsState
  private let enableAction: EnableAction?
  private let deleteAction: DeleteAction?
  private var enableCompletionAction: DeleteCompletionAction?
  private var deleteCompletionAction: DeleteCompletionAction?

  public init(
    mode: SyncedContentMode,
    initialState: SyncedContentSettingsState = .ready,
    enableAction: EnableAction? = nil,
    deleteAction: DeleteAction? = nil
  ) {
    self.mode = mode
    self.enableAction = enableAction
    self.deleteAction = deleteAction
    state = initialState
  }

  public func setEnableCompletionAction(_ action: @escaping DeleteCompletionAction) {
    enableCompletionAction = action
  }

  public func setDeleteCompletionAction(_ action: @escaping DeleteCompletionAction) {
    deleteCompletionAction = action
  }

  public var canDelete: Bool {
    guard mode == .iCloudSync, deleteAction != nil else { return false }
    return switch state {
    case .ready, .failed: true
    case .enabling, .deleting, .removalPending, .deleted: false
    }
  }

  public var canEnable: Bool {
    mode == .localOnly && enableAction != nil && state != .enabling
  }

  public var statusTitle: String {
    switch (mode, state) {
    case (.localOnly, .enabling): "Setting Up iCloud Sync…"
    case (.localOnly, _): "Local Only"
    case (_, .ready): "iCloud Sync On"
    case (_, .enabling): "Setting Up iCloud Sync…"
    case (_, .deleting): "Deleting Synced Content…"
    case (_, .removalPending): "Old Synced Content Removal Pending"
    case (_, .deleted): "Synced Content Deleted"
    case (_, .failed): "Delete Needs Attention"
    }
  }

  public var detail: String {
    switch (mode, state) {
    case (.localOnly, .enabling):
      "Snip Snap is fetching iCloud data and preparing a safe merged copy."
    case (.iCloudSync, .enabling):
      "Snip Snap is finishing iCloud Sync setup."
    case (.localOnly, _):
      "Saved snips and attachments stay on this device. Nothing is uploaded to iCloud."
    case (_, .ready):
      "Saved snips and attachments sync through your private iCloud database."
    case (_, .deleting):
      "Snip Snap is starting a fresh empty synced collection and removing the old data zones."
    case (_, .removalPending):
      "Snip Snap started a fresh empty synced collection, but it could not remove all old iCloud data yet. It will retry the next time it syncs. Your local recovery copy remains."
    case (_, .deleted):
      "Synced content was removed. This device kept a local recovery copy. A small control record remains in iCloud so an old device cannot restore the deleted collection."
    case (_, .failed(let message)):
      "Snip Snap could not finish deleting synced content. Your local recovery copy was not removed. \(message)"
    }
  }

  public func enableICloudSync() async {
    guard canEnable, let enableAction else { return }
    state = .enabling
    do {
      try await enableAction()
      try await enableCompletionAction?()
      mode = .iCloudSync
      state = .ready
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  public func recordRemovalPending(_ pending: Bool) {
    guard mode == .iCloudSync else { return }
    state = pending ? .removalPending : .deleted
  }

  public func deleteSyncedContent() async {
    guard canDelete, let deleteAction else { return }
    state = .deleting
    do {
      let outcome = try await deleteAction()
      try await deleteCompletionAction?()
      state = outcome == .completed ? .deleted : .removalPending
    } catch {
      state = .failed(error.localizedDescription)
    }
  }
}
