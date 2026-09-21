import CloudKit
import Foundation
import OSLog
import SnipSnapPersistence

enum CloudSyncDiagnostics {
  private static let logger = Logger(subsystem: "SnipSnap", category: "iCloudSync")
  private static let eventStore = CloudDiagnosticEventStore.live

  enum AttachmentStage: String {
    case cloudKitRequest = "cloudkit_request"
    case cloudKitRecord = "cloudkit_record"
    case cloudKitAssetURL = "cloudkit_asset_url"
    case assetCopy = "asset_copy"
    case remoteFetch = "remote_fetch"
    case receiptValidation = "receipt_validation"
    case cacheInstall = "cache_install"
  }

  static func record(_ error: Error, operation: String) {
    guard let error = error as? CKError else {
      logger.error("\(operation, privacy: .public): non-CloudKit failure")
      return
    }
    let retry = (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue ?? 0
    logger.error(
      "\(operation, privacy: .public): CKError \(error.errorCode, privacy: .public), retryAfter \(retry, privacy: .public)"
    )
  }

  static func recordRetry(
    _ error: Error,
    operation: String,
    selectedDelay: Duration?,
    nextAttemptIn: Duration?
  ) {
    guard let error = error as? CKError else {
      record(error, operation: operation)
      return
    }
    let delay = seconds(selectedDelay)
    let wait = seconds(nextAttemptIn)
    let nextPermittedAt = Date().addingTimeInterval(wait).ISO8601Format()
    logger.error(
      "\(operation, privacy: .public): CKError \(error.errorCode, privacy: .public), selectedDelay \(delay, privacy: .public), nextAttemptIn \(wait, privacy: .public), nextPermittedAt \(nextPermittedAt, privacy: .public)"
    )
  }

  static func attachmentStarted(_ stage: AttachmentStage) {
    let message = attachmentEvent(stage: stage, outcome: "started")
    logger.info(
      "\(message, privacy: .public)"
    )
    eventStore.append(message)
  }

  static func attachmentSucceeded(_ stage: AttachmentStage, byteCount: Int64? = nil) {
    let message = attachmentEvent(stage: stage, outcome: "succeeded", byteCount: byteCount)
    logger.info("\(message, privacy: .public)")
    eventStore.append(message)
  }

  static func attachmentMissing(_ stage: AttachmentStage) {
    let message = attachmentEvent(stage: stage, outcome: "missing")
    logger.error("\(message, privacy: .public)")
    eventStore.append(message)
  }

  static func attachmentFailed(_ stage: AttachmentStage, error: Error) {
    let code = attachmentErrorCode(error)
    let message = attachmentEvent(stage: stage, outcome: "failed", errorCode: code)
    logger.error("\(message, privacy: .public)")
    eventStore.append(message)
  }

  static func attachmentEvent(
    stage: AttachmentStage,
    outcome: String,
    errorCode: String? = nil,
    byteCount: Int64? = nil
  ) -> String {
    var fields = [
      "attachment_download",
      "stage=\(stage.rawValue)",
      "outcome=\(outcome)",
    ]
    if let errorCode { fields.append("error=\(errorCode)") }
    if let byteCount { fields.append("bytes=\(byteCount)") }
    return fields.joined(separator: " ")
  }

  static func attachmentErrorCode(_ error: Error) -> String {
    if let error = error as? CKError {
      return "cloudkit.\(error.errorCode)"
    }
    if let error = error as? CloudAttachmentStorageError {
      switch error {
      case .invalidPath: return "storage.invalidPath"
      case .invalidMetadata: return "storage.invalidMetadata"
      case .staleTransition: return "storage.staleTransition"
      case .missingPublication: return "storage.missingPublication"
      case .hashMismatch: return "storage.hashMismatch"
      case .sizeMismatch: return "storage.sizeMismatch"
      case .missingPayload: return "storage.missingPayload"
      }
    }
    if let error = error as? CloudRecordError {
      switch error {
      case .invalidShadow: return "record.invalidShadow"
      case .mismatchedShadow: return "record.mismatchedShadow"
      case .unsupportedValue: return "record.unsupportedValue"
      case .missingField: return "record.missingField"
      case .invalidField: return "record.invalidField"
      case .projectedSnapshot: return "record.projectedSnapshot"
      case .wrongRecordType: return "record.wrongRecordType"
      case .invalidAssetDestination: return "record.invalidAssetDestination"
      case .missingAsset: return "record.missingAsset"
      }
    }
    if let error = error as? CloudTransportError {
      switch error {
      case .stateNamespaceMismatch: return "transport.stateNamespaceMismatch"
      case .invalidEngineState: return "transport.invalidEngineState"
      case .invalidRecord: return "transport.invalidRecord"
      case .fetchFailed: return "transport.fetchFailed"
      case .sendFailed: return "transport.sendFailed"
      case .wrongBatchConfirmation: return "transport.wrongBatchConfirmation"
      case .notStarted: return "transport.notStarted"
      case .syncAlreadyRunning: return "transport.syncAlreadyRunning"
      }
    }
    if let error = error as? CocoaError {
      return "cocoa.\(error.errorCode)"
    }
    return "other.\(String(describing: type(of: error)))"
  }

  private static func seconds(_ duration: Duration?) -> Double {
    guard let components = duration?.components else { return 0 }
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

}

/// Creates a small, privacy-safe attachment diagnostic file suitable for TestFlight feedback.
/// The file contains only stable stage, outcome, error, byte-count, version, and timestamp fields.
public enum CloudSyncDiagnosticsExport {
  public static func makeShareableFile() throws -> URL {
    try CloudDiagnosticEventStore.live.makeShareableFile()
  }

  public static func clear() throws {
    try CloudDiagnosticEventStore.live.clear()
  }
}
