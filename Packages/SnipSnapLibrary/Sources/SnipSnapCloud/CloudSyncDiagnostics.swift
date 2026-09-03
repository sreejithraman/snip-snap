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
}
