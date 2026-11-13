import Darwin
import Foundation
import SnipSnapCore

/// Short-lived cross-process requests handled only by the running main app.
public actor SnipCLIRequestStore {
  public static let pendingNotificationName = Notification.Name("world.sree.snipsnap.cli-request-pending")

  private let paths: Paths
  private let now: @Sendable () -> Date
  private var processingPass = ProcessingPass.idle
  private var didExcludeRootFromBackup = false
  private var appSession = AppSession.none
  private var readinessRevision = UUID()

  public init(rootURL: URL) {
    paths = Paths(rootURL: rootURL)
    now = Date.init
  }

  package init(rootURL: URL, now: @escaping @Sendable () -> Date) {
    paths = Paths(rootURL: rootURL)
    self.now = now
  }

  public func publishActiveScopeToken(_ token: String) throws {
    try withLock {
      if let appInstance = appSession.instance {
        guard !appSession.isEnded, try readAppInstance() == appInstance else {
          throw SnipCLIAppReadinessError.unavailable
        }
      }
      // Termination may cancel the lifecycle while this task waits for the lock.
      try Task.checkCancellation()
      try DurableFile.write(Data(token.utf8), to: paths.activeScopeURL)
      if let appInstance = appSession.instance {
        try DurableFile.write(try Self.encoder.encode(
          SnipCLIAppReadiness(instance: appInstance, scopeToken: token)
        ), to: paths.readinessURL)
      } else {
        try removeIfPresent(paths.readinessURL)
      }
    }
  }

  /// Called by the main app before initialization. Old launch markers cannot grant admission.
  public func beginAppSession(_ instance: SnipCLIAppInstance) throws {
    guard !appSession.isEnded else { throw SnipCLIAppReadinessError.unavailable }
    try withLock {
      try removeIfPresent(paths.readinessURL)
      try removeIfPresent(paths.activeScopeURL)
      try DurableFile.write(try Self.encoder.encode(instance), to: paths.appInstanceURL)
    }
    appSession = .active(instance)
  }

  public func endAppSession() throws {
    appSession = .ended(appSession.instance)
    try withLock {
      guard let appInstance = appSession.instance, try readAppInstance() == appInstance else { return }
      try removeIfPresent(paths.readinessURL)
      try removeIfPresent(paths.appInstanceURL)
      try DurableFile.syncDirectory(paths.root)
    }
  }

  public func appReadiness() throws -> SnipCLIAppReadiness? {
    try withLock { try readAppReadiness() }
  }

  /// A missing marker denies commands until the app publishes the active library.
  public func suspendActiveScope() throws {
    try withLock {
      if let appInstance = appSession.instance {
        guard !appSession.isEnded, try readAppInstance() == appInstance else { return }
      }
      readinessRevision = UUID()
      try removeIfPresent(paths.readinessURL)
      try removeIfPresent(paths.activeScopeURL)
      try DurableFile.syncDirectory(paths.root)
    }
  }

  public func beginReadinessCheck() throws -> UUID {
    try suspendActiveScope()
    return readinessRevision
  }

  /// A later suspension invalidates a check even when the library scope stays the same.
  public func publishActiveScopeToken(_ token: String, ifUnchangedSince revision: UUID) throws -> Bool {
    guard revision == readinessRevision, !appSession.isEnded else { return false }
    try publishActiveScopeToken(token)
    return true
  }

  public func activeScopeToken() throws -> String? {
    try withLock { try readScopeToken() }
  }

  public func enqueue(
    _ request: SnipCLIRequest, readiness: SnipCLIAppReadiness? = nil
  ) throws -> SnipCLIRequestState {
    try withLock {
      pruneExpiredFiles()
      guard request.scopeToken == (try readScopeToken()) else {
        throw SnipCLIRequestError.scopeChanged
      }
      if let readiness {
        guard try readAppReadiness() == readiness else {
          throw SnipCLIAppReadinessError.unavailable
        }
      }
      if let receipt = try readReceipt(request.requestID) {
        guard receipt.visibleScopeToken == request.scopeToken else {
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
        if existing.expiresAt > now(), clientIsAlive(existing.clientPID) { return .pending }
        try FileManager.default.removeItem(at: pendingURL)
      }
      try DurableFile.write(try Self.encoder.encode(request), to: pendingURL)
      return .pending
    }
  }

  public func pruneAbandoned() throws {
    try withLock { pruneExpiredFiles() }
  }

  public func state(
    for requestID: UUID, waitingFor request: SnipCLIRequest? = nil
  ) throws -> SnipCLIRequestState {
    try withLock {
      let scopeToken = try readScopeToken()
      if let receipt = try currentReceipt(requestID),
         receipt.visibleScopeToken == scopeToken { return .completed(receipt) }
      let processingURL = paths.processingURL(requestID)
      if let processing = try readProcessing(at: processingURL) {
        guard processing.scopeToken == scopeToken
          || isAwaitedTransition(processing, request: request) else { return .missing }
        return processingState(processing, at: processingURL)
      }
      let pendingURL = paths.pendingURL(requestID)
      if let pending = try readRequest(at: pendingURL) {
        guard pending.scopeToken == scopeToken else { return .missing }
        if pending.expiresAt > now(), clientIsAlive(pending.clientPID) { return .pending }
        try FileManager.default.removeItem(at: pendingURL)
        try DurableFile.syncDirectory(paths.pendingRootURL)
      }
      return .missing
    }
  }

  /// Prevents a command that was never claimed by the app from running later.
  public func cancelPending(
    _ requestID: UUID, waitingFor request: SnipCLIRequest? = nil
  ) throws -> SnipCLIRequestState {
    try withLock {
      let scopeToken = try readScopeToken()
      if let receipt = try readReceipt(requestID),
         receipt.visibleScopeToken == scopeToken { return .completed(receipt) }
      let processingURL = paths.processingURL(requestID)
      if let processing = try readProcessing(at: processingURL) {
        guard processing.scopeToken == scopeToken
          || isAwaitedTransition(processing, request: request) else { return .missing }
        return processingState(processing, at: processingURL)
      }
      let pending = paths.pendingURL(requestID)
      guard FileManager.default.fileExists(atPath: pending.path) else { return .missing }
      guard let queued = try readRequest(at: pending),
        queued.scopeToken == scopeToken
          || (request?.action.allowsScopeTransition == true
            && queued.requestID == request?.requestID
            && queued.fingerprint == request?.fingerprint) else { return .missing }
      try FileManager.default.removeItem(at: pending)
      try DurableFile.syncDirectory(paths.pendingRootURL)
      return .missing
    }
  }

  /// Remove read results and compact list write results after the CLI displays them.
  public func releaseReceipt(_ requestID: UUID) throws {
    try withLock {
      guard let receipt = try readReceipt(requestID),
            receipt.visibleScopeToken == (try readScopeToken()) else { return }
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
    guard case .idle = processingPass else {
      processingPass = .scanning(rescanRequested: true)
      return
    }
    defer { processingPass = .idle }
    repeat {
      processingPass = .scanning(rescanRequested: false)
      for requestID in pendingRequestIDs() {
        guard let claimed = try? claim(requestID) else { continue }
        let (request, lease) = claimed
        switch await deliver(request, requestID: requestID, using: receive) {
        case .delivered: break
        case .deliveredBesideProcessingMarker, .uncertain: try? markUncertain(requestID)
        }
        withExtendedLifetime(lease) {}
      }
    } while processingPass == .scanning(rescanRequested: true)
  }

  private func deliver(
    _ request: SnipCLIRequest, requestID: UUID,
    using receive: @MainActor @Sendable (SnipCLIRequest) async throws -> SnipCLIReceipt
  ) async -> Delivery {
    let receipt: SnipCLIReceipt
    do {
      receipt = try await receive(request)
    } catch is SnipCLIOutcomeUncertain {
      return .uncertain
    } catch {
      receipt = SnipCLIReceipt(
        request: request, status: .failed, message: error.localizedDescription
      )
    }
    guard receipt.matches(request) else { return .uncertain }
    return finish(receipt, requestID: requestID)
  }

  private func claim(_ id: UUID) throws -> (SnipCLIRequest, SnipStoreFileLock)? {
    try withLock {
      let pending = paths.pendingURL(id)
      guard let request = try readRequest(at: pending) else { return nil }
      guard request.scopeToken == (try readScopeToken()) else { return nil }
      guard request.requestID == id, request.expiresAt > now(),
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

  private func finish(_ receipt: SnipCLIReceipt, requestID: UUID) -> Delivery {
    do {
      return try withLock {
        let stored: SnipCLIReceipt
        if case .extended = receipt.action {
          // Deliver actionable failures once. Release or retention cleanup removes
          // their user content along with the rest of the extended result.
          stored = receipt
        } else {
          stored = receipt.status == .success
            && receipt.action.receiptPolicy != .compactWrite ? receipt : receipt.compacted()
        }
        do {
          try DurableFile.write(try Self.encoder.encode(stored), to: paths.receiptURL(requestID))
        } catch {
          return .uncertain
        }
        do {
          try FileManager.default.removeItem(at: paths.processingURL(requestID))
          try DurableFile.syncDirectory(paths.processingRootURL)
        } catch {
          return .deliveredBesideProcessingMarker
        }
        return .delivered
      }
    } catch {
      return .uncertain
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

  /// The original caller may follow its claimed transition while the active scope is
  /// suspended or replaced. Status by UUID alone still hides another scope's marker.
  private func isAwaitedTransition(
    _ marker: ProcessingMarker, request: SnipCLIRequest?
  ) -> Bool {
    guard let request, request.action.allowsScopeTransition else { return false }
    return marker.requestID == request.requestID
      && marker.fingerprint == request.fingerprint && marker.scopeToken == request.scopeToken
  }

  /// Readers check the receipt before the processing marker: the receipt wins over a
  /// processing marker left beside it.
  private func readReceipt(_ id: UUID) throws -> SnipCLIReceipt? {
    let url = paths.receiptURL(id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Self.decoder.decode(SnipCLIReceipt.self, from: Data(contentsOf: url))
  }

  private func readScopeToken() throws -> String? {
    guard FileManager.default.fileExists(atPath: paths.activeScopeURL.path) else { return nil }
    return String(data: try Data(contentsOf: paths.activeScopeURL), encoding: .utf8)
  }

  private func readAppInstance() throws -> SnipCLIAppInstance? {
    guard FileManager.default.fileExists(atPath: paths.appInstanceURL.path) else { return nil }
    return try Self.decoder.decode(SnipCLIAppInstance.self, from: Data(contentsOf: paths.appInstanceURL))
  }

  private func readAppReadiness() throws -> SnipCLIAppReadiness? {
    guard FileManager.default.fileExists(atPath: paths.readinessURL.path) else { return nil }
    let ready = try Self.decoder.decode(SnipCLIAppReadiness.self, from: Data(contentsOf: paths.readinessURL))
    guard ready.instance == (try readAppInstance()), ready.scopeToken == (try readScopeToken()) else {
      return nil
    }
    return ready
  }

  private func removeIfPresent(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  private func currentReceipt(_ id: UUID) throws -> SnipCLIReceipt? {
    guard let receipt = try readReceipt(id) else { return nil }
    let url = paths.receiptURL(id)
    guard let modified = try url.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate else { return receipt }
    let age = now().timeIntervalSince(modified)
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

  private enum AppSession {
    /// A CLI process, or the app before it begins its session.
    case none
    case active(SnipCLIAppInstance)
    /// Holds the instance whose session ended, or nil when no session began.
    case ended(SnipCLIAppInstance?)

    var instance: SnipCLIAppInstance? {
      switch self {
      case .none: nil
      case .active(let instance): instance
      case .ended(let instance): instance
      }
    }

    var isEnded: Bool {
      if case .ended = self { true } else { false }
    }
  }

  private enum ProcessingPass: Equatable {
    case idle
    case scanning(rescanRequested: Bool)
  }

  /// How a claimed request's marker files end up after delivery.
  private enum Delivery {
    /// The receipt is written and the processing marker removed.
    case delivered
    /// The receipt is durable, but removing the processing marker or syncing its
    /// directory failed, so the marker may remain.
    case deliveredBesideProcessingMarker
    /// No durable receipt, so the outcome is unknown.
    case uncertain
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
        if let request, request.expiresAt > now(), clientIsAlive(request.clientPID) { continue }
        if (try? FileManager.default.removeItem(at: file)) != nil { removed = true }
      }
      if removed { try? DurableFile.syncDirectory(paths.pendingRootURL) }
    }
    let readCutoff = now().addingTimeInterval(-60 * 60)
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
    var appInstanceURL: URL { root.appendingPathComponent("app-instance.json") }
    var readinessURL: URL { root.appendingPathComponent("ready-app.json") }
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
