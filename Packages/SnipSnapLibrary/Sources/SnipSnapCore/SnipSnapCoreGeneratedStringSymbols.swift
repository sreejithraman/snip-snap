#if !SNIP_SNAP_SWIFTBUILD && (!Xcode || DEBUG)

// 
// GeneratedStringSymbols_Localizable.swift
// Auto-Generated symbols for localized strings defined in “Localizable.xcstrings”.
// 

import Foundation

#if SWIFT_PACKAGE
private nonisolated let resourceBundle = Foundation.Bundle.module
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
private nonisolated let resourceBundleDescription = LocalizedStringResource.BundleDescription.atURL(resourceBundle.bundleURL)
#else

private class ResourceBundleClass {}
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
private nonisolated let resourceBundleDescription = LocalizedStringResource.BundleDescription.forClass(ResourceBundleClass.self)
#endif

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
nonisolated extension LocalizedStringResource {
    /**
     Localized string for key “A list with that name already exists.” in table “Localizable.xcstrings”.
     */
    static var aListWithThatNameAlreadyExists: LocalizedStringResource {
        LocalizedStringResource("A list with that name already exists.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Deleting Synced Content…” in table “Localizable.xcstrings”.
     */
    static var deletingSyncedContent: LocalizedStringResource {
        LocalizedStringResource("Deleting Synced Content…", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Local Only” in table “Localizable.xcstrings”.
     */
    static var localOnly: LocalizedStringResource {
        LocalizedStringResource("Local Only", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Old Synced Content Removal Pending” in table “Localizable.xcstrings”.
     */
    static var oldSyncedContentRemovalPending: LocalizedStringResource {
        LocalizedStringResource("Old Synced Content Removal Pending", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Saved snips and attachments sync through your private iCloud database. Snip Snap’s maintainers cannot inspect private records in CloudKit Console. Apple encrypts synced data in transit and at rest; user fields use encrypted values and files use CKAsset data. Those user fields and attachments are end-to-end encrypted only when Advanced Data Protection is on.” in table “Localizable.xcstrings”.
     */
    static var savedSnipsAndAttachmentsSyncThroughYourPrivateICloudDatabaseSnipSnapsMaintainersCannotInspectPrivateRecordsInCloudKitConsoleAppleEncryptsSyncedDataInTransitAndAtRestUserFieldsUseEncryptedValuesAndFilesUseCkassetDataThoseUserFieldsAndAttachmentsAreEndToEndEncryptedOnlyWhenAdvancedDataProtectionIsOn: LocalizedStringResource {
        LocalizedStringResource("Saved snips and attachments sync through your private iCloud database. Snip Snap’s maintainers cannot inspect private records in CloudKit Console. Apple encrypts synced data in transit and at rest; user fields use encrypted values and files use CKAsset data. Those user fields and attachments are end-to-end encrypted only when Advanced Data Protection is on.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Select at least two snips to merge.” in table “Localizable.xcstrings”.
     */
    static var selectAtLeastTwoSnipsToMerge: LocalizedStringResource {
        LocalizedStringResource("Select at least two snips to merge.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Setting Up iCloud Sync…” in table “Localizable.xcstrings”.
     */
    static var settingUpICloudSync: LocalizedStringResource {
        LocalizedStringResource("Setting Up iCloud Sync…", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap cannot save changes until its snip store is available.” in table “Localizable.xcstrings”.
     */
    static var snipSnapCannotSaveChangesUntilItsSnipStoreIsAvailable: LocalizedStringResource {
        LocalizedStringResource("Snip Snap cannot save changes until its snip store is available.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap could not copy one of the files.” in table “Localizable.xcstrings”.
     */
    static var snipSnapCouldNotCopyOneOfTheFiles: LocalizedStringResource {
        LocalizedStringResource("Snip Snap could not copy one of the files.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap could not finish setting up iCloud Sync. Your local library remains available. %@” in table “Localizable.xcstrings”.
     */
    static func snipSnapCouldNotFinishSettingUpICloudSyncYourLocalLibraryRemainsAvailable(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("Snip Snap could not finish setting up iCloud Sync. Your local library remains available. %@", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap could not finish the iCloud action. Check the current sync status before you retry. %@” in table “Localizable.xcstrings”.
     */
    static func snipSnapCouldNotFinishTheICloudActionCheckTheCurrentSyncStatusBeforeYouRetry(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("Snip Snap could not finish the iCloud action. Check the current sync status before you retry. %@", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap could not read its saved snips.” in table “Localizable.xcstrings”.
     */
    static var snipSnapCouldNotReadItsSavedSnips: LocalizedStringResource {
        LocalizedStringResource("Snip Snap could not read its saved snips.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap does not send local-only data to CloudKit.” in table “Localizable.xcstrings”.
     */
    static var snipSnapDoesNotSendLocalOnlyDataToCloudKit: LocalizedStringResource {
        LocalizedStringResource("Snip Snap does not send local-only data to CloudKit.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap found records it could not copy safely.” in table “Localizable.xcstrings”.
     */
    static var snipSnapFoundRecordsItCouldNotCopySafely: LocalizedStringResource {
        LocalizedStringResource("Snip Snap found records it could not copy safely.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap is checking iCloud before it starts or joins the new synced collection.” in table “Localizable.xcstrings”.
     */
    static var snipSnapIsCheckingICloudBeforeItStartsOrJoinsTheNewSyncedCollection: LocalizedStringResource {
        LocalizedStringResource("Snip Snap is checking iCloud before it starts or joins the new synced collection.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap is fetching iCloud data and preparing a safe merged copy.” in table “Localizable.xcstrings”.
     */
    static var snipSnapIsFetchingICloudDataAndPreparingASafeMergedCopy: LocalizedStringResource {
        LocalizedStringResource("Snip Snap is fetching iCloud data and preparing a safe merged copy.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap is finishing iCloud Sync setup.” in table “Localizable.xcstrings”.
     */
    static var snipSnapIsFinishingICloudSyncSetup: LocalizedStringResource {
        LocalizedStringResource("Snip Snap is finishing iCloud Sync setup.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap is making a local copy of your synced library. Your iCloud copy will stay in place.” in table “Localizable.xcstrings”.
     */
    static var snipSnapIsMakingALocalCopyOfYourSyncedLibraryYourICloudCopyWillStayInPlace: LocalizedStringResource {
        LocalizedStringResource("Snip Snap is making a local copy of your synced library. Your iCloud copy will stay in place.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap is starting a fresh empty synced collection and removing the old data zones.” in table “Localizable.xcstrings”.
     */
    static var snipSnapIsStartingAFreshEmptySyncedCollectionAndRemovingTheOldDataZones: LocalizedStringResource {
        LocalizedStringResource("Snip Snap is starting a fresh empty synced collection and removing the old data zones.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap started a fresh empty synced collection, but it could not remove all old iCloud data yet. It will retry the next time it syncs. Your local recovery copy remains.” in table “Localizable.xcstrings”.
     */
    static var snipSnapStartedAFreshEmptySyncedCollectionButItCouldNotRemoveAllOldICloudDataYetItWillRetryTheNextTimeItSyncsYourLocalRecoveryCopyRemains: LocalizedStringResource {
        LocalizedStringResource("Snip Snap started a fresh empty synced collection, but it could not remove all old iCloud data yet. It will retry the next time it syncs. Your local recovery copy remains.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap stopped sync and kept this device’s snips and available attachment files as a read-only recovery copy. Choose how to start again.” in table “Localizable.xcstrings”.
     */
    static var snipSnapStoppedSyncAndKeptThisDevicesSnipsAndAvailableAttachmentFilesAsAReadOnlyRecoveryCopyChooseHowToStartAgain: LocalizedStringResource {
        LocalizedStringResource("Snip Snap stopped sync and kept this device’s snips and available attachment files as a read-only recovery copy. Choose how to start again.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Starting a New Synced Collection…” in table “Localizable.xcstrings”.
     */
    static var startingANewSyncedCollection: LocalizedStringResource {
        LocalizedStringResource("Starting a New Synced Collection…", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Sync Needs Attention” in table “Localizable.xcstrings”.
     */
    static var syncNeedsAttention: LocalizedStringResource {
        LocalizedStringResource("Sync Needs Attention", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Synced Content Deleted” in table “Localizable.xcstrings”.
     */
    static var syncedContentDeleted: LocalizedStringResource {
        LocalizedStringResource("Synced Content Deleted", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Synced content was removed. This device kept a local recovery copy. A small control record remains in iCloud so an old device cannot restore the deleted collection.” in table “Localizable.xcstrings”.
     */
    static var syncedContentWasRemovedThisDeviceKeptALocalRecoveryCopyASmallControlRecordRemainsInICloudSoAnOldDeviceCannotRestoreTheDeletedCollection: LocalizedStringResource {
        LocalizedStringResource("Synced content was removed. This device kept a local recovery copy. A small control record remains in iCloud so an old device cannot restore the deleted collection.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “That action cannot be undone because the same fields changed on another device.” in table “Localizable.xcstrings”.
     */
    static var thatActionCannotBeUndoneBecauseTheSameFieldsChangedOnAnotherDevice: LocalizedStringResource {
        LocalizedStringResource("That action cannot be undone because the same fields changed on another device.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “That change cannot run with other changes.” in table “Localizable.xcstrings”.
     */
    static var thatChangeCannotRunWithOtherChanges: LocalizedStringResource {
        LocalizedStringResource("That change cannot run with other changes.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “That choice does not apply to this recovered edit.” in table “Localizable.xcstrings”.
     */
    static var thatChoiceDoesNotApplyToThisRecoveredEdit: LocalizedStringResource {
        LocalizedStringResource("That choice does not apply to this recovered edit.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “That list is not available.” in table “Localizable.xcstrings”.
     */
    static var thatListIsNotAvailable: LocalizedStringResource {
        LocalizedStringResource("That list is not available.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “That recovered edit changed. Refresh the review and try again.” in table “Localizable.xcstrings”.
     */
    static var thatRecoveredEditChangedRefreshTheReviewAndTryAgain: LocalizedStringResource {
        LocalizedStringResource("That recovered edit changed. Refresh the review and try again.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “That recovered edit is no longer available.” in table “Localizable.xcstrings”.
     */
    static var thatRecoveredEditIsNoLongerAvailable: LocalizedStringResource {
        LocalizedStringResource("That recovered edit is no longer available.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “That snip no longer exists.” in table “Localizable.xcstrings”.
     */
    static var thatSnipNoLongerExists: LocalizedStringResource {
        LocalizedStringResource("That snip no longer exists.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “The backup or saved snips changed. Review the import again.” in table “Localizable.xcstrings”.
     */
    static var theBackupOrSavedSnipsChangedReviewTheImportAgain: LocalizedStringResource {
        LocalizedStringResource("The backup or saved snips changed. Review the import again.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “There is nothing to save.” in table “Localizable.xcstrings”.
     */
    static var thereIsNothingToSave: LocalizedStringResource {
        LocalizedStringResource("There is nothing to save.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “This device is changing its storage choice. Try again when setup finishes.” in table “Localizable.xcstrings”.
     */
    static var thisDeviceIsChangingItsStorageChoiceTryAgainWhenSetupFinishes: LocalizedStringResource {
        LocalizedStringResource("This device is changing its storage choice. Try again when setup finishes.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “This is a recovery copy. Restore it to an active library before making changes.” in table “Localizable.xcstrings”.
     */
    static var thisIsARecoveryCopyRestoreItToAnActiveLibraryBeforeMakingChanges: LocalizedStringResource {
        LocalizedStringResource("This is a recovery copy. Restore it to an active library before making changes.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “This snip changed in another window. Copy your edits, reopen it, and try again.” in table “Localizable.xcstrings”.
     */
    static var thisSnipChangedInAnotherWindowCopyYourEditsReopenItAndTryAgain: LocalizedStringResource {
        LocalizedStringResource("This snip changed in another window. Copy your edits, reopen it, and try again.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “This snip store cannot change storage modes.” in table “Localizable.xcstrings”.
     */
    static var thisSnipStoreCannotChangeStorageModes: LocalizedStringResource {
        LocalizedStringResource("This snip store cannot change storage modes.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Turning Off iCloud Sync…” in table “Localizable.xcstrings”.
     */
    static var turningOffICloudSync: LocalizedStringResource {
        LocalizedStringResource("Turning Off iCloud Sync…", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “iCloud Encrypted Data Was Reset” in table “Localizable.xcstrings”.
     */
    static var iCloudEncryptedDataWasReset: LocalizedStringResource {
        LocalizedStringResource("iCloud Encrypted Data Was Reset", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “iCloud Sync On” in table “Localizable.xcstrings”.
     */
    static var iCloudSyncOn: LocalizedStringResource {
        LocalizedStringResource("iCloud Sync On", table: "Localizable", bundle: resourceBundleDescription)
    }
}
#endif
