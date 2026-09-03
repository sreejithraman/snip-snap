import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension CloudFullBatchPlanner {
  func normalize(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?,
    rawBatchData: Data
  ) throws -> NormalizedBatch {
    switch batch {
    case .fetched(let fetched):
      guard outbound == nil else { throw CloudTransportError.invalidRecord }
      return try normalizeFetched(fetched, rawBatchData: rawBatchData)
    case .sent(let sent):
      guard let outbound else { throw CloudTransportError.invalidRecord }
      return try normalizeSent(sent, outbound: outbound, rawBatchData: rawBatchData)
    }
  }

  func normalizeFetched(
    _ fetched: CloudFetchedBatch,
    rawBatchData: Data
  ) throws -> NormalizedBatch {
    var seen: [CloudRecordID: CloudFetchItemResult] = [:]
    for item in fetched.items {
      guard let id = item.id else { continue }
      if let prior = seen[id], prior != item { throw CloudTransportError.invalidRecord }
      seen[id] = item
    }
    let recoveryInputs = Self.fetchRecoveryKind(fetched).map { kind in
      [CloudFullRecoveryInput(
        namespaceKey: namespaceKey.rawValue,
        batchID: fetched.id,
        kind: kind,
        outboundData: Data(),
        resultData: rawBatchData
      )]
    } ?? []
    return NormalizedBatch(
      results: seen.values.sorted { ($0.id?.name ?? "") < ($1.id?.name ?? "") },
      nextEngine: fetched.engineState,
      attachmentOperationIDs: [],
      outboundBindings: [],
      recoveryInputs: recoveryInputs,
      outboundOperations: [:],
      sentItemResults: [:]
    )
  }

  func normalizeSent(
    _ sent: CloudSentBatch,
    outbound: CloudOutboundBatch,
    rawBatchData: Data
  ) throws -> NormalizedBatch {
    let operations = try CloudFullSyncPersistence.uniqueOperations(outbound.operations)
    let attachmentOperationIDs: Set<CloudRecordID> = if let payloadZone {
      Set(operations.keys).intersection(
        CloudFullSyncPersistence.plannedAttachmentOperationIDs(
          attachmentStorage,
          dataZone: dataZone,
          payloadZone: payloadZone
        )
      )
    } else {
      []
    }
    var sentResults: [CloudRecordID: CloudSendItemResult] = [:]
    for result in sent.items {
      guard operations[result.id] != nil,
        sentResults.updateValue(result, forKey: result.id) == nil
      else { throw CloudTransportError.invalidRecord }
    }
    guard Set(sentResults.keys) == Set(operations.keys) else {
      throw CloudTransportError.invalidRecord
    }
    let results = try sentResults.values.map { result in
      try Self.normalizeSentResult(result, operation: operations[result.id])
    }
    .sorted { ($0.id?.name ?? "") < ($1.id?.name ?? "") }
    let recoveryInputs = try Self.sendRecoveryKind(
      sent,
      normalized: results,
      attachmentOperationIDs: attachmentOperationIDs
    ).map { kind in
      [CloudFullRecoveryInput(
        namespaceKey: namespaceKey.rawValue,
        batchID: sent.id,
        kind: kind,
        outboundData: try JSONEncoder().encode(outbound),
        resultData: rawBatchData
      )]
    } ?? []
    let outboundBindings = try operations.values
      .map(CloudFullSyncPersistence.outboundBinding)
      .sorted {
        CloudFullSyncPersistence.identityOrder($0.identity)
          < CloudFullSyncPersistence.identityOrder($1.identity)
      }
    return NormalizedBatch(
      results: results,
      nextEngine: sent.engineState,
      attachmentOperationIDs: attachmentOperationIDs,
      outboundBindings: outboundBindings,
      recoveryInputs: recoveryInputs,
      outboundOperations: operations,
      sentItemResults: sentResults
    )
  }

  static func normalizeSentResult(
    _ result: CloudSendItemResult,
    operation: CloudOutboundOperation?
  ) throws -> CloudFetchItemResult {
    guard let operation else { throw CloudTransportError.invalidRecord }
    switch result {
    case .saved(let value):
      guard case .save(let draft) = operation else {
        throw CloudTransportError.invalidRecord
      }
      guard value.recordType == draft.recordType else {
        return .failed(value.id, .invalidRecord)
      }
      return .record(value)
    case .deleted(let id):
      guard case .delete = operation else { throw CloudTransportError.invalidRecord }
      return .deleted(id)
    case .conflict(let id, let value):
      if case .save(let draft) = operation, value.recordType != draft.recordType {
        return .failed(id, .invalidRecord)
      }
      return .record(value)
    case .unknownItem(let id):
      if case .save(let draft) = operation,
        draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
          || draft.recordType == CloudAttachmentRecordCodec.payloadRecordType
      {
        return .failed(id, .invalidRecord)
      }
      return .deleted(id)
    case .failed(let id, let failure):
      return .failed(id, failure)
    }
  }

  static func fetchRecoveryKind(
    _ batch: CloudFetchedBatch
  ) -> CloudFullRecoveryKind? {
    if batch.databaseEvents.contains(where: isDestructiveReset) { return .destructiveReset }
    let failures = batch.items.compactMap { item -> CloudOperationFailure? in
      guard case .failed(_, let failure) = item else { return nil }
      return failure
    } + batch.databaseEvents.compactMap { event -> CloudOperationFailure? in
      guard case .failed(_, let failure) = event else { return nil }
      return failure
    } + batch.zoneEvents.compactMap { event -> CloudOperationFailure? in
      guard case .failed(_, let failure) = event else { return nil }
      return failure
    }
    let relevant = failures.filter { $0 != .zoneMissing }
    guard !relevant.isEmpty else { return nil }
    return relevant.allSatisfy(\.isRetryable) ? .retryableFetch : .terminalFetch
  }

  static func sendRecoveryKind(
    _ batch: CloudSentBatch,
    normalized: [CloudFetchItemResult],
    attachmentOperationIDs: Set<CloudRecordID>
  ) -> CloudFullRecoveryKind? {
    if batch.databaseEvents.contains(where: isDestructiveReset) { return .destructiveReset }
    let failures = normalized.compactMap { item -> CloudOperationFailure? in
      guard case .failed(let id, let failure) = item else { return nil }
      if !failure.isRetryable, let id, attachmentOperationIDs.contains(id)
      {
        return nil
      }
      return failure
    } + batch.databaseEvents.compactMap { event -> CloudOperationFailure? in
      guard case .failed(_, let failure) = event else { return nil }
      return failure
    } + batch.zoneEvents.compactMap { event -> CloudOperationFailure? in
      guard case .failed(_, let failure) = event else { return nil }
      return failure
    }
    let relevant = failures.filter { $0 != .zoneMissing }
    guard !relevant.isEmpty else { return nil }
    return relevant.allSatisfy(\.isRetryable) ? .retryableSend : .terminalSend
  }

  static func nextNamespaceState(
    current: CloudFullNamespaceState,
    batch: CloudSyncBatch,
    dataZone: CloudZoneID,
    attachmentOperationIDs: Set<CloudRecordID>
  ) -> CloudFullNamespaceState {
    var phase = current.phase
    var zoneCreationPending = current.zoneCreationPending
    switch batch {
    case .fetched(let fetched):
      if fetched.databaseEvents.contains(where: isDestructiveReset) {
        phase = .blocked
        zoneCreationPending = false
      } else if hasMissingZone(fetched) {
        if current.phase == .active {
          phase = .blocked
        } else {
          phase = .remoteCheckedMissingZone
        }
      } else if fetchRecoveryKind(fetched) == nil {
        if current.phase != .active && current.phase != .seeding && current.phase != .blocked {
          phase = fetched.items.contains(where: {
            if case .record = $0 { true } else { false }
          }) ? .active : .remoteChecked
        }
      }
    case .sent(let sent):
      if sent.databaseEvents.contains(where: isDestructiveReset) {
        phase = .blocked
        zoneCreationPending = false
      } else if hasMissingZone(sent, attachmentOperationIDs: attachmentOperationIDs) {
        if current.phase == .seeding {
          zoneCreationPending = true
        } else {
          phase = .blocked
        }
      } else if current.phase == .seeding {
        let hasIncomplete = sent.items.contains { item in
          if case .failed(_, let failure) = item { failure.isRetryable }
          else { false }
        }
        if !hasIncomplete {
          if !zoneCreationPending || sent.databaseEvents.contains(where: { event in
            if case .zoneSaved(let zone) = event { zone == dataZone } else { false }
          }) {
            phase = .active
            zoneCreationPending = false
          }
        }
      }
    }
    return CloudFullNamespaceState(
      revision: current.revision + 1,
      phase: phase,
      zoneCreationPending: zoneCreationPending
    )
  }

  static func isDestructiveReset(_ event: CloudDatabaseEvent) -> Bool {
    switch event {
    case .zoneDeleted(_, reason: .purged), .zoneDeleted(_, reason: .encryptedDataReset): true
    default: false
    }
  }

  static func hasMissingZone(_ batch: CloudFetchedBatch) -> Bool {
    batch.databaseEvents.contains { event in
      switch event {
      case .zoneDeleted(_, reason: .deleted), .failed(_, .zoneMissing): true
      default: false
      }
    } || batch.zoneEvents.contains { event in
      if case .failed(_, .zoneMissing) = event { true } else { false }
    }
  }

  static func hasMissingZone(
    _ batch: CloudSentBatch,
    attachmentOperationIDs: Set<CloudRecordID>
  ) -> Bool {
    batch.items.contains { item in
      if case .failed(let id, .zoneMissing) = item {
        !attachmentOperationIDs.contains(id)
      } else { false }
    } || batch.databaseEvents.contains { event in
      if case .failed(_, .zoneMissing) = event { true } else { false }
    } || batch.zoneEvents.contains { event in
      if case .failed(_, .zoneMissing) = event { true } else { false }
    }
  }
}
