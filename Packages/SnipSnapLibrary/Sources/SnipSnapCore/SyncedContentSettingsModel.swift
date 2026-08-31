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
    case (_, .failed): String(localized: LocalizedStringResource.syncNeedsAttention)
    case (.localOnly, .enabling): String(localized: LocalizedStringResource.settingUpICloudSync)
    case (.localOnly, _): String(localized: LocalizedStringResource.localOnly)
    case (_, .ready): String(localized: LocalizedStringResource.iCloudSyncOn)
    case (_, .enabling): String(localized: LocalizedStringResource.settingUpICloudSync)
    case (_, .disabling): String(localized: LocalizedStringResource.turningOffICloudSync)
    case (_, .deleting): String(localized: LocalizedStringResource.deletingSyncedContent)
    case (_, .encryptedDataReset): String(localized: LocalizedStringResource.iCloudEncryptedDataWasReset)
    case (_, .resolvingEncryptedDataReset): String(localized: LocalizedStringResource.startingANewSyncedCollection)
    case (_, .removalPending): String(localized: LocalizedStringResource.oldSyncedContentRemovalPending)
    case (_, .deleted): String(localized: LocalizedStringResource.syncedContentDeleted)
    }
  }

  public var detail: String {
    switch (mode, state) {
    case (.localOnly, .failed(let message)):
      String(localized: LocalizedStringResource.snipSnapCouldNotFinishSettingUpICloudSyncYourLocalLibraryRemainsAvailable(message))
    case (_, .failed(let message)):
      String(localized: LocalizedStringResource.snipSnapCouldNotFinishTheICloudActionCheckTheCurrentSyncStatusBeforeYouRetry(message))
    case (.localOnly, .enabling):
      String(localized: LocalizedStringResource.snipSnapIsFetchingICloudDataAndPreparingASafeMergedCopy)
    case (.iCloudSync, .enabling):
      String(localized: LocalizedStringResource.snipSnapIsFinishingICloudSyncSetup)
    case (.iCloudSync, .disabling):
      String(localized: LocalizedStringResource.snipSnapIsMakingALocalCopyOfYourSyncedLibraryYourICloudCopyWillStayInPlace)
    case (.localOnly, _):
      String(localized: LocalizedStringResource.snipSnapDoesNotSendLocalOnlyDataToCloudKit)
    case (_, .ready):
      String(localized: LocalizedStringResource.savedSnipsAndAttachmentsSyncThroughYourPrivateICloudDatabaseSnipSnapsMaintainersCannotInspectPrivateRecordsInCloudKitConsoleAppleEncryptsSyncedDataInTransitAndAtRestUserFieldsUseEncryptedValuesAndFilesUseCkassetDataThoseUserFieldsAndAttachmentsAreEndToEndEncryptedOnlyWhenAdvancedDataProtectionIsOn)
    case (_, .deleting):
      String(localized: LocalizedStringResource.snipSnapIsStartingAFreshEmptySyncedCollectionAndRemovingTheOldDataZones)
    case (_, .encryptedDataReset):
      String(localized: LocalizedStringResource.snipSnapStoppedSyncAndKeptThisDevicesSnipsAndAvailableAttachmentFilesAsAReadOnlyRecoveryCopyChooseHowToStartAgain)
    case (_, .resolvingEncryptedDataReset):
      String(localized: LocalizedStringResource.snipSnapIsCheckingICloudBeforeItStartsOrJoinsTheNewSyncedCollection)
    case (_, .removalPending):
      String(localized: LocalizedStringResource.snipSnapStartedAFreshEmptySyncedCollectionButItCouldNotRemoveAllOldICloudDataYetItWillRetryTheNextTimeItSyncsYourLocalRecoveryCopyRemains)
    case (_, .deleted):
      String(localized: LocalizedStringResource.syncedContentWasRemovedThisDeviceKeptALocalRecoveryCopyASmallControlRecordRemainsInICloudSoAnOldDeviceCannotRestoreTheDeletedCollection)
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
