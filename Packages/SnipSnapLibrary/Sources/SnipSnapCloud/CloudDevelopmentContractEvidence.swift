#if DEBUG
import CloudKit
import CryptoKit
import Foundation
import SnipSnapPersistence
import Synchronization

/// Evidence only. These files are not an application storage format or CloudKit fields.
struct CloudDevelopmentContractManifest: Codable, Sendable {
  let runID: UUID
  let sourceRevision: String
  let harnessRevision: String
  let accountFingerprint: String
  let startedAt: Date
  let workDeadline: Date
  let cleanupDeadline: Date
  let zones: [String]
  var results: [String: String] = [:]
  var cleanup: [String: String] = [:]
  var observations: [String: [String: String]] = [:]
}

enum CloudDevelopmentContractFailure: Error, Equatable {
  case invalidEvidence
  case deadline(String)
  case oracle(String)
  case cleanup([String])
}

final class CloudDevelopmentContractEvidence: Sendable {
  struct Entry: Codable, Sendable {
    let sequence: Int
    let phase: String
    let client: String
    let kind: String
    let ids: [String]
    let atomic: Bool?
    let errors: [String: Int]
    let serverTags: [String: String]
    let pending: [String]
  }
  private struct State: Sendable {
    var phase = "baseline"
    var entries: [Entry] = []
    var truncated = false
  }
  private let state = Mutex(State())
  let directory: URL
  let zoneNames: Set<String>

  init(directory: URL, zoneNames: Set<String>) throws {
    guard directory.isFileURL, directory.path.hasPrefix("/"), !zoneNames.isEmpty,
      zoneNames.allSatisfy({ $0.hasPrefix("snipsnap-contract-") })
    else { throw CloudDevelopmentContractFailure.invalidEvidence }
    self.directory = directory
    self.zoneNames = zoneNames
  }

  static func fingerprint(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func begin(_ phase: String) { state.withLock { $0.phase = phase } }

  func name(_ id: CKRecord.ID) -> String {
    // An unexpected account/app-zone identity must never leak through the observer.
    zoneNames.contains(id.zoneID.zoneName) ? "\(id.zoneID.zoneName)/\(id.recordName)" : "<foreign-zone>"
  }

  func append(client: String, kind: String, ids: [CKRecord.ID] = [], atomic: Bool? = nil,
    errors: [(CKRecord.ID, CKError)] = [], records: [CKRecord] = [], pending: [CKSyncEngine.PendingRecordZoneChange] = []) {
    let codes = Dictionary(errors.map { (name($0.0), $0.1.errorCode) }, uniquingKeysWith: { a, _ in a })
    var tags = Dictionary(errors.compactMap { id, error -> (String, String)? in
      guard let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
        server.recordID == id, let tag = server.recordChangeTag else { return nil }
      return (name(id), Self.fingerprint(tag))
    }, uniquingKeysWith: { a, _ in a })
    for record in records {
      if let tag = record.recordChangeTag { tags[name(record.recordID)] = Self.fingerprint(tag) }
    }
    let remaining = pending.compactMap { change -> String? in
      switch change {
      case .saveRecord(let id): "save:\(name(id))"
      case .deleteRecord(let id): "delete:\(name(id))"
      @unknown default: "unknown"
      }
    }.sorted()
    state.withLock { value in
      guard value.entries.count < 10_000 else { value.truncated = true; return }
      value.entries.append(Entry(sequence: value.entries.count, phase: value.phase, client: client,
        kind: kind, ids: ids.map(name).sorted(), atomic: atomic, errors: codes,
        serverTags: tags, pending: remaining))
    }
  }

  func entries(phase: String? = nil, client: String? = nil) throws -> [Entry] {
    try state.withLock { value in
      guard !value.truncated else { throw CloudDevelopmentContractFailure.oracle("trace-truncated") }
      return value.entries.filter { (phase == nil || $0.phase == phase) && (client == nil || $0.client == client) }
    }
  }

  func write<Value: Encodable>(_ value: Value, named name: String) throws {
    guard !name.contains("/"), !name.contains("..") else { throw CloudDevelopmentContractFailure.invalidEvidence }
    let url = directory.appendingPathComponent(name)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try DurableFile.write(encoder.encode(value), to: url)
  }

  func flush() throws { try write(entries(), named: "sdk-trace.json") }
}

/// Forwards the same operations, errors, events and returned batches. No production transport hook.
final class CloudDevelopmentEngineObserver: CloudKitRecordEngine, CKSyncEngineDelegate, Sendable {
  private let storage = Mutex<(any CloudKitRecordEngine)?>(nil)
  private let transport: CloudKitRecordTransport
  private let evidence: CloudDevelopmentContractEvidence
  private let client: String

  init(transport: CloudKitRecordTransport, evidence: CloudDevelopmentContractEvidence, client: String,
    makeBase: (CloudDevelopmentEngineObserver) -> any CloudKitRecordEngine) {
    self.transport = transport
    self.evidence = evidence
    self.client = client
    // All stored fields are initialized before the SDK receives its delegate.
    let base = makeBase(self)
    storage.withLock { $0 = base }
  }

