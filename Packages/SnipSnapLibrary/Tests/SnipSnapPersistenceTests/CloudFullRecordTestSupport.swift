import Foundation

@testable import SnipSnapCore
@testable import SnipSnapPersistence

extension SwiftDataSnipLibrary {
  func testAcceptCloudEntity(
    namespaceKey: CloudSyncNamespaceKey,
    value: CloudAcceptedEntityInput,
    conflict: CloudConflictInput? = nil
  ) throws {
    let before = try cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let entities = before.readyEntities + before.deferredEntities
    let sameDomain = entities.first { $0.reference == value.reference }
    let sameIdentity = entities.first { $0.identity == value.identity }
    let quarantine: CloudQuarantineInput?
    if let sameDomain, sameDomain.identity != value.identity {
      quarantine = CloudQuarantineInput(
        key: "domain|\(value.reference.kind.rawValue)|\(value.reference.domainID.uuidString.lowercased())|\(value.identity.key)",
        reference: value.reference,
        identity: value.identity,
        payload: try JSONEncoder().encode(value)
      )
    } else if let sameIdentity, sameIdentity.reference != value.reference {
      quarantine = CloudQuarantineInput(
        key: "identity|\(value.identity.key)|\(value.reference.kind.rawValue)|\(value.reference.domainID.uuidString.lowercased())",
        reference: value.reference,
        identity: value.identity,
        payload: try JSONEncoder().encode(value)
      )
    } else {
      quarantine = nil
    }
    let wire = try cloudTextSyncSnapshot(namespaceKey: namespaceKey)
    let batch = CloudFullBatchCommit(
      namespaceKey: namespaceKey.rawValue,
      batchID: UUID(),
      expectedEngineState: wire.engineState,
      nextEngineState: wire.engineState,
      items: [
        CloudFullBatchItem(
          accepted: value,
          expectedLocalRevision: sameDomain?.localRevision,
          expectedSystemFields: sameDomain?.systemFields,
          localMutation: .none,
          conflict: conflict,
          quarantine: quarantine
        )
      ]
    )
    try stageCloudFullBatch(batch)
    _ = try commitCloudFullBatch(batch)
  }

  func testStoreCloudConflict(
    namespaceKey: CloudSyncNamespaceKey,
    key: String,
    reference: CloudEntityReference,
    payload: Data,
    recovery: SnipRecoveryRecord? = nil
  ) throws {
    let before = try cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let current = (before.readyEntities + before.deferredEntities).first {
      $0.reference == reference
    }
    let identity = current?.identity ?? CloudTextStorageIdentity(
      zoneName: "test-zone",
      ownerName: "test-owner",
      recordName: "test-\(reference.kind.rawValue)-\(reference.domainID.uuidString.lowercased())"
    )
    let accepted = current.map {
      CloudAcceptedEntityInput(
        reference: $0.reference,
        identity: $0.identity,
        schemaVersion: $0.schemaVersion,
        acceptedData: $0.acceptedData,
        presenceData: $0.presenceData,
        shadowData: $0.shadowData,
        systemFields: $0.systemFields,
        dependencyListID: $0.dependencyListID
      )
    } ?? CloudAcceptedEntityInput(
      reference: reference,
      identity: identity,
      schemaVersion: 1,
      acceptedData: Data("test-accepted".utf8),
      presenceData: Data(),
      shadowData: Data("test-shadow".utf8),
      systemFields: Data("test-system".utf8),
      dependencyListID: reference.kind == .snip ? SnipList.inbox.id : nil
    )
    let conflict = CloudConflictInput(
      key: key,
      reference: reference,
      format: reference.kind == .snip ? .snipMergeV1 : .listMergeV1,
      payload: payload,
      recovery: recovery
    )
    let wire = try cloudTextSyncSnapshot(namespaceKey: namespaceKey)
    let batch = CloudFullBatchCommit(
      namespaceKey: namespaceKey.rawValue,
      batchID: UUID(),
      expectedEngineState: wire.engineState,
      nextEngineState: wire.engineState,
      recoveryReviews: recovery.map {
        [CloudRecoveryReviewInput(conflictKey: key, recovery: $0)]
      } ?? [],
      items: [
        CloudFullBatchItem(
          accepted: accepted,
          expectedLocalRevision: current?.localRevision,
          expectedSystemFields: current?.systemFields,
          localMutation: .none,
          conflict: conflict,
          quarantine: nil
        )
      ]
    )
    try stageCloudFullBatch(batch)
    _ = try commitCloudFullBatch(batch)
  }

  func testDormantCloudBase(
    namespaceKey: CloudSyncNamespaceKey,
    reference: CloudEntityReference
  ) throws -> CloudDormantBase? {
    try dormantCloudBases().first {
      $0.namespaceKey == namespaceKey.rawValue && $0.reference == reference
    }
  }
}
