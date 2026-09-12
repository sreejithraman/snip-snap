#if DEBUG
import CloudKit
import Foundation

@_spi(Maintainer)
public enum CloudDevelopmentTransportContract {
  public static func run(containerIdentifier: String) async throws {
    let zone = CloudZoneID(
      name: "snipsnap-contract-\(UUID().uuidString.lowercased())",
      ownerName: CKCurrentUserDefaultName
    )
    let namespace = CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "maintainer-contract",
      generation: UUID(),
      zones: [zone]
    )
    let recordID = CloudRecordID.random(in: zone)
    let draft = CloudRecordDraft.text(
      id: recordID,
      snipID: UUID(),
      text: "Snip Snap Cloud Dev transport contract"
    )
    let files = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: files) }
    let source = files.appendingPathComponent("attachment.bin")
    try Data((0..<8192).map { UInt8($0 % 251) }).write(to: source)
    let attachment = CloudRecordDraft(
      id: .random(in: zone), recordType: CloudAttachmentRecordCodec.payloadRecordType,
      schemaVersion: CloudAttachmentRecordCodec.schemaVersion,
      routingFields: ["schemaVersion": .int64(1)], encryptedFields: [:],
      assetFields: [CloudAttachmentRecordCodec.assetField: CloudAssetUpload(fileURL: source)]
    )
    let drafts = [draft, attachment]
    let fakeServer = FakeCloudServer()
    let fake = FakeCloudRecordTransport(server: fakeServer, namespace: namespace)
    let fakeReader = FakeCloudRecordTransport(server: fakeServer, namespace: namespace)
    try await exercise(
      transport: fake, reader: fakeReader,
      name: "fake", zone: zone, drafts: drafts
    )

    let container = CKContainer(identifier: containerIdentifier)
    let account = try await step("CloudKit: account") { try await container.userRecordID() }
    let database = container.privateCloudDatabase
    let real = CloudKitRecordTransport(
      database: database,
      namespace: namespace
    )
    let realReader = CloudKitRecordTransport(database: database, namespace: namespace)
    let validateAccount: () async throws -> Void = {
      guard try await container.userRecordID() == account else { throw ContractError.accountChanged }
    }
    let zoneID = CKRecordZone.ID(
      zoneName: zone.name,
      ownerName: zone.ownerName
    )
    try await runWithCleanup(
      operation: {
        try await exercise(
          transport: real, reader: realReader,
          name: "CloudKit", zone: zone, drafts: drafts,
          validateAccount: validateAccount
        )
      },
      cleanup: {
        await real.reset()
        await realReader.reset()
        try await step("CloudKit: cleanup \(zone.name)") {
          try await validateAccount()
          try await cleanupZone(
            delete: { try await database.deleteRecordZone(withID: zoneID) },
            zoneExists: {
              do {
                _ = try await database.recordZone(for: zoneID)
                return true
              } catch let error as CKError where error.code == .zoneNotFound {
                return false
              }
            }
          )
        }
      }
    )
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
          detail: "\(original.localizedDescription); cleanup: \(error.localizedDescription)")
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
      guard fetched.zoneEvents.contains(.fetched(zone)),
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
    catch { throw StepFailure(stage: name, detail: String(reflecting: error)) }
  }

  struct StepFailure: Error, LocalizedError {
    let stage: String
    let detail: String
    var errorDescription: String? { "\(stage): \(detail)" }
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
