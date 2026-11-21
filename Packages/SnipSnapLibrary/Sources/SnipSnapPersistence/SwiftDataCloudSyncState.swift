import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  // Kept for package callers that inspect transport checkpoints and staged batches.
  package func cloudTextSyncSnapshot(
    namespaceKey: CloudSyncNamespaceKey
  ) throws -> (engineState: Data?, stagedBatches: [CloudStagedBatchStorage]) {
    let key = namespaceKey.rawValue
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let engine = try Self.cloudEngineStates(namespaceKey: key, context: context).first?.envelopeData
    let batches = try Self.cloudStagedBatches(namespaceKey: key, context: context)
      .map { CloudStagedBatchStorage(id: $0.batchID, payload: $0.payload) }
    return (engine, batches)
  }

  package func saveCloudEngineState(
    namespaceKey: CloudSyncNamespaceKey,
    envelopeData: Data,
    startsFullRecordInitialFetch: Bool = false
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    if startsFullRecordInitialFetch,
      try Self.cloudEngineStates(namespaceKey: namespaceKey, context: context).isEmpty
    {
      try Self.startFullFetchInventory(namespaceKey: namespaceKey, reset: false, context: context)
    }
    try Self.replaceCloudEngineState(
      namespaceKey: namespaceKey,
      envelopeData: envelopeData,
      context: context
    )
    try lock.check()
    try context.save()
  }

  /// Retire transport state while keeping all local content and full-record shadows.
  static func resetRetiredTextSync(namespaceKey: CloudSyncNamespaceKey, context: ModelContext) throws {
    let key = namespaceKey.rawValue
    let batches = try Self.cloudStagedBatches(namespaceKey: key, context: context)
    let events = try Self.cloudRecoveryEvents(namespaceKey: key, context: context)
    let legacyBatches = batches.compactMap { row in retiredTextPayload(row.payload).map { (row, $0) } }
    let legacyEvents = events.compactMap { row in retiredTextPayload(row.payload).map { (row, $0) } }
    let reset = try Self.cloudNamespaceStates(namespaceKey: key, context: context)
      .contains { $0.phase == CloudNamespaceBootstrapPhase.blocked.rawValue }
      || legacyBatches.contains { hasRetiredReset($0.1) }
      || legacyEvents.contains { hasRetiredReset($0.1) }
    let enrollment = try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
      .first { $0.namespaceKey == key }

    // A full-record batch and its checkpoint must survive together for replay.
    if batches.count == legacyBatches.count {
      for state in try Self.cloudEngineStates(namespaceKey: key, context: context) {
        context.delete(state)
      }
    }
    for (batch, _) in legacyBatches { context.delete(batch) }
    for (event, _) in legacyEvents { context.delete(event) }

    if let enrollment {
      if reset {
        let prior = try Self.fullEnrollmentState(from: enrollment.referencesData)
        enrollment.referencesData = try JSONEncoder().encode(CloudFullEnrollmentState(
          namespaceState: prior.namespaceState.committingSend(.destructiveReset),
          references: prior.references
        ))
      }
      return
    }
    let snips = try context.fetch(FetchDescriptor<StoredSnipRecord>())
    let lists = try context.fetch(FetchDescriptor<StoredListRecord>())
    let references = Set(snips.map { CloudEntityReference(kind: .snip, domainID: $0.id) })
      .union(lists.map { CloudEntityReference(kind: .list, domainID: $0.id) })
      .union([CloudEntityReference(kind: .list, domainID: SnipList.inbox.id)])
    let initial = CloudFullNamespaceState.notEnrolled.approvingEnrollment()
    let seeded = CloudFullEnrollmentState(
      namespaceState: reset ? initial.committingSend(.destructiveReset) : initial,
      references: references
    )
    context.insert(StoredCloudFullEnrollment(
      namespaceKey: key, referencesData: try JSONEncoder().encode(seeded)
    ))
  }

  private static func retiredTextPayload(_ data: Data) -> [String: Any]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    if object["marker"] as? String == "snipsnap-cloud-wire" {
      guard object["format"] as? String == "legacyTextV1" else { return nil }
      let payload = (object["payload"] as? String).flatMap { Data(base64Encoded: $0) }
      return payload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    guard object.count == 1,
      ["fetched", "sent", "database", "zone", "modeRetryDeletion"].contains(where: { object[$0] != nil })
    else { return nil }
    return object
  }

  private static func hasRetiredReset(_ payload: [String: Any]) -> Bool {
    let events: [[String: Any]]
    if let event = (payload["database"] as? [String: Any])?["_0"] as? [String: Any] {
      events = [event]
    } else {
      let batch = (payload["fetched"] ?? payload["sent"]) as? [String: Any]
      events = (batch?["_0"] as? [String: Any])?["databaseEvents"] as? [[String: Any]] ?? []
    }
    return events.contains {
      let reason = ($0["zoneDeleted"] as? [String: Any])?["reason"] as? String
      return reason == "purged" || reason == "encryptedDataReset"
    }
  }

  package func clearCloudEngineState(
    namespaceKey: CloudSyncNamespaceKey,
    resetsFullRecordInitialFetch: Bool = false
  ) throws {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    if resetsFullRecordInitialFetch {
      try Self.startFullFetchInventory(namespaceKey: namespaceKey.rawValue, reset: true, context: context)
    }
    for state in try Self.cloudEngineStates(
      namespaceKey: namespaceKey.rawValue,
      context: context
    ) {
      context.delete(state)
    }
    try afterMutationBeforeSave()
    try lock.check()
    try context.save()
  }

  package func clearCloudSyncState(
    namespaceKey: CloudSyncNamespaceKey, afterReset: Bool = false
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    for state in try Self.cloudEngineStates(namespaceKey: namespaceKey, context: context) {
      context.delete(state)
    }
    for batch in try Self.cloudStagedBatches(namespaceKey: namespaceKey, context: context) {
      context.delete(batch)
    }
    for event in try Self.cloudRecoveryEvents(namespaceKey: namespaceKey, context: context) {
      if !afterReset || !event.eventKey.hasPrefix(Self.recoveryReviewPrefix) { context.delete(event) }
    }
    for state in try Self.cloudNamespaceStates(namespaceKey: namespaceKey, context: context) {
      context.delete(state)
    }
    for record in try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
      where record.namespaceKey == namespaceKey
    {
      context.delete(record)
    }
    for record in try context.fetch(FetchDescriptor<StoredCloudFullConflict>())
      where record.namespaceKey == namespaceKey && !afterReset
    {
      context.delete(record)
    }
    for record in try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
      where record.namespaceKey == namespaceKey
    {
      context.delete(record)
    }
    for record in try context.fetch(FetchDescriptor<StoredCloudDormantBaseRecord>())
      where record.namespaceKey == namespaceKey
    {
      context.delete(record)
    }
    for record in try context.fetch(FetchDescriptor<StoredCloudMappingQuarantine>())
      where record.namespaceKey == namespaceKey
    {
      context.delete(record)
    }
    for record in try context.fetch(FetchDescriptor<StoredCloudFullBatchReceipt>())
      where record.namespaceKey == namespaceKey
    {
      context.delete(record)
    }
    for record in try Self.cloudPendingDeletes(namespaceKey: namespaceKey, context: context) {
      context.delete(record)
    }
    if afterReset {
      for row in try Self.cloudAttachmentPublications(namespaceKey: namespaceKey, context: context) {
        context.delete(row)
      }
      for row in try Self.cloudAttachmentCleanups(namespaceKey: namespaceKey, context: context) {
        context.delete(row)
      }
      for row in try Self.cloudAttachmentCacheEntries(namespaceKey: namespaceKey, context: context) {
        context.delete(row)
      }
      for row in try context.fetch(FetchDescriptor<StoredCloudTextRecord>())
        where row.namespaceKey == namespaceKey { context.delete(row) }
    }
    guard context.hasChanges else { return }
    try afterMutationBeforeSave()
    try lock.check()
    try context.save()
  }

  private static func replaceCloudEngineState(
    namespaceKey: String,
    envelopeData: Data?,
    context: ModelContext
  ) throws {
    let states = try Self.cloudEngineStates(namespaceKey: namespaceKey, context: context)
    let existing = states.first
    guard let envelopeData else { return }
    if let existing {
      existing.envelopeData = envelopeData
    } else {
      context.insert(
        StoredCloudEngineState(namespaceKey: namespaceKey, envelopeData: envelopeData)
      )
    }
  }

  private static func cloudEngineStates(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredCloudEngineState] {
    let key = namespaceKey
    return try context.fetch(
      FetchDescriptor(predicate: #Predicate<StoredCloudEngineState> { $0.namespaceKey == key })
    )
  }

  private static func cloudStagedBatches(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredCloudStagedBatch] {
    let key = namespaceKey
    return try context.fetch(
      FetchDescriptor(predicate: #Predicate<StoredCloudStagedBatch> { $0.namespaceKey == key })
    )
  }

  private static func cloudRecoveryEvents(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredCloudRecoveryEvent] {
    let key = namespaceKey
    return try context.fetch(
      FetchDescriptor(predicate: #Predicate<StoredCloudRecoveryEvent> { $0.namespaceKey == key })
    )
  }

  private static func cloudNamespaceStates(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredCloudNamespaceState] {
    let key = namespaceKey
    return try context.fetch(
      FetchDescriptor(predicate: #Predicate<StoredCloudNamespaceState> { $0.namespaceKey == key })
    )
  }

}
