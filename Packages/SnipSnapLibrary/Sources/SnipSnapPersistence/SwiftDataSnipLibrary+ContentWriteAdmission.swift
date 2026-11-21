import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  package func hasPendingCloudReset() throws -> Bool {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    do {
      try requireNoCloudReset(context: context, checkEnrollment: false)
      return false
    } catch CloudContentWriteAdmission.Block.dataReset {
      return true
    }
  }

  /// Call inside the same store lock as the content write. Reset evidence moves
  /// from the staged batch to recovery rows in one commit. Unreadable evidence
  /// cannot prove that this source is safe to edit, including after reopening.
  func requireContentWritesAllowed(context: ModelContext) throws {
    guard retirementMarkers.phase == .writable else {
      throw SnipLibraryError.readOnlyRecovery
    }
    do {
      try Self.requireNoCloudReset(context: context, checkEnrollment: checksCloudEnrollment)
    } catch CloudContentWriteAdmission.Block.dataReset {
      diagnostics.record(.writeAdmission(.failed, reason: .dataReset))
      throw SnipLibraryError.modeTransitionInProgress
    }
  }

  private static func requireNoCloudReset(context: ModelContext, checkEnrollment: Bool) throws {
    for row in try context.fetch(FetchDescriptor<StoredCloudStagedBatch>()) {
      try CloudContentWriteAdmission.requireStagedAllowsWrites(row, checkEnrollment: checkEnrollment)
    }
    for row in try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>()) {
      try CloudContentWriteAdmission.requireRecoveryAllowsWrites(row)
    }
    guard checkEnrollment else { return }
    for row in try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>()) {
      guard let enrollment = try? Self.fullEnrollmentState(from: row.referencesData) else {
        throw SnipLibraryError.invalidStore
      }
      try CloudContentWriteAdmission.requireNamespaceAllowsWrites(enrollment.namespaceState)
    }
  }
}

/// The storage admission rule reads every durable source of reset evidence.
private enum CloudContentWriteAdmission {
  enum Block: Error { case dataReset }
  static func requireStagedAllowsWrites(_ row: StoredCloudStagedBatch, checkEnrollment: Bool) throws {
    guard row.id == "\(row.namespaceKey)|\(row.batchID.uuidString.lowercased())" else {
      throw SnipLibraryError.invalidStore
    }
    let envelope = CloudWirePayloadEnvelope.decode(row.payload)
    guard let envelope, envelope.format == .fullRecordV1,
      let batch = try? JSONDecoder().decode(CloudFullBatchCommit.self, from: envelope.payload),
      batch.storageVersion == 1, batch.namespaceKey == row.namespaceKey,
      batch.batchID == row.batchID
    else { throw SnipLibraryError.invalidStore }
    try requireFullBatchAllowsWrites(batch, checkEnrollment: checkEnrollment)
  }

  private static func requireFullBatchAllowsWrites(_ batch: CloudFullBatchCommit, checkEnrollment: Bool) throws {
    if checkEnrollment, let state = batch.nextNamespaceState {
      try requireNamespaceAllowsWrites(state)
    }
    if let raw = batch.rawBatchData {
      try requireRawBatchAllowsWrites(raw, id: batch.batchID)
    }
    for input in batch.recoveryInputs {
      try requireValidRecovery(input, namespace: batch.namespaceKey, batchID: batch.batchID)
    }
    for change in batch.recoveryChanges {
      try requireValidRecovery(change.expected, namespace: batch.namespaceKey,
        batchID: change.expected.batchID)
      if let replacement = change.replacement {
        try requireValidRecovery(replacement, namespace: batch.namespaceKey,
          batchID: change.expected.batchID)
      }
    }
  }

  static func requireNamespaceAllowsWrites(_ state: CloudFullNamespaceState) throws {
    guard state.storageVersion == 1 else { throw SnipLibraryError.invalidStore }
    // The namespace commit outlives staged input and failed reset delivery.
    if state.phase == .blocked { throw Block.dataReset }
  }

