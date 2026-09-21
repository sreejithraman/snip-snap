import CryptoKit
import Foundation

public enum AgentImportError: Error, Equatable, LocalizedError, Sendable {
  case conflictingRequestID
  case invalidRequest

  public var errorDescription: String? {
    switch self {
    case .conflictingRequestID:
      String(
        localized: "The request UUID is already being used for different snip content, context, or a different list.",
        bundle: .main
      )
    case .invalidRequest:
      String(localized: "The pending agent snip request is invalid.", bundle: .main)
    }
  }
}

/// The domain payload exchanged between an automation client and Snip Snap.
public struct AgentImportRequest: Codable, Equatable, Sendable {
  public let content: String
  public let destinationListID: UUID
  public let destinationSelector: String?
  public let agentContext: SnipAgentContext?
  public let requestID: UUID
  public let createdAt: Date

  public init(
    content: String,
    destinationListID: UUID,
    destinationSelector: String? = nil,
    agentContext: SnipAgentContext? = nil,
    requestID: UUID = UUID(),
    createdAt: Date = Date()
  ) {
    self.content = content
    self.destinationListID = destinationListID
    self.destinationSelector = destinationSelector
    self.agentContext = agentContext
    self.requestID = requestID
    self.createdAt = createdAt
  }

  public var fingerprint: String {
    let identity = FingerprintIdentity(
      version: 1,
      content: content,
      destinationListID: destinationListID,
      destinationSelector: destinationSelector,
      agentContext: agentContext
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(identity)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public func hasSameIdentity(as other: AgentImportRequest) -> Bool {
    requestID == other.requestID && fingerprint == other.fingerprint
  }

  private struct FingerprintIdentity: Encodable {
    let version: Int
    let content: String
    let destinationListID: UUID
    let destinationSelector: String?
    let agentContext: SnipAgentContext?
  }
}

public struct AgentImportReceipt: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case added
    case unchanged
    case failed
  }

  public let status: Status
  public let snipID: UUID?
  public let listID: UUID
  public let listName: String
  public let requestID: UUID
  public let requestedListID: UUID
  public let requestFingerprint: String
  public let error: String?

  public init(
    status: Status,
    snipID: UUID?,
    listID: UUID,
    listName: String,
    request: AgentImportRequest,
    error: String? = nil
  ) {
    self.status = status
    self.snipID = snipID
    self.listID = listID
    self.listName = listName
    requestID = request.requestID
    requestedListID = request.destinationListID
    requestFingerprint = request.fingerprint
    self.error = error
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case snipID
    case listID
    case listName
    case requestID
    case requestedListID
    case requestFingerprint
    case error
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(Status.self, forKey: .status)
    snipID = try container.decodeIfPresent(UUID.self, forKey: .snipID)
    listID = try container.decode(UUID.self, forKey: .listID)
    listName = try container.decode(String.self, forKey: .listName)
    requestID = try container.decode(UUID.self, forKey: .requestID)
    requestedListID = try container.decodeIfPresent(UUID.self, forKey: .requestedListID) ?? listID
    requestFingerprint = try container.decode(String.self, forKey: .requestFingerprint)
    error = try container.decodeIfPresent(String.self, forKey: .error)
  }

  public func matches(_ request: AgentImportRequest) -> Bool {
    requestID == request.requestID && requestFingerprint == request.fingerprint
  }
}
