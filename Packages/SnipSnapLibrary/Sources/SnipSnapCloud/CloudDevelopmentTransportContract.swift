#if DEBUG
import CloudKit
import Foundation

@_spi(Maintainer)
public enum CloudDevelopmentTransportContract {
  public static func run(containerIdentifier: String, evidenceDirectory: URL,
    sourceRevision: String, harnessRevision: String, sessionStartedAt: Date) async throws {
    do {
      try await CloudDevelopmentAtomicContract.run(containerIdentifier: containerIdentifier,
        evidenceDirectory: evidenceDirectory, sourceRevision: sourceRevision,
        harnessRevision: harnessRevision, sessionStartedAt: sessionStartedAt)
    } catch {
      throw StepFailure(stage: "Development contract", error: error)
    }
  }

  static func runWithCleanup(
    operation: () async throws -> Void,
    cleanup: () async throws -> Void
  ) async throws {
    let result: Result<Void, Error>
    do {
      result = .success(try await operation())
    } catch {
      result = .failure(error)
    }
    do { try await cleanup() }
    catch {
      if case .failure(let original) = result {
        throw StepFailure(stage: "operation and cleanup failed",
          causes: [.step("operation", [Cause(original)]), .step("cleanup", [Cause(error)])],
          legacyDetail: "\(legacyDescription(original)); cleanup: \(legacyDescription(error))")
      }
      throw error
    }
    try result.get()
  }

  static func cleanupZone(
    maximumAttempts: Int = 3,
    delete: () async throws -> Void,
    zoneExists: () async throws -> Bool
  ) async throws {
    guard maximumAttempts > 0 else {
      throw ContractError.zoneCleanupWasNotConfirmed
    }
    for _ in 0..<maximumAttempts {
      do {
        try await delete()
      } catch {
        // A failed delete may still mean the zone is already gone. Verify it.
      }
      do {
        if try await !zoneExists() {
          return
        }
      } catch {
        // Retry both the delete and the read that confirms it.
      }
    }
    throw ContractError.zoneCleanupWasNotConfirmed
  }

