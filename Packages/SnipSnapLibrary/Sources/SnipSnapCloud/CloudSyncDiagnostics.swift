import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

enum CloudSyncDiagnostics {
  enum AttachmentStage {
    case cloudKitRequest
    case cloudKitRecord
    case cloudKitAssetURL
    case assetCopy
    case remoteFetch
    case receiptValidation
    case cacheInstall

    var operation: StaticString {
      switch self {
      case .cloudKitRequest: "attachment.cloudkit_request"
      case .cloudKitRecord: "attachment.cloudkit_record"
      case .cloudKitAssetURL: "attachment.cloudkit_asset_url"
      case .assetCopy: "attachment.asset_copy"
      case .remoteFetch: "attachment.remote_fetch"
      case .receiptValidation: "attachment.receipt_validation"
      case .cacheInstall: "attachment.cache_install"
      }
    }
  }

  static func record(_ error: Error, operation: String) {
    let retry = ((error as? CKError)?.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
    AppDiagnostics.shared.record(
      .failure(
        operation: diagnosticOperation(operation),
        errorCode: attachmentErrorCode(error),
        visibility: .background,
        retryAfterSeconds: retry
      )
    )
  }

  static func recordRetry(
    _ error: Error,
    operation: String,
    selectedDelay: Duration?,
    nextAttemptIn: Duration?
  ) {
    AppDiagnostics.shared.record(
      .failure(
        operation: diagnosticOperation(operation),
        errorCode: attachmentErrorCode(error),
        visibility: .background,
        retryAfterSeconds: seconds(selectedDelay),
        nextAttemptSeconds: seconds(nextAttemptIn)
      )
    )
  }

  static func attachmentStarted(_ stage: AttachmentStage) {
    AppDiagnostics.shared.record(.started(operation: stage.operation))
  }

  static func attachmentSucceeded(_ stage: AttachmentStage, byteCount: Int64? = nil) {
    AppDiagnostics.shared.record(.succeeded(operation: stage.operation, byteCount: byteCount))
  }

  static func attachmentMissing(_ stage: AttachmentStage) {
    AppDiagnostics.shared.record(.missing(operation: stage.operation))
  }

  static func attachmentFailed(_ stage: AttachmentStage, error: Error) {
    AppDiagnostics.shared.record(
      .failure(
        operation: stage.operation,
        errorCode: attachmentErrorCode(error),
        visibility: .background
      )
    )
  }

  static func attachmentErrorCode(_ error: Error) -> String {
    if let error = error as? CKError {
      return "cloudkit.\(error.errorCode)"
    }
    return diagnosticErrorCode(error)
  }

  private static func seconds(_ duration: Duration?) -> Double {
    guard let components = duration?.components else { return 0 }
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

  private static func diagnosticOperation(_ operation: String) -> StaticString {
    switch operation {
    case "record fetch": "cloudkit.record_fetch"
    case "record send": "cloudkit.record_send"
    case "control fetch": "cloudkit.control_fetch"
    case "control create zones": "cloudkit.control_create_zones"
    case "control save": "cloudkit.control_save"
    case "control delete zones": "cloudkit.control_delete_zones"
    case "clipboard fetch": "cloudkit.clipboard_fetch"
    case "clipboard save": "cloudkit.clipboard_save"
    case "clipboard delete": "cloudkit.clipboard_delete"
    default: "cloudkit.request"
    }
  }

}

/// Creates a small, privacy-safe attachment diagnostic file suitable for TestFlight feedback.
/// The file contains only stable stage, outcome, error, byte-count, version, and timestamp fields.
public enum CloudSyncDiagnosticsExport {
  public static func makeShareableFile() throws -> URL {
    try AppDiagnosticsExport.makeShareableFile()
  }

  public static func clear() throws {
    try AppDiagnosticsExport.clear()
  }
}
