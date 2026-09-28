import Darwin
import Foundation
import SnipSnapCore

/// Short-lived cross-process requests handled only by the running main app.
public actor SnipCLIRequestStore {
  public static let pendingNotificationName = Notification.Name("world.sree.snipsnap.cli-request-pending")

  private let paths: Paths
  private var isProcessing = false
  private var needsRescan = false
  private var didExcludeRootFromBackup = false

  public init(rootURL: URL) {
    paths = Paths(rootURL: rootURL)
  }

  public func publishActiveScopeToken(_ token: String) throws {
    try withLock {
      try DurableFile.write(Data(token.utf8), to: paths.activeScopeURL)
    }
  }

  /// A missing marker denies running-app commands and lets offline adds wait for
  /// an explicit library choice if the transition cannot finish.
  public func suspendActiveScope() throws {
    try withLock {
      guard FileManager.default.fileExists(atPath: paths.activeScopeURL.path) else { return }
      try FileManager.default.removeItem(at: paths.activeScopeURL)
      try DurableFile.syncDirectory(paths.root)
    }
  }

  public func activeScopeToken() throws -> String? {
    try withLock { try readScopeToken() }
  }

  public func enqueue(_ request: SnipCLIRequest) throws -> SnipCLIRequestState {
    try withLock {
      pruneExpiredFiles()
      guard request.scopeToken == (try readScopeToken()) else {
        throw SnipCLIRequestError.scopeChanged
      }
      if let receipt = try readReceipt(request.requestID) {
        guard receipt.scopeToken == request.scopeToken else {
          throw SnipCLIRequestError.scopeChanged
        }
        guard receipt.matches(request) else { throw SnipCLIRequestError.conflictingRequestID }
        return .completed(receipt)
      }
      let processingURL = paths.processingURL(request.requestID)
      if let existing = try readProcessing(at: processingURL) {
        guard existing.scopeToken == request.scopeToken else {
          throw SnipCLIRequestError.scopeChanged
        }
        guard existing.fingerprint == request.fingerprint else {
          throw SnipCLIRequestError.conflictingRequestID
        }
        return processingState(existing, at: processingURL)
      }
      let pendingURL = paths.pendingURL(request.requestID)
      if let existing = try readRequest(at: pendingURL) {
        guard existing.scopeToken == request.scopeToken else {
          throw SnipCLIRequestError.scopeChanged
        }
        guard existing.fingerprint == request.fingerprint else {
          throw SnipCLIRequestError.conflictingRequestID
        }
        if existing.expiresAt > Date(), clientIsAlive(existing.clientPID) { return .pending }
        try FileManager.default.removeItem(at: pendingURL)
      }
      try DurableFile.write(try Self.encoder.encode(request), to: pendingURL)
      return .pending
    }
  }

  public func pruneAbandoned() throws {
    try withLock { pruneExpiredFiles() }
  }

  public func state(for requestID: UUID) throws -> SnipCLIRequestState {
    try withLock {
      let scopeToken = try readScopeToken()
      if let receipt = try currentReceipt(requestID),
         receipt.scopeToken == scopeToken { return .completed(receipt) }
      let processingURL = paths.processingURL(requestID)
      if let processing = try readProcessing(at: processingURL) {
        guard processing.scopeToken == scopeToken else { return .missing }
        return processingState(processing, at: processingURL)
      }
      let pendingURL = paths.pendingURL(requestID)
      if let pending = try readRequest(at: pendingURL) {
        guard pending.scopeToken == scopeToken else { return .missing }
        if pending.expiresAt > Date(), clientIsAlive(pending.clientPID) { return .pending }
        try FileManager.default.removeItem(at: pendingURL)
        try DurableFile.syncDirectory(paths.pendingRootURL)
      }
      return .missing
    }
  }

  /// Prevents a command that was never claimed by the app from running later.
  public func cancelPending(_ requestID: UUID) throws -> SnipCLIRequestState {
    try withLock {
      let scopeToken = try readScopeToken()
      if let receipt = try readReceipt(requestID),
         receipt.scopeToken == scopeToken { return .completed(receipt) }
      let processingURL = paths.processingURL(requestID)
      if let processing = try readProcessing(at: processingURL) {
        guard processing.scopeToken == scopeToken else { return .missing }
        return processingState(processing, at: processingURL)
      }
      let pending = paths.pendingURL(requestID)
      guard FileManager.default.fileExists(atPath: pending.path) else { return .missing }
      guard try readRequest(at: pending)?.scopeToken == scopeToken else { return .missing }
      try FileManager.default.removeItem(at: pending)
      try DurableFile.syncDirectory(paths.pendingRootURL)
      return .missing
    }
  }

  /// Remove read results and compact list write results after the CLI displays them.
  public func releaseReceipt(_ requestID: UUID) throws {
    try withLock {
      guard let receipt = try readReceipt(requestID),
            receipt.scopeToken == (try readScopeToken()) else { return }
      switch receipt.action.receiptPolicy {
      case .transientRead:
        try FileManager.default.removeItem(at: paths.receiptURL(requestID))
        try DurableFile.syncDirectory(paths.receiptsRootURL)
      case .listWrite:
        if receipt.hasListWritePayload {
          try DurableFile.write(try Self.encoder.encode(receipt.compacted()),
                                to: paths.receiptURL(requestID))
        }
      case .compactWrite: break
      }
    }
  }

  public func processPending(
    using receive: @MainActor @Sendable (SnipCLIRequest) async throws -> SnipCLIReceipt
  ) async {
    try? withLock { pruneExpiredFiles() }
    guard !isProcessing else {
      needsRescan = true
      return
    }
    isProcessing = true
    defer { isProcessing = false }
    repeat {
      needsRescan = false
      for requestID in pendingRequestIDs() {
        let request: SnipCLIRequest
        let lease: SnipStoreFileLock
        do {
          guard let claimed = try claim(requestID) else { continue }
          (request, lease) = claimed
        } catch {
          continue
        }
        let receipt: SnipCLIReceipt
        do {
          receipt = try await receive(request)
        } catch is SnipCLIOutcomeUncertain {
          try? markUncertain(requestID)
          withExtendedLifetime(lease) {}
          continue
        } catch {
          receipt = SnipCLIReceipt(
            request: request, status: .failed, message: error.localizedDescription
          )
        }
        guard receipt.matches(request) else {
          try? markUncertain(requestID)
          continue
        }
        do {
          try finish(receipt, requestID: requestID)
        } catch {
          try? markUncertain(requestID)
        }
        withExtendedLifetime(lease) {}
      }
    } while needsRescan
  }

  private func claim(_ id: UUID) throws -> (SnipCLIRequest, SnipStoreFileLock)? {
    try withLock {
      let pending = paths.pendingURL(id)
      guard let request = try readRequest(at: pending) else { return nil }
      guard request.scopeToken == (try readScopeToken()) else { return nil }
      guard request.requestID == id, request.expiresAt > Date(),
        clientIsAlive(request.clientPID) else {
        try FileManager.default.removeItem(at: pending)
        try DurableFile.syncDirectory(paths.pendingRootURL)
        return nil
      }
      try DurableFile.createDirectory(paths.processingRootURL)
      let processing = paths.processingURL(id)
      if FileManager.default.fileExists(atPath: processing.path) {
        try FileManager.default.removeItem(at: pending)
        try DurableFile.syncDirectory(paths.pendingRootURL)
        return nil
      }
      let marker = ProcessingMarker(requestID: id, fingerprint: request.fingerprint,
                                    scopeToken: request.scopeToken,
                                    handlerPID: getpid())
      try DurableFile.write(try Self.encoder.encode(marker), to: processing)
      let lease = try SnipStoreFileLock(url: processing)
      try FileManager.default.removeItem(at: pending)
      try DurableFile.syncDirectory(paths.pendingRootURL)
      return (request, lease)
    }
  }

  private func finish(_ receipt: SnipCLIReceipt, requestID: UUID) throws {
    try withLock {
      let stored = receipt.status == .success
        && receipt.action.receiptPolicy != .compactWrite ? receipt : receipt.compacted()
      try DurableFile.write(try Self.encoder.encode(stored), to: paths.receiptURL(requestID))
      try FileManager.default.removeItem(at: paths.processingURL(requestID))
      try DurableFile.syncDirectory(paths.processingRootURL)
    }
  }

  private func markUncertain(_ requestID: UUID) throws {
    try withLock {
      let url = paths.processingURL(requestID)
      guard let marker = try readProcessing(at: url) else { return }
      let uncertain = ProcessingMarker(requestID: marker.requestID,
                                       fingerprint: marker.fingerprint,
                                       scopeToken: marker.scopeToken, handlerPID: 0)
      try DurableFile.write(try Self.encoder.encode(uncertain), to: url)
    }
  }

  private func pendingRequestIDs() -> [UUID] {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: paths.pendingRootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )) ?? []
    return files.compactMap { file in
      guard file.pathExtension == "json",
        let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
        let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        attributes.isRegularFile == true, attributes.isSymbolicLink != true
      else { return nil }
      return id
    }.sorted { $0.uuidString < $1.uuidString }
  }

  private func readRequest(at url: URL) throws -> SnipCLIRequest? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Self.decoder.decode(SnipCLIRequest.self, from: Data(contentsOf: url))
  }

  private func readProcessing(at url: URL) throws -> ProcessingMarker? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Self.decoder.decode(ProcessingMarker.self, from: Data(contentsOf: url))
  }

  private func processingState(_ marker: ProcessingMarker, at url: URL) -> SnipCLIRequestState {
    guard clientIsAlive(marker.handlerPID) else { return .uncertain }
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { return .uncertain }
    defer { Darwin.close(descriptor) }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
      flock(descriptor, LOCK_UN)
      return .uncertain
    }
    return errno == EWOULDBLOCK ? .processing : .uncertain
  }

  private func readReceipt(_ id: UUID) throws -> SnipCLIReceipt? {
    let url = paths.receiptURL(id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Self.decoder.decode(SnipCLIReceipt.self, from: Data(contentsOf: url))
  }

  private func readScopeToken() throws -> String? {
    guard FileManager.default.fileExists(atPath: paths.activeScopeURL.path) else { return nil }
    return String(data: try Data(contentsOf: paths.activeScopeURL), encoding: .utf8)
  }

  private func currentReceipt(_ id: UUID) throws -> SnipCLIReceipt? {
    guard let receipt = try readReceipt(id) else { return nil }
    let url = paths.receiptURL(id)
    guard let modified = try url.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate else { return receipt }
    let age = Date().timeIntervalSince(modified)
    let isRead = receipt.action.receiptPolicy == .transientRead
    if isRead && age > 60 * 60 {
      try FileManager.default.removeItem(at: url)
      try DurableFile.syncDirectory(paths.receiptsRootURL)
      return nil
    }
    if age > 60 * 60, receipt.hasListWritePayload {
      let compact = receipt.compacted()
      try DurableFile.write(try Self.encoder.encode(compact), to: url)
      return compact
    }
    return receipt
  }

  private func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
    try DurableFile.createDirectory(paths.root)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path)
    if !didExcludeRootFromBackup {
      try DurableFile.excludeFromBackup(paths.root)
      didExcludeRootFromBackup = true
    }
    let lock = try SnipStoreFileLock(url: paths.lockURL)
    defer { withExtendedLifetime(lock) {} }
    return try operation()
  }

  private func clientIsAlive(_ pid: Int32) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
  }

  private struct ProcessingMarker: Codable {
    let requestID: UUID
    let fingerprint: String
    let scopeToken: String?
    let handlerPID: Int32
  }

  private func pruneExpiredFiles() {
    if let files = try? FileManager.default.contentsOfDirectory(
      at: paths.pendingRootURL, includingPropertiesForKeys: [.isRegularFileKey]
    ) {
      var removed = false
      for file in files where file.pathExtension == "json" {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
          values.isRegularFile == true else { continue }
        let request = try? readRequest(at: file)
        if let request, request.expiresAt > Date(), clientIsAlive(request.clientPID) { continue }
        if (try? FileManager.default.removeItem(at: file)) != nil { removed = true }
      }
      if removed { try? DurableFile.syncDirectory(paths.pendingRootURL) }
    }
    let readCutoff = Date().addingTimeInterval(-60 * 60)
    // Keep write receipts and uncertain markers so an old request ID cannot
    // silently run a mutation twice. Read results carry library data and expire.
    if let files = try? FileManager.default.contentsOfDirectory(
      at: paths.receiptsRootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
    ) {
      var removed = false
      for file in files where file.pathExtension == "json" {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
          values.isRegularFile == true, let modified = values.contentModificationDate else { continue }
        let expiredRead: Bool
        if modified < readCutoff,
          let receipt = try? Self.decoder.decode(SnipCLIReceipt.self, from: Data(contentsOf: file)) {
          switch receipt.action.receiptPolicy {
          case .transientRead: expiredRead = true
          case .listWrite:
            if receipt.hasListWritePayload {
              try? DurableFile.write(try Self.encoder.encode(receipt.compacted()), to: file)
            }
            expiredRead = false
          case .compactWrite: expiredRead = false
          }
        } else {
          expiredRead = false
        }
        guard expiredRead else { continue }
        if (try? FileManager.default.removeItem(at: file)) != nil { removed = true }
      }
      if removed { try? DurableFile.syncDirectory(paths.receiptsRootURL) }
    }
  }

  private struct Paths: Sendable {
    let rootURL: URL
    var root: URL { rootURL.appendingPathComponent("Agent/Commands", isDirectory: true) }
    var pendingRootURL: URL { root.appendingPathComponent("Pending", isDirectory: true) }
    var processingRootURL: URL { root.appendingPathComponent("Processing", isDirectory: true) }
    var receiptsRootURL: URL { root.appendingPathComponent("Receipts", isDirectory: true) }
    var lockURL: URL { root.appendingPathComponent("requests.lock") }
    var activeScopeURL: URL { root.appendingPathComponent("active-scope") }
    func pendingURL(_ id: UUID) -> URL {
      pendingRootURL.appendingPathComponent("\(id.uuidString).json")
    }
    func processingURL(_ id: UUID) -> URL {
      processingRootURL.appendingPathComponent("\(id.uuidString).json")
    }
    func receiptURL(_ id: UUID) -> URL {
      receiptsRootURL.appendingPathComponent("\(id.uuidString).json")
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.timeIntervalSinceReferenceDate)
    }
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
    }
    return decoder
  }
}
