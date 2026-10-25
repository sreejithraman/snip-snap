import Foundation

/// The same allowlist protects new records, legacy migration, health, and exports.
enum AppDiagnosticLine {
  static func sanitize(_ line: String) -> String? {
    guard line.utf8.count <= 512 else { return nil }
    let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 4,
      fields[0].count >= 19, fields[0].count <= 35,
      fields[0].allSatisfy({ "0123456789-T:.+Z".contains($0) })
    else { return nil }

    let requiredKeys: [String]
    let optionalKeys: [String]
    switch fields[1] {
    case "diagnostic_event":
      requiredKeys = ["operation", "outcome", "visibility"]
      optionalKeys = [
        "error", "bytes", "retry_after", "next_attempt", "scope", "environment", "phase",
        "reason", "pending_uploads", "pending_downloads", "pending_events", "blocked_records",
      ]
    case "attachment_download":
      requiredKeys = ["stage", "outcome"]
      optionalKeys = ["error", "bytes"]
    default:
      return nil
    }
    guard fields.count <= 2 + requiredKeys.count + optionalKeys.count else { return nil }

    var values: [String: String] = [:]
    for field in fields.dropFirst(2) {
      let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2, !pair[1].isEmpty,
        values.updateValue(String(pair[1]), forKey: String(pair[0])) == nil
      else { return nil }
    }
    guard requiredKeys.allSatisfy({ values[$0] != nil }),
      values.keys.allSatisfy({ requiredKeys.contains($0) || optionalKeys.contains($0) }),
      values.filter({ !["bytes", "retry_after", "next_attempt"].contains($0.key) })
        .allSatisfy({ entry in
          entry.value.unicodeScalars.allSatisfy {
            CharacterSet(
              charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
            )
            .contains($0)
          }
        })
    else { return nil }

    if let bytes = values["bytes"], Int64(bytes) == nil { return nil }
    for key in ["retry_after", "next_attempt"] {
      if let value = values[key], Double(value)?.isFinite != true { return nil }
    }
    for key in ["pending_uploads", "pending_downloads", "pending_events", "blocked_records"] {
      if let raw = values[key] {
        guard let count = Int(raw), count >= 0, String(count) == raw else { return nil }
      }
    }
    if let scope = values["scope"], AppDiagnosticSyncScope(rawValue: scope) == nil { return nil }
    if let environment = values["environment"],
      AppDiagnosticSyncEnvironment(rawValue: environment) == nil
    {
      return nil
    }
    if let phase = values["phase"], AppDiagnosticSyncPhase(rawValue: phase) == nil { return nil }
    if let reason = values["reason"], AppDiagnosticSyncReason(rawValue: reason) == nil {
      return nil
    }
    guard let outcome = values["outcome"] else { return nil }
    if fields[1] == "attachment_download" {
      guard let stage = values["stage"],
        [
          "cloudkit_request", "cloudkit_record", "cloudkit_asset_url", "asset_copy",
          "remote_fetch", "receipt_validation", "cache_install",
        ].contains(stage)
          && ["started", "succeeded", "failed", "missing"].contains(outcome)
      else { return nil }
    } else {
      guard let visibility = values["visibility"],
        ["started", "succeeded", "failed", "cancelled", "missing"].contains(outcome),
        ["user", "background"].contains(visibility)
      else { return nil }
      values["operation"] = AppDiagnosticCodePolicy.operation(values["operation"] ?? "")
      if values["operation"] == "sync.snapshot" {
        guard values["scope"] != nil, outcome == "succeeded", visibility == "background"
        else { return nil }
      } else if [
        "scope", "environment", "phase", "pending_uploads", "pending_downloads", "pending_events",
        "blocked_records",
      ].contains(where: { values[$0] != nil }) {
        return nil
      }
    }
    if let error = values["error"] {
      values["error"] = AppDiagnosticCodePolicy.errorCode(error)
    }
    let orderedFields = (requiredKeys + optionalKeys).compactMap { key in
      values[key].map { "\(key)=\($0)" }
    }
    return ([fields[0], fields[1]] + orderedFields).joined(separator: " ")
  }

}
