import CryptoKit
import Darwin
import Foundation

/// Commands exchanged with the running main app. The CLI never opens its library.
public enum SnipCLIAction: Codable, Equatable, Sendable {
  case add(content: String, list: String?, agentContext: SnipAgentContext?)
  case listSnips(list: String?)
  case showSnip(id: UUID)
  case updateSnip(id: UUID, content: String, expectedUpdatedAt: Date)
  case deleteSnip(id: UUID, expectedRevision: String)
  case listLists
  case showList(selector: String)
  case createList(name: String)
  case updateList(id: UUID, name: String, expectedRevision: String)
  case deleteList(id: UUID, expectedRevision: String)
}

public enum SnipCLIReceiptPolicy: Equatable, Sendable {
  case transientRead
  case listWrite
  case compactWrite
}

public extension SnipCLIAction {
  var receiptPolicy: SnipCLIReceiptPolicy {
    switch self {
    case .add: .compactWrite
    case .listSnips, .showSnip, .listLists, .showList: .transientRead
    case .createList, .updateList: .listWrite
    case .updateSnip, .deleteSnip, .deleteList: .compactWrite
    }
  }
}

public enum SnipCLIItemRevision {
  public static func token(snip: Snip) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(snip)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public enum SnipCLIListRevision {
  private struct State: Encodable {
    let list: SnipList
    let memberIDs: [String]
  }

  public static func token(list: SnipList, memberIDs: [UUID]) -> String {
    let state = State(list: list, memberIDs: memberIDs.map(\.uuidString).sorted())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(state)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct SnipCLIRequest: Codable, Equatable, Sendable {
  public let requestID: UUID
  public let action: SnipCLIAction
  public let scopeToken: String?
  public let expiresAt: Date
  public let clientPID: Int32

  public init(
    action: SnipCLIAction,
    requestID: UUID = UUID(),
    scopeToken: String? = nil,
    expiresAt: Date = Date().addingTimeInterval(15),
    clientPID: Int32 = getpid()
  ) {
    self.requestID = requestID
    self.action = action
    self.scopeToken = scopeToken
    self.expiresAt = expiresAt
    self.clientPID = clientPID
  }

  public var fingerprint: String {
    struct Identity: Encodable {
      let action: SnipCLIAction
      let scopeToken: String?
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try! encoder.encode(Identity(action: action, scopeToken: scopeToken))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public func scoped(to token: String?) -> Self {
    Self(action: action, requestID: requestID, scopeToken: token,
         expiresAt: expiresAt, clientPID: clientPID)
  }
}

public enum SnipCLIScopeToken {
  public static func token(for scope: String) -> String {
    SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

public struct SnipCLIReceipt: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case success
    case failed
  }

  public let requestID: UUID
  public let requestFingerprint: String
  public let scopeToken: String?
  public let action: SnipCLIAction
  public let status: Status
  public let snips: [Snip]
  public let lists: [SnipList]
  public let message: String?
  public let listRevision: String?
  public let snipRevisions: [String: String]
  public let updatedSnipID: UUID?
  public let updatedAt: Date?
  public let resultListID: UUID?
  public let resultSnipID: UUID?

  public init(
    request: SnipCLIRequest,
    status: Status,
    snips: [Snip] = [],
    lists: [SnipList] = [],
    message: String? = nil,
    listRevision: String? = nil
  ) {
    requestID = request.requestID
    requestFingerprint = request.fingerprint
    scopeToken = request.scopeToken
    action = request.action
    self.status = status
    self.snips = snips
    self.lists = lists
    self.message = message
    self.listRevision = listRevision
    snipRevisions = Dictionary(uniqueKeysWithValues: snips.map {
      ($0.id.uuidString, SnipCLIItemRevision.token(snip: $0))
    })
    if case .updateSnip = request.action, let snip = snips.first {
      updatedSnipID = snip.id
      updatedAt = snip.updatedAt
    } else {
      updatedSnipID = nil
      updatedAt = nil
    }
    switch request.action {
    case .add, .createList, .updateList: resultListID = lists.first?.id
    default: resultListID = nil
    }
    if case .add = request.action {
      resultSnipID = snips.first?.id
    } else {
      resultSnipID = nil
    }
  }

  public func matches(_ request: SnipCLIRequest) -> Bool {
    requestID == request.requestID && requestFingerprint == request.fingerprint
  }

  public func compacted() -> SnipCLIReceipt {
    var storedAction = action
    var storedMessage = message
    switch action {
    case .add:
      storedAction = .add(content: "", list: nil, agentContext: nil)
      if status == .success, let id = resultSnipID {
        storedMessage = message ?? "Added agent snip \(id.uuidString)."
      }
    case .updateSnip(let id, _, let expectedUpdatedAt):
      storedAction = .updateSnip(id: id, content: "", expectedUpdatedAt: expectedUpdatedAt)
      storedMessage = message ?? "Updated snip \(id.uuidString)."
    case .createList:
      storedAction = .createList(name: "")
      if status == .success, let id = lists.first?.id {
        storedMessage = message ?? "Created list \(id.uuidString)."
      }
    case .updateList(let id, _, let expectedRevision):
      storedAction = .updateList(id: id, name: "", expectedRevision: expectedRevision)
      if status == .success {
        storedMessage = message ?? "Renamed list \(id.uuidString)."
      }
    case .listSnips, .showSnip, .deleteSnip, .listLists, .showList, .deleteList:
      break
    }
    return SnipCLIReceipt(
      requestID: requestID, requestFingerprint: requestFingerprint,
      scopeToken: scopeToken, action: storedAction,
      status: status, snips: [], lists: [], message: storedMessage,
      listRevision: nil, snipRevisions: [:],
      updatedSnipID: updatedSnipID, updatedAt: updatedAt, resultListID: resultListID,
      resultSnipID: resultSnipID
    )
  }

  public var hasListWritePayload: Bool {
    switch action {
    case .createList(let name), .updateList(_, let name, _):
      !name.isEmpty || !lists.isEmpty
    case .add, .listSnips, .showSnip, .updateSnip, .deleteSnip,
         .listLists, .showList, .deleteList: false
    }
  }

  private init(requestID: UUID, requestFingerprint: String,
               scopeToken: String?, action: SnipCLIAction,
               status: Status, snips: [Snip], lists: [SnipList], message: String?,
               listRevision: String?, snipRevisions: [String: String],
               updatedSnipID: UUID?, updatedAt: Date?, resultListID: UUID?,
               resultSnipID: UUID?) {
    self.requestID = requestID
    self.requestFingerprint = requestFingerprint
    self.scopeToken = scopeToken
    self.action = action
    self.status = status
    self.snips = snips
    self.lists = lists
    self.message = message
    self.listRevision = listRevision
    self.snipRevisions = snipRevisions
    self.updatedSnipID = updatedSnipID
    self.updatedAt = updatedAt
    self.resultListID = resultListID
    self.resultSnipID = resultSnipID
  }
}

public enum SnipCLIRequestState: Equatable, Sendable {
  case missing
  case pending
  case processing
  case uncertain
  case completed(SnipCLIReceipt)
}

/// A mutation may have committed before its caller received a failure.
public struct SnipCLIOutcomeUncertain: Error, Sendable {
  public init() {}
}

public enum SnipCLIRequestError: Error, LocalizedError, Sendable {
  case conflictingRequestID
  case scopeChanged
  case editingInProgress
  case draftInProgress

  public var errorDescription: String? {
    switch self {
    case .conflictingRequestID:
      String(localized: "This request ID belongs to a different Snip Snap command.", bundle: .main)
    case .scopeChanged:
      String(localized: "Snip Snap switched libraries. Reread the library and try again with a new request ID.", bundle: .main)
    case .editingInProgress:
      String(localized: "Finish editing in Snip Snap and try again.", bundle: .main)
    case .draftInProgress:
      String(localized: "Save or clear the draft in this list before deleting it.", bundle: .main)
    }
  }
}
