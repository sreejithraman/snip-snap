import Foundation
import SnipSnapCore

public enum ClipboardSyncErrorMessage {
  public static func sync(for error: any Error) -> String {
    String(
      localized: "Couldn’t sync clipboard history. \(reason(for: error))",
      bundle: .main
    )
  }

  public static func accountReset(for error: any Error) -> String {
    String(
      localized: "Couldn’t update clipboard history for this account. \(reason(for: error))",
      bundle: .main
    )
  }

  public static func deleteSyncedHistory(for error: any Error) -> String {
    String(
      localized: "Couldn’t delete synced clipboard history. \(reason(for: error))",
      bundle: .main
    )
  }

  private static func reason(for error: any Error) -> String {
    if let clipboardError = error as? ClipboardCloudError {
      return switch clipboardError {
      case .conflict:
        String(localized: "Clipboard history changed on another device. Try again.", bundle: .main)
      case .accountChanged:
        String(localized: "Clipboard history belongs to another iCloud account or library.", bundle: .main)
      case .unavailable:
        String(localized: "Clipboard sync is unavailable. Try again later.", bundle: .main)
      case .invalidPayload:
        String(localized: "Can’t read clipboard data. Try again or contact support.", bundle: .main)
      case .busy:
        String(localized: "Wait for sync to finish.", bundle: .main)
      case .payloadTooLarge:
        String(localized: "Clipboard entries over 32 MB can’t sync. Contact support for help.", bundle: .main)
      }
    }

    return switch SnipSnapCloudSyncIssueMapper.issue(for: error) {
    case .waitingForConnection:
      String(localized: "Check your connection, then try again.", bundle: .main)
    case .iCloudUnavailable:
      String(localized: "iCloud is unavailable. Try again later.", bundle: .main)
    case .retryingSoon:
      String(localized: "iCloud needs more time. Try again later.", bundle: .main)
    case .checkingAccount:
      String(localized: "Can’t check your iCloud account. Try again later.", bundle: .main)
    case .signInRequired:
      String(localized: "Sign in to iCloud, then try again.", bundle: .main)
    case .accountRestricted:
      String(localized: "iCloud access is restricted on this device.", bundle: .main)
    case .accountTemporarilyUnavailable:
      String(localized: "Your iCloud account is unavailable. Try again later.", bundle: .main)
    case .iCloudStorageFull:
      String(localized: "iCloud storage is full. Free up space, then try again.", bundle: .main)
    case .updateRequired:
      String(localized: "Update Snip Snap, then try again.", bundle: .main)
    case .accessDenied:
      String(localized: "Check your device’s iCloud permissions for Snip Snap.", bundle: .main)
    case .someChangesPending:
      String(localized: "Some changes haven’t synced. Try again.", bundle: .main)
    case .attachmentMissing:
      String(localized: "Can’t read a clipboard file. Try again or contact support.", bundle: .main)
    case .attachmentUnavailable:
      String(localized: "A clipboard file isn’t available from iCloud. Try again later.", bundle: .main)
    case .attachmentStorageUnavailable:
      String(localized: "Couldn’t save a clipboard file. Try again or contact support.", bundle: .main)
    case .setupBlocked, .iCloudDataReset, .iCloudAccountChanged, .appDataIssue:
      String(localized: "Try again. If it still fails, update Snip Snap or contact support.", bundle: .main)
    }
  }
}
