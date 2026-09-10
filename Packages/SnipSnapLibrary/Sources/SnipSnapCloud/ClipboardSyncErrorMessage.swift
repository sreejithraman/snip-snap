import Foundation
import SnipSnapCore

public enum ClipboardSyncErrorMessage {
  public static func sync(for error: any Error) -> String {
    String(
      localized: "Snip Snap couldn’t sync clipboard history. \(reason(for: error))",
      bundle: .main
    )
  }

  public static func accountReset(for error: any Error) -> String {
    String(
      localized: "Snip Snap couldn’t update clipboard history for this iCloud account. \(reason(for: error))",
      bundle: .main
    )
  }

  public static func deleteSyncedHistory(for error: any Error) -> String {
    String(
      localized: "Snip Snap couldn’t delete synced clipboard history. \(reason(for: error))",
      bundle: .main
    )
  }

  private static func reason(for error: any Error) -> String {
    if let clipboardError = error as? ClipboardCloudError {
      return switch clipboardError {
      case .conflict:
        String(localized: "Clipboard history changed on another device. Try again.", bundle: .main)
      case .accountChanged:
        String(localized: "Clipboard history belongs to a different iCloud account or library.", bundle: .main)
      case .unavailable:
        String(localized: "Clipboard sync is unavailable. Try again later.", bundle: .main)
      case .invalidPayload:
        String(localized: "Snip Snap can’t read a clipboard item.", bundle: .main)
      case .busy:
        String(localized: "Clipboard history is already syncing.", bundle: .main)
      case .payloadTooLarge:
        String(localized: "Snip Snap can’t sync a clipboard entry larger than 32 MB.", bundle: .main)
      }
    }

    return switch SnipSnapCloudSyncIssueMapper.issue(for: error) {
    case .waitingForConnection:
      String(localized: "Check your connection, then try again.", bundle: .main)
    case .iCloudUnavailable:
      String(localized: "iCloud is unavailable right now. Try again.", bundle: .main)
    case .retryingSoon:
      String(localized: "iCloud paused the request. Try again shortly.", bundle: .main)
    case .checkingAccount:
      String(localized: "Snip Snap can’t check your iCloud account. Try again.", bundle: .main)
    case .signInRequired:
      String(localized: "Sign in to iCloud, then try again.", bundle: .main)
    case .accountRestricted:
      String(localized: "iCloud access is restricted on this device.", bundle: .main)
    case .accountTemporarilyUnavailable:
      String(localized: "Your iCloud account is unavailable right now. Try again.", bundle: .main)
    case .iCloudStorageFull:
      String(localized: "iCloud storage is full. Free up space, then try again.", bundle: .main)
    case .updateRequired:
      String(localized: "Update Snip Snap, then try again.", bundle: .main)
    case .accessDenied:
      String(localized: "Snip Snap can’t access iCloud. Check your device and iCloud restrictions.", bundle: .main)
    case .someChangesPending:
      String(localized: "Some iCloud changes are pending. Try again.", bundle: .main)
    case .attachmentMissing:
      String(localized: "Snip Snap can’t read a clipboard file on this device.", bundle: .main)
    case .attachmentUnavailable:
      String(localized: "iCloud can’t provide a clipboard file right now.", bundle: .main)
    case .attachmentStorageUnavailable:
      String(localized: "Snip Snap can’t save a clipboard file on this device.", bundle: .main)
    case .setupBlocked, .iCloudDataReset, .iCloudAccountChanged, .appDataIssue:
      String(localized: "Try again. If this keeps happening, check for an update or contact support.", bundle: .main)
    }
  }
}
