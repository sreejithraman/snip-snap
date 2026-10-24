import Foundation
import SnipSnapCore

/// Add request identity without discarding the error's machine-readable cause.
struct SnipCLIRequestFailure: Error, LocalizedError {
  let requestID: UUID
  let cause: any Error

  var errorDescription: String? {
    let message = (cause as? SnipSnapCLIError)?.description ?? cause.localizedDescription
    return "Request \(requestID.uuidString): \(message) Check 'snipsnap status \(requestID.uuidString)' before retrying if the outcome is unclear."
  }
}

struct SnipCLIErrorReport: Encodable {
  let status = "failed"
  let code: String
  let message: String
  let requestID: UUID?

  init(error: any Error, requestID: UUID? = nil) {
    let failure = error as? SnipCLIRequestFailure
    let cause = failure?.cause ?? error
    message = (error as? SnipSnapCLIError)?.description ?? error.localizedDescription
    var causeRequestID: UUID?
    switch cause {
    case AppDiagnosticAccessError.busy:
      code = "diagnostics_busy"
    case SnipSnapCLIError.usage, SnipSnapCLIError.missingContent,
         SnipSnapCLIError.invalidRequestID:
      code = "invalid_arguments"
    case SnipSnapCLIError.appUnavailable:
      code = "app_unavailable"
    case SnipSnapCLIError.commandInProgress(let id):
      code = "in_progress"; causeRequestID = id
    case SnipSnapCLIError.outcomeUnknown(let id):
      code = "outcome_unknown"; causeRequestID = id
    case SnipSnapCLIError.requestNotFound:
      code = "request_not_found"
    default:
      code = "command_failed"
    }
    self.requestID = failure?.requestID ?? causeRequestID ?? requestID
  }

  func data() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self) + Data("\n".utf8)
  }
}
