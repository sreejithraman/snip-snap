import Foundation
import Observation

public enum SyncedContentMode: Equatable, Sendable {
  case localOnly
  case iCloudSync
}

public enum SyncedContentSettingsState: Equatable, Sendable {
  case ready
  case enabling
  case disabling
  case deleting
  case encryptedDataReset
  case resolvingEncryptedDataReset
  case removalPending
  case deleted
  case failed(String)
}

public enum SyncedContentDisableChoice: Equatable, Sendable {
  case refreshThenCopy
  case useCurrentCache
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
  public typealias DisableAction = @Sendable (SyncedContentDisableChoice) async throws -> Void
  public typealias DeleteAction = @Sendable () async throws -> SyncedContentDeleteOutcome
  public typealias DeleteCompletionAction = @MainActor @Sendable () async throws -> Void
  public typealias EncryptedDataResetAction = @Sendable (
    EncryptedDataResetChoice
  ) async throws -> EncryptedDataResetResolutionOutcome
  public typealias EncryptedDataResetCompletionAction = @MainActor @Sendable () async throws -> Void

  public private(set) var mode: SyncedContentMode
  public private(set) var state: SyncedContentSettingsState
  private let enableAction: EnableAction?
  private let disableAction: DisableAction?
  private let deleteAction: DeleteAction?
  private let encryptedDataResetAction: EncryptedDataResetAction?
  private var enableCompletionAction: DeleteCompletionAction?
  private var disableCompletionAction: DeleteCompletionAction?
  private var deleteCompletionAction: DeleteCompletionAction?
  private var encryptedDataResetCompletionAction: EncryptedDataResetCompletionAction?

  public init(
    mode: SyncedContentMode,
    initialState: SyncedContentSettingsState = .ready,
    enableAction: EnableAction? = nil,
    disableAction: DisableAction? = nil,
    deleteAction: DeleteAction? = nil,
    encryptedDataResetAction: EncryptedDataResetAction? = nil
  ) {
    self.mode = mode
    self.enableAction = enableAction
    self.disableAction = disableAction
    self.deleteAction = deleteAction
    self.encryptedDataResetAction = encryptedDataResetAction
    state = initialState
  }

  public func setEnableCompletionAction(_ action: @escaping DeleteCompletionAction) {
    enableCompletionAction = action
  }

  public func setDisableCompletionAction(_ action: @escaping DeleteCompletionAction) {
    disableCompletionAction = action
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
    case .enabling, .disabling, .deleting, .encryptedDataReset, .resolvingEncryptedDataReset,
         .removalPending, .deleted: false
    }
  }

  public var canEnable: Bool {
    guard mode == .localOnly, enableAction != nil else { return false }
    return switch state {
    case .ready, .failed: true
    case .enabling, .disabling, .deleting, .encryptedDataReset,
         .resolvingEncryptedDataReset, .removalPending, .deleted: false
    }
  }

  public var canDisable: Bool {
    guard mode == .iCloudSync, disableAction != nil else { return false }
    return switch state {
    case .ready, .failed: true
    case .enabling, .disabling, .deleting, .encryptedDataReset,
         .resolvingEncryptedDataReset, .removalPending, .deleted: false
    }
  }

  public var statusTitle: String {
    switch (mode, state) {
    case (_, .failed): String(localized: "Sync Needs Attention", bundle: .main)
    case (.localOnly, .enabling): String(localized: "Setting Up iCloud Sync…", bundle: .main)
    case (.localOnly, _): String(localized: "Local Only", bundle: .main)
    case (_, .ready): String(localized: "iCloud Sync On", bundle: .main)
    case (_, .enabling): String(localized: "Setting Up iCloud Sync…", bundle: .main)
    case (_, .disabling): String(localized: "Turning Off iCloud Sync…", bundle: .main)
    case (_, .deleting): String(localized: "Deleting Synced Content…", bundle: .main)
    case (_, .encryptedDataReset): String(localized: "iCloud Encrypted Data Was Reset", bundle: .main)
    case (_, .resolvingEncryptedDataReset): String(localized: "Starting a New Synced Collection…", bundle: .main)
    case (_, .removalPending): String(localized: "Old Synced Content Removal Pending", bundle: .main)
    case (_, .deleted): String(localized: "Synced Content Deleted", bundle: .main)
    }
  }

  public var detail: String {
    switch (mode, state) {
    case (.localOnly, .failed(let message)):
      String(localized: "Snip Snap could not finish setting up iCloud Sync. Your local library remains available. \(message)", bundle: .main)
    case (_, .failed(let message)):
      String(localized: "Snip Snap could not finish the iCloud action. Check the current sync status before you retry. \(message)", bundle: .main)
    case (.localOnly, .enabling):
      String(localized: "Snip Snap is fetching iCloud data and preparing a safe merged copy.", bundle: .main)
    case (.iCloudSync, .enabling):
      String(localized: "Snip Snap is finishing iCloud Sync setup.", bundle: .main)
    case (.iCloudSync, .disabling):
      String(localized: "Snip Snap is making a local copy of your synced library. Your iCloud copy will stay in place.", bundle: .main)
    case (.localOnly, _):
      String(localized: "Snip Snap does not send local-only data to CloudKit.", bundle: .main)
    case (_, .ready):
      String(localized: "Saved snips and attachments sync through your private iCloud database. Snip Snap’s maintainers cannot inspect private records in CloudKit Console. Apple encrypts synced data in transit and at rest; user fields use encrypted values and files use CKAsset data. Those user fields and attachments are end-to-end encrypted only when Advanced Data Protection is on.", bundle: .main)
    case (_, .deleting):
      String(localized: "Snip Snap is starting a fresh empty synced collection and removing the old data zones.", bundle: .main)
    case (_, .encryptedDataReset):
      String(localized: "Snip Snap stopped sync and kept this device’s snips and available attachment files as a read-only recovery copy. Choose how to start again.", bundle: .main)
    case (_, .resolvingEncryptedDataReset):
      String(localized: "Snip Snap is checking iCloud before it starts or joins the new synced collection.", bundle: .main)
    case (_, .removalPending):
      String(localized: "Snip Snap started a fresh empty synced collection, but it could not remove all old iCloud data yet. It will retry the next time it syncs. Your local recovery copy remains.", bundle: .main)
    case (_, .deleted):
      String(localized: "Synced content was removed. This device kept a local recovery copy. A small control record remains in iCloud so an old device cannot restore the deleted collection.", bundle: .main)
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

  public func disableICloudSync(_ choice: SyncedContentDisableChoice) async {
    guard canDisable, let disableAction else { return }
    state = .disabling
    do {
      try await disableAction(choice)
      try await disableCompletionAction?()
      mode = .localOnly
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
