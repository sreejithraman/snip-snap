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
    let fake = FakeCloudRecordTransport(
      server: FakeCloudServer(),
      namespace: namespace
    )
    let fakeSnapshot = try await exercise(
      transport: fake,
      zone: zone,
      draft: draft
    )

    let container = CKContainer(identifier: containerIdentifier)
    let database = container.privateCloudDatabase
    let real = CloudKitRecordTransport(
      database: database,
      namespace: namespace
    )
    let zoneID = CKRecordZone.ID(
      zoneName: zone.name,
      ownerName: zone.ownerName
    )
    let realSnapshot = try await runWithCleanup(
      operation: {
        try await exercise(
          transport: real,
          zone: zone,
          draft: draft
        )
      },
      cleanup: {
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
    )

    guard fakeSnapshot.recordType == realSnapshot.recordType,
      fakeSnapshot.schemaVersion == realSnapshot.schemaVersion,
      fakeSnapshot.routingFields == realSnapshot.routingFields,
      fakeSnapshot.encryptedFields == realSnapshot.encryptedFields
    else {
      throw ContractError.fakeAndRealResultsDiffer
    }
  }

  static func runWithCleanup<Value>(
    operation: () async throws -> Value,
    cleanup: () async throws -> Void
  ) async throws -> Value {
    let result: Result<Value, Error>
    do {
      result = .success(try await operation())
    } catch {
      result = .failure(error)
    }
    try await cleanup()
    return try result.get()
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

  private static func exercise(
    transport: any CloudRecordTransport,
    zone: CloudZoneID,
    draft: CloudRecordDraft
  ) async throws -> CloudRecordSnapshot {
    try await transport.start(state: nil)
    let sent = try await transport.send(
      CloudOutboundBatch(
        operations: [.save(draft)],
        zonesToSave: [zone]
      )
    )
    guard case .saved(let accepted) = sent.items.first else {
      throw ContractError.saveWasNotAccepted
    }
    try await transport.confirmApplied(sent.id)
    guard let fetched = try await transport.fetchRecord(
      draft.id,
      fields: Set(draft.routingFields.keys).union(draft.encryptedFields.keys)
    ) else {
      throw ContractError.savedRecordWasNotFound
    }
    guard fetched.routingFields == accepted.routingFields,
      fetched.encryptedFields == accepted.encryptedFields
    else {
      throw ContractError.savedRecordChanged
    }
    let deleted = try await transport.send(
      CloudOutboundBatch(operations: [.delete(draft.id, base: accepted.shadow)])
    )
    guard case .deleted = deleted.items.first else {
      throw ContractError.deleteWasNotAccepted
    }
    try await transport.confirmApplied(deleted.id)
    guard try await transport.fetchRecord(
      draft.id,
      fields: Set(draft.routingFields.keys).union(draft.encryptedFields.keys)
    ) == nil else {
      throw ContractError.deletedRecordStillExists
    }
    return fetched
  }

  enum ContractError: Error, Equatable {
    case saveWasNotAccepted
    case savedRecordWasNotFound
    case savedRecordChanged
    case deleteWasNotAccepted
    case deletedRecordStillExists
    case fakeAndRealResultsDiffer
    case zoneCleanupWasNotConfirmed
  }
}
#endif
