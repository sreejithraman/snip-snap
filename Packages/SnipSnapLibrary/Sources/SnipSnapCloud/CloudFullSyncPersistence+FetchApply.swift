import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  func commitStagedBatch(
    _ batch: CloudFullBatchCommit, deferredSetupPointerDeletes: [UUID: CloudSetupPointerDelete.Deferral] = [:],
    setupReplacements: Set<CloudSetupPointerDelete.Replacement> = []
  ) async throws {
    let legacyPayloadReplay = deferredSetupPointerDeletes.isEmpty && setupReplacements.isEmpty
      ? legacyStagedPayloadReplayProof(for: batch) : nil
    _ = try await library.commitCloudFullBatch(
      batch, resolveAttachmentMetadata: attachmentMetadataRebase(for: batch),
      deferredSetupPointerDeletes: deferredSetupPointerDeletes, setupReplacements: setupReplacements,
      legacyPayloadReplay: legacyPayloadReplay
    )
  }

  private func legacyStagedPayloadReplayProof(
    for batch: CloudFullBatchCommit
  ) -> SwiftDataSnipLibrary.LegacyStagedPayloadReplayProof? {
    guard batch.hasPlannedDeferredReleases, batch.nextNamespaceState?.phase == .blocked,
      batch.namespaceKey == namespaceKey.rawValue, batch.attachmentTransitions.isEmpty,
      let payloadZone, let data = batch.rawBatchData
    else { return nil }
    let decoder = JSONDecoder()
    guard let raw = try? decoder.decode(RawStagedBatch.self, from: data),
      raw.storageVersion == 1, case .sent(let sent) = raw.batch, sent.id == batch.batchID,
      let outbound = raw.outbound, outbound.operations.count == 1,
      let operation = outbound.operations.first,
      CloudFullBatchPlanner.isSubmittedPayloadSave(operation, dataZone: dataZone, payloadZone: payloadZone),
      case .save(let draft) = operation, Self.hasLegacyPayloadDraftFields(draft),
      sent.items == [.failed(operation.id, .zoneMissing)],
      outbound.zonesToSave.isSubset(of: [payloadZone]), sent.zoneEvents.isEmpty,
      sent.databaseEvents.isEmpty
        || (outbound.zonesToSave.contains(payloadZone) && sent.databaseEvents == [.zoneSaved(payloadZone)]),
      let binding = try? Self.outboundBinding(operation), batch.outboundBindings == [binding],
      let expectedData = batch.expectedEngineState, let nextData = batch.nextEngineState,
      let expected = try? decoder.decode(CloudEngineStateEnvelope.self, from: expectedData),
      let next = try? decoder.decode(CloudEngineStateEnvelope.self, from: nextData),
      expected.namespace == namespace, next.namespace == namespace,
      !expected.serialization.isEmpty, !next.serialization.isEmpty,
      !expected.requiresInitialFetch, !next.requiresInitialFetch, next == sent.engineState
    else { return nil }
    return .init(payloadIdentity: binding.identity)
  }

  private static func hasLegacyPayloadDraftFields(_ draft: CloudRecordDraft) -> Bool {
    let version = CloudAttachmentRecordCodec.schemaVersion
    return draft.schemaVersion == version
      && draft.routingFields == ["schemaVersion": .int64(Int64(version))]
      && draft.encryptedFields.isEmpty && draft.removedRoutingFields.isEmpty
      && draft.removedEncryptedFields.isEmpty && draft.base == nil
      && draft.assetFields.count == 1
      && draft.assetFields[CloudAttachmentRecordCodec.assetField]?.fileURL.isFileURL == true
  }

  private func attachmentMetadataRebase(
    for batch: CloudFullBatchCommit
  ) -> CloudAttachmentMetadataRebase.Resolve? {
    guard !batch.attachmentTransitions.isEmpty, let payloadZone,
      let data = batch.rawBatchData, let raw = try? JSONDecoder().decode(RawStagedBatch.self, from: data),
      raw.storageVersion == 1, raw.batch.id == batch.batchID
    else { return nil }
    let dataZone = self.dataZone
    switch raw.batch {
    case .fetched:
      return { identity, priorShadow, _ in
        let base = priorShadow.flatMap {
          Self.attachmentMetadata(from: $0, id: Self.recordID(identity), dataZone: dataZone, payloadZone: payloadZone)
        }
        return .fetched(base: base)
      }
    case .sent(let sent):
      let conflicts = sent.items.compactMap { item -> (CloudRecordID, CloudRecordSnapshot)? in
        guard case .conflict(let id, let server) = item,
          id == server.id, server.recordType == CloudAttachmentRecordCodec.metadataRecordType
        else { return nil }
        return (id, server)
      }
      guard !conflicts.isEmpty, let outbound = raw.outbound,
        let operations = try? Self.uniqueOperations(outbound.operations)
      else { return nil }
      let servers = Dictionary(conflicts, uniquingKeysWith: { first, _ in first })
      return { identity, priorShadow, incomingShadow in
        let id = Self.recordID(identity)
        guard let incomingShadow, let server = servers[id], server.shadow.data == incomingShadow,
          case .save(let draft)? = operations[id], let shadow = draft.base,
          let base = Self.attachmentMetadata(
            from: shadow.data, id: id, dataZone: dataZone, payloadZone: payloadZone
          ),
          let sent = try? CloudAttachmentRecordCodec.metadata(
            from: draft, metadataZone: dataZone, payloadZone: payloadZone
          ),
          let remote = try? CloudAttachmentRecordCodec.metadata(
            from: server, metadataZone: dataZone, payloadZone: payloadZone
          )
        else { return nil }
        let prior = priorShadow.flatMap {
          Self.attachmentMetadata(from: $0, id: id, dataZone: dataZone, payloadZone: payloadZone)
        }
        return .conflict(base: base, prior: prior, sent: sent, server: remote)
      }
    }
  }

  private static func attachmentMetadata(
    from shadowData: Data,
    id: CloudRecordID,
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID
  ) -> CloudAttachmentMetadataValue? {
    guard let shadow = try? CloudRecordShadow(data: shadowData),
      let snapshot = try? CloudKitRecordMapper.snapshot(shadow.record()), snapshot.id == id
    else { return nil }
    return try? CloudAttachmentRecordCodec.metadata(
      from: snapshot, metadataZone: dataZone, payloadZone: payloadZone
    )
  }

  func makeCommit(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?,
    rawBatchData: Data
  ) async throws -> CloudFullBatchCommit {
    let wire = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let recovery = corruptShadowRecovery(in: stored)
    let attachmentStorage = try await library.cloudAttachmentStorageSnapshot(
      namespaceKey: namespaceKey
    )
    return try CloudFullBatchPlanner(
      namespaceKey: namespaceKey,
      dataZone: dataZone,
      payloadZone: payloadZone,
      expectedEngine: wire.engineState,
      local: local,
      stored: stored,
      attachmentStorage: attachmentStorage,
      recoveryEvents: try await library.cloudFullRecoveryEvents(namespaceKey: namespaceKey)
    ).plan(
      recoveryFetchBatch(batch, stored: stored, recovery: recovery), inventorySource: batch,
      blockedReplayIDs: recovery.unpreparedRecordIDs,
      outbound: outbound, rawBatchData: rawBatchData
    )
  }
}
