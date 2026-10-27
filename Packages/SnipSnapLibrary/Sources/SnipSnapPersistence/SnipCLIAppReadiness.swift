import Foundation
import SnipSnapCore

/// Identifies one launch, independently of the library's durable scope and receipts.
public struct SnipCLIAppInstance: Codable, Equatable, Sendable {
  public let pid: Int32
  public let launchDate: Date
  public let applicationPath: String
  public let nonce: UUID

  public init(pid: Int32, launchDate: Date, applicationURL: URL, nonce: UUID = UUID()) {
    self.pid = pid
    self.launchDate = launchDate
    applicationPath = applicationURL.resolvingSymlinksInPath().standardizedFileURL.path
    self.nonce = nonce
  }
}

public struct SnipCLIAppReadiness: Codable, Equatable, Sendable {
  public let instance: SnipCLIAppInstance
  public let scopeToken: String

  public init(instance: SnipCLIAppInstance, scopeToken: String) {
    self.instance = instance
    self.scopeToken = scopeToken
  }
}

public enum SnipCLIAppReadinessError: LocalizedError, AppDiagnosticErrorCodeProviding, Sendable {
  case unavailable

  public var errorDescription: String? {
    String(localized:
      "Snip Snap couldn’t prepare its command connection. Quit and reopen Snip Snap, then try again.",
      bundle: .main)
  }

  public var appDiagnosticCode: String { "cli.unavailable" }
}