  static func requireRecoveryAllowsWrites(_ row: StoredCloudRecoveryEvent) throws {
    guard row.id == "\(row.namespaceKey)|\(row.eventKey)" else { throw SnipLibraryError.invalidStore }
    let envelope = CloudWirePayloadEnvelope.decode(row.payload)
    guard let envelope, envelope.format == .fullRecordV1 else { throw SnipLibraryError.invalidStore }
    if row.eventKey.hasPrefix("review-recovery-") {
      // These rows hold user review choices, not collection-reset events.
      guard let review = try? JSONDecoder().decode(ContentRecoveryReview.self, from: envelope.payload),
        review.storageVersion == 1,
        row.eventKey == "review-recovery-\(review.recovery.id.uuidString.lowercased())"
      else { throw SnipLibraryError.invalidStore }
      return
    }
    guard let recovery = try? JSONDecoder().decode(CloudFullRecoveryInput.self, from: envelope.payload),
      row.eventKey == "full-recovery-\(recovery.batchID.uuidString.lowercased())"
    else { throw SnipLibraryError.invalidStore }
    try requireValidRecovery(recovery, namespace: row.namespaceKey, batchID: recovery.batchID)
  }

  private struct RawBatchVersion: Decodable {
    let storageVersion: Int
  }

  private static func requireValidRecovery(
    _ input: CloudFullRecoveryInput, namespace: String, batchID: UUID
  ) throws {
    guard input.storageVersion == 1, input.namespaceKey == namespace, input.batchID == batchID else {
      throw SnipLibraryError.invalidStore
    }
    // Fetch/send recovery must retain its original batch evidence. Retry policy
    // belongs to the cloud normalizer; only batch identity and reset affect edits.
    switch input.kind {
    case .destructiveReset:
      throw Block.dataReset
    case .retryableFetch, .terminalFetch:
      guard try requireRawBatchAllowsWrites(input.resultData, id: batchID) == .fetched else {
        throw SnipLibraryError.invalidStore
      }
    case .retryableSend, .terminalSend:
      guard try requireRawBatchAllowsWrites(input.resultData, id: batchID) == .sent else {
        throw SnipLibraryError.invalidStore
      }
    case .malformedSentBatch, .modeRecoveredSnip, .modeRecoveredList,
      .modeDeletedListPlacement, .deletedListPlacement:
      break
    }
  }

  private struct ContentRecoveryReview: Decodable {
    let storageVersion: Int
    let conflictKey: String
    let recovery: SnipRecoveryRecord
  }

  @discardableResult
  private static func requireRawBatchAllowsWrites(_ data: Data, id: UUID) throws -> WireBatchKind {
    guard let header = try? JSONDecoder().decode(RawBatchVersion.self, from: data),
      header.storageVersion == 1,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let wireBatch = root["batch"]
    else { throw SnipLibraryError.invalidStore }
    return try requireWireBatchAllowsWrites(wireBatch, id: id)
  }

  private enum WireBatchKind: String { case fetched, sent }

  @discardableResult
  private static func requireWireBatchAllowsWrites(_ object: Any, id: UUID) throws -> WireBatchKind {
    guard let root = object as? [String: Any],
      root.count == 1, let key = root.keys.first, let kind = WireBatchKind(rawValue: key),
      let value = root[key] as? [String: Any], let batch = value["_0"] as? [String: Any],
      let rawID = batch["id"] as? String, UUID(uuidString: rawID) == id,
      batch["items"] is [Any], let events = batch["databaseEvents"] as? [Any],
      batch["zoneEvents"] is [Any]
    else { throw SnipLibraryError.invalidStore }
    for event in events { try requireDatabaseEventAllowsWrites(event) }
    return kind
  }

  private static func requireDatabaseEventAllowsWrites(_ object: Any) throws {
    guard let event = object as? [String: Any], event.count == 1,
      let kind = event.keys.first, ["zoneChanged", "zoneSaved", "zoneDeleted", "failed"].contains(kind),
      let value = event[kind] as? [String: Any]
    else { throw SnipLibraryError.invalidStore }
    guard kind == "zoneDeleted" else { return }
    guard let zone = value["_0"] as? [String: Any], zone["name"] is String,
      zone["ownerName"] is String, let reason = value["reason"] as? String,
      ["deleted", "purged", "encryptedDataReset"].contains(reason)
    else { throw SnipLibraryError.invalidStore }
    if reason != "deleted" { throw Block.dataReset }
  }
}
