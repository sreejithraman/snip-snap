#if !SNIP_SNAP_SWIFTBUILD && !Xcode

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
     Localized string for key “%lld MiB” in table “Localizable.xcstrings”.
     */
    static func miB(_ arg1: Int) -> LocalizedStringResource {
        LocalizedStringResource("%lld MiB", defaultValue: "\(arg1, specifier: "%lld")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “%lld bytes” in table “Localizable.xcstrings”.
     */
    static func bytes(_ arg1: Int) -> LocalizedStringResource {
        LocalizedStringResource("%lld bytes", defaultValue: "\(arg1, specifier: "%lld")", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Another iCloud Sync task is still running.” in table “Localizable.xcstrings”.
     */
    static var anotherICloudSyncTaskIsStillRunning: LocalizedStringResource {
        LocalizedStringResource("Another iCloud Sync task is still running.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “Choose how to handle the iCloud encrypted-data reset before turning sync on.” in table “Localizable.xcstrings”.
     */
    static var chooseHowToHandleTheICloudEncryptedDataResetBeforeTurningSyncOn: LocalizedStringResource {
        LocalizedStringResource("Choose how to handle the iCloud encrypted-data reset before turning sync on.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “The iCloud Sync collection is not valid.” in table “Localizable.xcstrings”.
     */
    static var theICloudSyncCollectionIsNotValid: LocalizedStringResource {
        LocalizedStringResource("The iCloud Sync collection is not valid.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “These attachments cannot sync. %@” in table “Localizable.xcstrings”.
     */
    static func theseAttachmentsCannotSync(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("These attachments cannot sync. %@", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     A file name followed by the reason that attachment cannot sync.
     
     Localized string for key “attachment.error.detail” in table “Localizable.xcstrings”.
     */
    static func attachmentErrorDetail(_ arg1: String, _ arg2: String) -> LocalizedStringResource {
        LocalizedStringResource("attachment.error.detail", defaultValue: "\(arg1)\(arg2)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “iCloud Sync does not have an active collection.” in table “Localizable.xcstrings”.
     */
    static var iCloudSyncDoesNotHaveAnActiveCollection: LocalizedStringResource {
        LocalizedStringResource("iCloud Sync does not have an active collection.", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “larger than Snip Snap’s %@ per-file limit” in table “Localizable.xcstrings”.
     */
    static func largerThanSnipSnapsPerFileLimit(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("larger than Snip Snap’s %@ per-file limit", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “local file is missing or changed” in table “Localizable.xcstrings”.
     */
    static var localFileIsMissingOrChanged: LocalizedStringResource {
        LocalizedStringResource("local file is missing or changed", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “part of a snip above Snip Snap’s %@ attachment limit” in table “Localizable.xcstrings”.
     */
    static func partOfASnipAboveSnipSnapsAttachmentLimit(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("part of a snip above Snip Snap’s %@ attachment limit", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “unknown” in table “Localizable.xcstrings”.
     */
    static var unknown: LocalizedStringResource {
        LocalizedStringResource("unknown", table: "Localizable", bundle: resourceBundleDescription)
    }

    /**
     Localized string for key “unsupported file type %@” in table “Localizable.xcstrings”.
     */
    static func unsupportedFileType(_ arg1: String) -> LocalizedStringResource {
        LocalizedStringResource("unsupported file type %@", defaultValue: "\(arg1)", table: "Localizable", bundle: resourceBundleDescription)
    }
}
#endif
