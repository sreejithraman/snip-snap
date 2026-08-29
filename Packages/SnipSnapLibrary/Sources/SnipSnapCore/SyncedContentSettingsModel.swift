import Foundation
import Observation

public enum SyncedContentMode: Equatable, Sendable {
  case localOnly
  case iCloudSync
}

public enum SyncedContentSettingsState: Equatable, Sendable {
  case ready
  case deleting
  case deleted
  case failed(String)
}

@MainActor
@Observable
public final class SyncedContentSettingsModel {
  public typealias DeleteAction = @Sendable () async throws -> Void

  public let mode: SyncedContentMode
  public private(set) var state: SyncedContentSettingsState
  private let deleteAction: DeleteAction?

  public init(
    mode: SyncedContentMode,
    deleteAction: DeleteAction? = nil
  ) {
    self.mode = mode
    self.deleteAction = deleteAction
    state = .ready
  }

  public var canDelete: Bool {
    guard mode == .iCloudSync, deleteAction != nil else { return false }
    return switch state {
    case .ready, .failed: true
    case .deleting, .deleted: false
    }
  }

  public var statusTitle: String {
    switch (mode, state) {
    case (.localOnly, _): "Local Only"
    case (_, .ready): "iCloud Sync On"
    case (_, .deleting): "Deleting Synced Content…"
    case (_, .deleted): "Synced Content Deleted"
    case (_, .failed): "Delete Needs Attention"
    }
  }

  public var detail: String {
    switch (mode, state) {
    case (.localOnly, _):
      "Saved snips and attachments stay on this device. Nothing is uploaded to iCloud."
    case (_, .ready):
      "Saved snips and attachments sync through your private iCloud database."
    case (_, .deleting):
      "Snip Snap is starting a fresh empty synced collection and removing the old data zones."
    case (_, .deleted):
      "Synced content was removed. This device kept a local recovery copy. A small control record remains in iCloud so an old device cannot restore the deleted collection."
    case (_, .failed(let message)):
      "Snip Snap could not finish deleting synced content. Your local recovery copy was not removed. \(message)"
    }
  }

  public func deleteSyncedContent() async {
    guard canDelete, let deleteAction else { return }
    state = .deleting
    do {
      try await deleteAction()
      state = .deleted
    } catch {
      state = .failed(error.localizedDescription)
    }
  }
}