  private var base: any CloudKitRecordEngine {
    storage.withLock { value in
      guard let value else { preconditionFailure("Engine factory used before initialization completed") }
      return value
    }
  }
  var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { base.pendingRecordZoneChanges }
  var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { base.pendingDatabaseChanges }
  func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
    evidence.append(client: client, kind: "app-add", pending: changes)
    base.add(pendingRecordZoneChanges: changes)
  }
  func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
    evidence.append(client: client, kind: "app-remove", pending: changes)
    base.remove(pendingRecordZoneChanges: changes)
  }
  func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) { base.add(pendingDatabaseChanges: changes) }
  func remove(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) { base.remove(pendingDatabaseChanges: changes) }

  func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {
    evidence.append(client: client, kind: "fetch-start", pending: pendingRecordZoneChanges)
    do {
      try await base.fetchChanges(options)
      evidence.append(client: client, kind: "fetch-return", pending: pendingRecordZoneChanges)
    } catch {
      evidence.append(client: client, kind: "fetch-throw", pending: pendingRecordZoneChanges)
      throw error
    }
  }
  func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
    evidence.append(client: client, kind: "send-start", pending: pendingRecordZoneChanges)
    do {
      try await base.sendChanges(options)
      evidence.append(client: client, kind: "send-return", pending: pendingRecordZoneChanges)
    } catch {
      // Error codes only: never error.userInfo, serialized state or account identifiers.
      evidence.append(client: client, kind: "send-throw:\((error as? CKError)?.errorCode ?? -1)", pending: pendingRecordZoneChanges)
      throw error
    }
  }

  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    await forward(CloudKitRecordEngineEvent(event))
  }

  // Established engine-event seam, also used by account-free forwarding negative controls.
  func forward(_ event: CloudKitRecordEngineEvent) async {
    switch event {
    case .sentRecordZoneChanges(let saved, let deleted, let failedSaves, let failedDeletes):
      let errors = failedSaves.map { ($0.recordID, $0.error) } + failedDeletes.map { ($0.recordID, $0.error) }
      evidence.append(client: client, kind: "sent-event-before", ids: saved.map(\.recordID) + deleted + errors.map(\.0),
        errors: errors, records: saved, pending: pendingRecordZoneChanges)
    case .fetchedRecordZoneChanges(let records, let deleted):
      evidence.append(client: client, kind: "fetched-event", ids: records.map(\.recordID) + deleted, records: records)
    case .didFetchChanges: evidence.append(client: client, kind: "did-fetch")
    case .accountChange: evidence.append(client: client, kind: "account-change")
    default: break
    }
    await transport.handle(event, from: self)
    if case .sentRecordZoneChanges = event {
      evidence.append(client: client, kind: "sent-event-after", pending: pendingRecordZoneChanges)
    }
  }

  func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
    await batch(scope: context.options.scope)
  }
  func batch(scope: CKSyncEngine.SendChangesOptions.Scope) async -> CKSyncEngine.RecordZoneChangeBatch? {
    let batch = await transport.nextRecordZoneChangeBatch(scope: scope, from: self)
    evidence.append(client: client, kind: batch == nil ? "provider-nil" : "provider-batch",
      ids: (batch?.recordsToSave.map(\.recordID) ?? []) + (batch?.recordIDsToDelete ?? []),
      atomic: batch?.atomicByZone, pending: pendingRecordZoneChanges)
    return batch
  }
  func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
    syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
    await fetchOptions()
  }
  func fetchOptions() async -> CKSyncEngine.FetchChangesOptions {
    await transport.nextFetchChangesOptions()
  }
}

struct CloudDevelopmentContractBudget: Sendable {
  let workDeadline: Date
  let cleanupDeadline: Date
  var now: @Sendable () -> Date = Date.init

  func check(_ phase: String, cleanup: Bool = false) throws {
    if !cleanup { try Task.checkCancellation() }
    guard now() < (cleanup ? cleanupDeadline : workDeadline) else {
      throw CloudDevelopmentContractFailure.deadline(phase)
    }
  }

  func perform<Value: Sendable>(_ phase: String, seconds: TimeInterval = 90,
    cleanup: Bool = false, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    try check(phase, cleanup: cleanup)
    let remaining = min(seconds, (cleanup ? cleanupDeadline : workDeadline).timeIntervalSince(now()))
    // The SDK must cooperate with cancellation; the coordinated slot is the outer bound.
    return try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: .seconds(remaining))
        throw CloudDevelopmentContractFailure.deadline(phase)
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() else { throw CancellationError() }
      return value
    }
  }
}

extension CloudDevelopmentTransportContract {
  /// Always attempt every exact manifest zone, including partial creation/first cleanup failure.
  static func cleanupZones(_ zones: [CloudZoneID], validateAccount: () async throws -> Void,
    delete: (CloudZoneID) async throws -> Void, exists: (CloudZoneID) async throws -> Bool,
    checkBudget: () throws -> Void = {}, didFinish: (CloudZoneID, Bool) -> Void = { _, _ in }) async throws {
    var failures: [String] = []
    for zone in zones {
      do {
        try checkBudget()
        try await validateAccount()
        try await cleanupZone(delete: {
          try checkBudget()
          try await validateAccount()
          try await delete(zone)
        }, zoneExists: {
          try checkBudget()
          try await validateAccount()
          return try await exists(zone)
        })
        didFinish(zone, true)
      } catch {
        failures.append("\(zone.name): \(CloudDevelopmentAtomicContract.safe(error))")
        didFinish(zone, false)
      }
    }
    if !failures.isEmpty { throw CloudDevelopmentContractFailure.cleanup(failures) }
  }
}
#endif