  static func exercise(
    transport: any CloudRecordTransport,
    reader: any CloudRecordTransport,
    name: String,
    zone: CloudZoneID,
    drafts: [CloudRecordDraft],
    validateAccount: () async throws -> Void = {}
  ) async throws {
    try await step("\(name): start") {
      try await transport.start(state: nil)
      try await reader.start(state: nil)
    }
    // New zones must exist before the first fetch; records wait for its confirmation.
    try await step("\(name): create zone") {
      let created = try await transport.send(CloudOutboundBatch(operations: [], zonesToSave: [zone]))
      guard created.databaseEvents.contains(.zoneSaved(zone)) else {
        throw ContractError.zoneWasNotCreated
      }
      try await confirm(.sent(created), transport: transport, validateAccount: validateAccount)
    }
    try await step("\(name): initial fetch") {
      let fetched = try await transport.fetch(scope: .all)
      guard fetched.isInitialFetch, fetched.zoneEvents.contains(.fetched(zone)),
            !CloudSyncIssueError.blocksOutbound(in: .fetched(fetched)) else {
        throw ContractError.initialFetchFailed
      }
      try await confirm(.fetched(fetched), transport: transport, validateAccount: validateAccount)
    }
    for draft in drafts {
      let label = "\(name) / \(draft.recordType)"
      let accepted: CloudRecordSnapshot = try await step("\(label): save record") {
        let sent = try await transport.send(CloudOutboundBatch(operations: [.save(draft)]))
        guard case .saved(let accepted) = sent.items.first else {
          throw ContractError.saveWasNotAccepted
        }
        try await confirm(.sent(sent), transport: transport, validateAccount: validateAccount)
        return accepted
      }
      try await step("\(label): second client fetch") {
        let batch = try await reader.fetch(scope: .all)
        guard !CloudSyncIssueError.blocksOutbound(in: .fetched(batch)),
              let fetched = batch.items.compactMap({ item -> CloudRecordSnapshot? in
                if case .record(let snapshot) = item { return snapshot }
                return nil
              }).first(where: { $0.id == draft.id }) else {
          throw ContractError.savedRecordWasNotFound
        }
        guard fetched.recordType == draft.recordType,
              fetched.schemaVersion == draft.schemaVersion,
              fetched.routingFields == draft.routingFields,
              fetched.encryptedFields == draft.encryptedFields,
              fetched.routingFields == accepted.routingFields,
              fetched.encryptedFields == accepted.encryptedFields,
              fetched.assetFields == Set(draft.assetFields.keys) else {
          throw ContractError.savedRecordChanged
        }
        try await confirm(.fetched(batch), transport: reader, validateAccount: validateAccount)
      }
      try await step("\(label): attachment bytes") {
        for (field, upload) in draft.assetFields {
          let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: directory) }
          guard let receipt = try await reader.fetchAsset(
            draft.id, field: field, destination: CloudAssetDestination(validating: directory)
          ), try Data(contentsOf: receipt.fileURL) == Data(contentsOf: upload.fileURL) else {
            throw ContractError.attachmentBytesDiffer
          }
        }
      }
      try await step("\(label): delete record") {
        let deleted = try await transport.send(
          CloudOutboundBatch(operations: [.delete(draft.id, base: accepted.shadow)])
        )
        guard case .deleted = deleted.items.first else { throw ContractError.deleteWasNotAccepted }
        try await confirm(.sent(deleted), transport: transport, validateAccount: validateAccount)
        guard try await transport.fetchRecord(
          draft.id, fields: Set(draft.routingFields.keys).union(draft.encryptedFields.keys)
        ) == nil else { throw ContractError.deletedRecordStillExists }
      }
      try await step("\(label): second client deletion") {
        let batch = try await reader.fetch(scope: .all)
        guard !CloudSyncIssueError.blocksOutbound(in: .fetched(batch)),
              batch.items.contains(.deleted(draft.id)) else {
          throw ContractError.deletionWasNotDelivered
        }
        try await confirm(.fetched(batch), transport: reader, validateAccount: validateAccount)
      }
    }
  }

  // The real transport queues checkpoints before returned batches. Never acknowledge
  // past one, or silently discard an unexpected batch/account change.
  static func confirm(
    _ batch: CloudSyncBatch, transport: any CloudRecordTransport,
    validateAccount: () async throws -> Void
  ) async throws {
    while let event = await transport.pendingEvent() {
      switch event {
      case .checkpoint: break
      case .batch(let pending):
        guard pending.batch.id == batch.id else { throw ContractError.unexpectedBatch }
      case .accountChange:
        // A fresh engine reports initial sign-in too; accept only the account this run started with.
        try await validateAccount()
      }
      try await transport.confirmApplied(event.id)
      if event.id == batch.id { return }
    }
    try await transport.confirmApplied(batch.id)
  }

  private static func step<Value>(
    _ name: String, operation: () async throws -> Value
  ) async throws -> Value {
    do { return try await operation() }
    catch { throw StepFailure(stage: name, error: error) }
  }

  indirect enum Cause: Sendable {
    case contract(String), cloud(Int), oracle(String), deadline(String)
    case step(String, [Cause]), cleanup(CloudDevelopmentCleanupFailure)
    case redacted, invalidEvidence, evidenceWrite, cancelled

    init(_ error: Error) {
      switch error {
      case is CancellationError: self = .cancelled
      case let error as StepFailure: self = .step(Self.stage(error.stage), error.causes)
      case let error as ContractError: self = .contract(String(describing: error))
      case let error as CKError: self = .cloud(error.errorCode)
      case let error as CloudDevelopmentCleanupFailure: self = .cleanup(error)
      case let error as CloudDevelopmentContractFailure:
        switch error {
        case .invalidEvidence: self = .invalidEvidence
        case .oracle(let label): self = .oracle(Self.label(label))
        case .deadline(let label): self = .deadline(Self.label(label))
        case .cleanup: self = .redacted
        }
      default: self = .redacted
      }
    }

    var text: String {
      switch self {
      case .contract(let code): "contract:\(code)"
      case .cloud(let code): "CKError(\(code))"
      case .oracle(let code): "oracle:\(code)"
      case .deadline(let code): "deadline:\(code)"
      case .step(let stage, let causes): "\(stage): \(causes.map(\.text).joined(separator: "; "))"
      case .cleanup(let failure): failure.summary
      case .redacted: "redacted-error"
      case .invalidEvidence: "invalid-contract-evidence"
      case .evidenceWrite: "evidence-write-failed"
      case .cancelled: "cancelled"
      }
    }

    static func label(_ value: String) -> String {
      // Typed oracle/deadline labels are source-owned identifiers, never record bodies or paths.
      value.utf8.count <= 80 && !value.isEmpty && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
      } ? value : "redacted-label"
    }

    static func stage(_ value: String) -> String {
      let fixed = ["atomic-contract", "Development contract", "operation and cleanup failed", "operation", "cleanup"]
      if fixed.contains(value) { return value }
      for step in ["start", "create zone", "initial fetch", "save record", "second client fetch", "attachment bytes", "delete record", "second client deletion"] {
        if value.hasSuffix(": \(step)") {
          for client in ["fake", "CloudKit"] {
            for prefix in [client, "\(client) / Snip", "\(client) / AttachmentPayload"] {
              if value == "\(prefix): \(step)" { return value }
            }
          }
          return "baseline: \(step)"
        }
      }
      return "contract-step"
    }
  }

  struct StepFailure: Error, LocalizedError {
    let stage: String
    let detail: String
    let causes: [Cause]
    init(stage: String, detail: String) {
      self.stage = stage; self.detail = detail; causes = [.redacted]
    }
    init(stage: String, error: Error) {
      self.init(stage: stage, causes: [Cause(error)])
    }
    init(stage: String, causes: [Cause], legacyDetail: String? = nil) {
      self.stage = stage; self.causes = causes
      detail = legacyDetail ?? causes.map(\.text).joined(separator: "; ")
    }
    var errorDescription: String? { "\(Cause.stage(stage)): \(causes.map(\.text).joined(separator: "; "))" }
  }

  private static func legacyDescription(_ error: Error) -> String {
    // Retain old package-test introspection for plain Swift errors; never emit this compatibility detail.
    if !(error is any LocalizedError), !(error is any CustomNSError), !(type(of: error) is NSError.Type),
      (error as NSError).userInfo.isEmpty { return error.localizedDescription }
    return Cause(error).text
  }

  enum ContractError: Error, Equatable {
    case zoneWasNotCreated
    case initialFetchFailed
    case unexpectedBatch
    case accountChanged
    case saveWasNotAccepted
    case savedRecordWasNotFound
    case savedRecordChanged
    case attachmentBytesDiffer
    case deletionWasNotDelivered
    case deleteWasNotAccepted
    case deletedRecordStillExists
    case zoneCleanupWasNotConfirmed
  }
}
#endif
