import CloudKit
import Foundation
import OSLog

enum CloudSyncDiagnostics {
  private static let logger = Logger(subsystem: "SnipSnap", category: "iCloudSync")

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

  private static func seconds(_ duration: Duration?) -> Double {
    guard let components = duration?.components else { return 0 }
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

}
