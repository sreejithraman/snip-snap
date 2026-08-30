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
  case encryptedDataReset
  case resolvingEncryptedDataReset
  case removalPending
  case deleted
  case failed(String)
}

public enum EncryptedDataResetChoice: String, Codable, Equatable, Sendable {
  case restoreFromThisDevice
  case startEmpty
  case keepSyncOff
}

public enum EncryptedDataResetResolutionOutcome: Equatable, Sendable {
  case resolved
  case requiresChoice
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
  public typealias EncryptedDataResetAction = @Sendable (
    EncryptedDataResetChoice
  ) async throws -> EncryptedDataResetResolutionOutcome
  public typealias EncryptedDataResetCompletionAction = @MainActor @Sendable () async throws -> Void

  public private(set) var mode: SyncedContentMode
  public private(set) var state: SyncedContentSettingsState
  private let enableAction: EnableAction?
  private let deleteAction: DeleteAction?
  private let encryptedDataResetAction: EncryptedDataResetAction?
  private var enableCompletionAction: DeleteCompletionAction?
  private var deleteCompletionAction: DeleteCompletionAction?
  private var encryptedDataResetCompletionAction: EncryptedDataResetCompletionAction?

  public init(
    mode: SyncedContentMode,
    initialState: SyncedContentSettingsState = .ready,
    enableAction: EnableAction? = nil,
    deleteAction: DeleteAction? = nil,
    encryptedDataResetAction: EncryptedDataResetAction? = nil
  ) {
    self.mode = mode
    self.enableAction = enableAction
    self.deleteAction = deleteAction
    self.encryptedDataResetAction = encryptedDataResetAction
    state = initialState
  }

  public func setEnableCompletionAction(_ action: @escaping DeleteCompletionAction) {
    enableCompletionAction = action
  }

  public func setDeleteCompletionAction(_ action: @escaping DeleteCompletionAction) {
    deleteCompletionAction = action
  }

  public func setEncryptedDataResetCompletionAction(
    _ action: @escaping EncryptedDataResetCompletionAction
  ) {
    encryptedDataResetCompletionAction = action
  }

  public var canDelete: Bool {
    guard mode == .iCloudSync, deleteAction != nil else { return false }
    return switch state {
    case .ready, .failed: true
    case .enabling, .deleting, .encryptedDataReset, .resolvingEncryptedDataReset,
         .removalPending, .deleted: false
    }
  }

  public var canEnable: Bool {
    mode == .localOnly && enableAction != nil && state != .enabling
  }

  public var statusTitle: String {
    switch (mode, state) {
    case (_, .failed): "Sync Needs Attention"
    case (.localOnly, .enabling): "Setting Up iCloud Sync…"
    case (.localOnly, _): "Local Only"
    case (_, .ready): "iCloud Sync On"
    case (_, .enabling): "Setting Up iCloud Sync…"
    case (_, .deleting): "Deleting Synced Content…"
    case (_, .encryptedDataReset): "iCloud Encrypted Data Was Reset"
    case (_, .resolvingEncryptedDataReset): "Starting a New Synced Collection…"
    case (_, .removalPending): "Old Synced Content Removal Pending"
    case (_, .deleted): "Synced Content Deleted"
    }
  }

  public var detail: String {
    switch (mode, state) {
    case (_, .failed(let message)):
      "Snip Snap could not finish the iCloud action. Nothing was uploaded or removed. \(message)"
    case (.localOnly, .enabling):
      "Snip Snap is fetching iCloud data and preparing a safe merged copy."
    case (.iCloudSync, .enabling):
      "Snip Snap is finishing iCloud Sync setup."
    case (.localOnly, _):
      "Saved snips and attachments stay on this device. Nothing is uploaded to iCloud."
    case (_, .ready):
      "Saved snips and attachments sync through your private iCloud database. Snip Snap’s maintainers cannot inspect private records in CloudKit Console. Apple encrypts synced data in transit and at rest; user fields use encrypted values and files use CKAsset data. This data is end-to-end encrypted only when Advanced Data Protection is on."
    case (_, .deleting):
      "Snip Snap is starting a fresh empty synced collection and removing the old data zones."
    case (_, .encryptedDataReset):
      "Snip Snap stopped sync and kept this device’s snips and available attachment files as a read-only recovery copy. Choose how to start again."
    case (_, .resolvingEncryptedDataReset):
      "Snip Snap is checking iCloud before it starts or joins the new synced collection."
    case (_, .removalPending):
      "Snip Snap started a fresh empty synced collection, but it could not remove all old iCloud data yet. It will retry the next time it syncs. Your local recovery copy remains."
    case (_, .deleted):
      "Synced content was removed. This device kept a local recovery copy. A small control record remains in iCloud so an old device cannot restore the deleted collection."
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

  public func recordEncryptedDataReset() {
    mode = .iCloudSync
    state = .encryptedDataReset
  }

  public func resolveEncryptedDataReset(_ choice: EncryptedDataResetChoice) async {
    guard state == .encryptedDataReset, let encryptedDataResetAction else { return }
    state = .resolvingEncryptedDataReset
    do {
      let outcome = try await encryptedDataResetAction(choice)
      try await encryptedDataResetCompletionAction?()
      if outcome == .requiresChoice {
        mode = .iCloudSync
        state = .encryptedDataReset
        return
      }
      mode = choice == .keepSyncOff ? .localOnly : .iCloudSync
      state = .ready
    } catch {
      state = .failed(error.localizedDescription)
    }
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
