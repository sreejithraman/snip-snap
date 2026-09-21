import Darwin
import Foundation
import SnipSnapCore

public enum AgentImportSaveResult: Equatable, Sendable {
  case pending(requestID: UUID)
  case completed(AgentImportReceipt)
}

public enum AgentImportExistingResult: Equatable, Sendable {
  case pending(AgentImportRequest)
  case completed(AgentImportReceipt)
}

public struct AgentImportSummary: Equatable, Sendable {
  public let imported: Int
  public let failed: Int

  public init(imported: Int, failed: Int) {
    self.imported = imported
    self.failed = failed
  }
}

/// A durable cross-process inbox. Only the main app consumes requests and opens the live library.
public actor AgentImportStore {
  public static let pendingNotificationName = Notification.Name("world.sree.snipsnap.agent-import-pending")

  private let paths: Paths
  private var isImporting = false
  private var needsImportRescan = false

  public init(rootURL: URL) {
    paths = Paths(rootURL: rootURL)
  }

  public func availableLists() -> [SnipList] {
    ShareDestinationCatalog.read(from: ShareImportPaths(rootURL: paths.rootURL).catalogURL)
  }

  public func publishAvailableLists(_ lists: [SnipList]) throws {
    try withLock {
      try ShareDestinationCatalog.write(
        lists,
        to: ShareImportPaths(rootURL: paths.rootURL).catalogURL
      )
    }
  }

  public func save(_ request: AgentImportRequest) throws -> AgentImportSaveResult {
    try withLock {
      if let receipt = try readReceipt(requestID: request.requestID) {
        guard receipt.matches(request) else { throw AgentImportError.conflictingRequestID }
        return .completed(receipt)
      }
      if let pending = try readRequest(requestID: request.requestID) {
        guard pending.hasSameIdentity(as: request) else {
          throw AgentImportError.conflictingRequestID
        }
        return .pending(requestID: request.requestID)
      }
      try DurableFile.write(
        try Self.makeEncoder().encode(request),
        to: paths.pendingURL(request.requestID)
      )
      return .pending(requestID: request.requestID)
    }
  }

  public func receipt(for requestID: UUID) throws -> AgentImportReceipt? {
    try withLock { try readReceipt(requestID: requestID) }
  }

  public func existingResult(for requestID: UUID) throws -> AgentImportExistingResult? {
    try withLock {
      if let receipt = try readReceipt(requestID: requestID) {
        return .completed(receipt)
      }
      if let request = try readRequest(requestID: requestID) {
        return .pending(request)
      }
      return nil
    }
  }

  /// The receiver must persist the snip before returning. Throwing retains the request for retry.
  public func importPending(
    using receive: @MainActor @Sendable (AgentImportRequest) async throws -> AgentImportReceipt
  ) async -> AgentImportSummary {
    guard !isImporting else {
      needsImportRescan = true
      return AgentImportSummary(imported: 0, failed: 0)
    }
    isImporting = true
    defer { isImporting = false }
    var imported = 0
    var failed = 0
    var attempted = Set<UUID>()
    repeat {
      needsImportRescan = false
      let requestIDs = pendingRequestIDs().filter { !attempted.contains($0) }
      for requestID in requestIDs {
        attempted.insert(requestID)
        let request: AgentImportRequest
        do {
          guard let pendingRequest = try withLock({ try readRequest(requestID: requestID) }) else {
            continue
          }
          request = pendingRequest
        } catch is DecodingError {
          try? quarantine(requestID: requestID)
          failed += 1
          continue
        } catch AgentImportError.invalidRequest {
          try? quarantine(requestID: requestID)
          failed += 1
          continue
        } catch {
          failed += 1
          continue
        }
        do {
          let receipt = try await receive(request)
          guard receipt.matches(request) else { throw AgentImportError.invalidRequest }
          try finish(request: request, with: receipt)
          if receipt.status == .failed {
            failed += 1
          } else {
            imported += 1
          }
        } catch let error as AgentImportError {
          let receipt = AgentImportReceipt(
            status: .failed,
            snipID: nil,
            listID: request.destinationListID,
            listName: request.destinationSelector ?? SnipList.inbox.name,
            request: request,
            error: error.localizedDescription
          )
          try? finish(request: request, with: receipt)
          failed += 1
        } catch {
          failed += 1
        }
      }
    } while needsImportRescan
    return AgentImportSummary(imported: imported, failed: failed)
  }

  public func pendingImportCount() -> Int {
    pendingRequestIDs().count
  }

  private func finish(request: AgentImportRequest, with receipt: AgentImportReceipt) throws {
    try withLock {
      try DurableFile.write(
        try Self.makeEncoder().encode(receipt),
        to: paths.receiptURL(request.requestID)
      )
      try FileManager.default.removeItem(at: paths.pendingURL(request.requestID))
      try DurableFile.syncDirectory(paths.pendingRootURL)
    }
  }

  private func quarantine(requestID: UUID) throws {
    try withLock {
      let sourceURL = paths.pendingURL(requestID)
      guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
      try DurableFile.createDirectory(paths.invalidRootURL)
      var destinationURL = paths.invalidURL(requestID)
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        destinationURL = paths.invalidRootURL
          .appendingPathComponent("\(requestID.uuidString)-\(UUID().uuidString).json")
      }
      try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
      try DurableFile.syncDirectory(paths.pendingRootURL)
      try DurableFile.syncDirectory(paths.invalidRootURL)
    }
  }

  private func pendingRequestIDs() -> [UUID] {
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: paths.pendingRootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    return urls.compactMap { url in
      guard url.pathExtension == "json",
        let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true,
        values.isSymbolicLink != true
      else { return nil }
      return id
    }.sorted { $0.uuidString < $1.uuidString }
  }

  private func readRequest(requestID: UUID) throws -> AgentImportRequest? {
    let url = paths.pendingURL(requestID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let request = try Self.makeDecoder().decode(
      AgentImportRequest.self,
      from: Data(contentsOf: url)
    )
    guard request.requestID == requestID else { throw AgentImportError.invalidRequest }
    return request
  }

  private func readReceipt(requestID: UUID) throws -> AgentImportReceipt? {
    let url = paths.receiptURL(requestID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let receipt = try Self.makeDecoder().decode(
      AgentImportReceipt.self,
      from: Data(contentsOf: url)
    )
    guard receipt.requestID == requestID else { throw AgentImportError.invalidRequest }
    return receipt
  }

  private func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
    try DurableFile.createDirectory(paths.agentRootURL)
    let lock = try SnipStoreFileLock(url: paths.lockURL)
    defer { withExtendedLifetime(lock) {} }
    return try operation()
  }

  private struct Paths: Sendable {
    let rootURL: URL
    var agentRootURL: URL { rootURL.appendingPathComponent("Agent", isDirectory: true) }
    var pendingRootURL: URL { agentRootURL.appendingPathComponent("Pending", isDirectory: true) }
    var invalidRootURL: URL { agentRootURL.appendingPathComponent("Invalid", isDirectory: true) }
    var receiptsRootURL: URL { agentRootURL.appendingPathComponent("Receipts", isDirectory: true) }
    var lockURL: URL { agentRootURL.appendingPathComponent("requests.lock") }
    func pendingURL(_ id: UUID) -> URL {
      pendingRootURL.appendingPathComponent("\(id.uuidString).json")
    }
    func receiptURL(_ id: UUID) -> URL {
      receiptsRootURL.appendingPathComponent("\(id.uuidString).json")
    }
    func invalidURL(_ id: UUID) -> URL {
      invalidRootURL.appendingPathComponent("\(id.uuidString).json")
    }
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
