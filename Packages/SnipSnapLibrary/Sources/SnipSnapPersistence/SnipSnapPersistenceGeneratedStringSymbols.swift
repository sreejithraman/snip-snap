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
     Localized string for key “%@ Snip Snap also could not open the JSON store, so it cannot save new snips.” in table “Localizable.xcstrings”.
     */
    static func snipSnapAlsoCouldNotOpenTheJsonStoreSoItCannotSaveNewSnips(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("%@ Snip Snap also could not open the JSON store, so it cannot save new snips.", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “A Local store exists without a valid migration marker. Snip Snap left it in place.” in table “Localizable.xcstrings”.
     */
    static var aLocalStoreExistsWithoutAValidMigrationMarkerSnipSnapLeftItInPlace: LocalizedStringResource {
        LocalizedStringResource("A Local store exists without a valid migration marker. Snip Snap left it in place.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “An attachment did not match its copied file: %@.” in table “Localizable.xcstrings”.
     */
    static func anAttachmentDidNotMatchItsCopiedFile(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("An attachment did not match its copied file: %@.", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap could not create its local storage folder, so it cannot save new snips. %@” in table “Localizable.xcstrings”.
     */
    static func snipSnapCouldNotCreateItsLocalStorageFolderSoItCannotSaveNewSnips(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("Snip Snap could not create its local storage folder, so it cannot save new snips. %@", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap could not finish its storage upgrade. It kept the JSON store active. %@” in table “Localizable.xcstrings”.
     */
    static func snipSnapCouldNotFinishItsStorageUpgradeItKeptTheJsonStoreActive(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("Snip Snap could not finish its storage upgrade. It kept the JSON store active. %@", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap could not keep the shared files.” in table “Localizable.xcstrings”.
     */
    static var snipSnapCouldNotKeepTheSharedFiles: LocalizedStringResource {
        LocalizedStringResource("Snip Snap could not keep the shared files.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap could not open its SwiftData store. It left the Local and JSON stores unchanged, so it cannot save new snips.” in table “Localizable.xcstrings”.
     */
    static var snipSnapCouldNotOpenItsSwiftDataStoreItLeftTheLocalAndJsonStoresUnchangedSoItCannotSaveNewSnips: LocalizedStringResource {
        LocalizedStringResource("Snip Snap could not open its SwiftData store. It left the Local and JSON stores unchanged, so it cannot save new snips.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap could not open its migrated SwiftData store and could not safely move Local back to staging. It left Local and JSON in place and will not save new snips. %@” in table “Localizable.xcstrings”.
     */
    static func snipSnapCouldNotOpenItsMigratedSwiftDataStoreAndCouldNotSafelyMoveLocalBackToStagingItLeftLocalAndJsonInPlaceAndWillNotSaveNewSnips(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("Snip Snap could not open its migrated SwiftData store and could not safely move Local back to staging. It left Local and JSON in place and will not save new snips. %@", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Snip Snap kept the unreadable JSON as %@ and started a new JSON store. %@” in table “Localizable.xcstrings”.
     */
    static func snipSnapKeptTheUnreadableJsonAsAndStartedANewJsonStore(_ arg1: String, _ arg2: String) -> LocalizedStringResource {
        LocalizedStringResource("Snip Snap kept the unreadable JSON as %@ and started a new JSON store. %@", defaultValue: "\(arg1)\(arg2)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “The JSON store changed while Snip Snap was copying it.” in table “Localizable.xcstrings”.
     */
    static var theJsonStoreChangedWhileSnipSnapWasCopyingIt: LocalizedStringResource {
        LocalizedStringResource("The JSON store changed while Snip Snap was copying it.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “The JSON store refers to a missing attachment: %@.” in table “Localizable.xcstrings”.
     */
    static func theJsonStoreRefersToAMissingAttachment(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("The JSON store refers to a missing attachment: %@.", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “The Local store migration marker is invalid. Snip Snap left the store in place.” in table “Localizable.xcstrings”.
     */
    static var theLocalStoreMigrationMarkerIsInvalidSnipSnapLeftTheStoreInPlace: LocalizedStringResource {
        LocalizedStringResource("The Local store migration marker is invalid. Snip Snap left the store in place.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “The SwiftData check did not match the JSON store.” in table “Localizable.xcstrings”.
     */
    static var theSwiftDataCheckDidNotMatchTheJsonStore: LocalizedStringResource {
        LocalizedStringResource("The SwiftData check did not match the JSON store.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “This build does not have access to the shared Snip Snap container.” in table “Localizable.xcstrings”.
     */
    static var thisBuildDoesNotHaveAccessToTheSharedSnipSnapContainer: LocalizedStringResource {
        LocalizedStringResource("This build does not have access to the shared Snip Snap container.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “attachment.genericName” in table “Localizable.xcstrings”.
     */
    static var attachmentGenericName: LocalizedStringResource {
        LocalizedStringResource("attachment.genericName", table: "Localizable", bundle: resourceBundleDescription)
    }
}
#endif
