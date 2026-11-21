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
    for state in try Self.cloudEngineStates(namespaceKey: key, context: context) {
      context.delete(state)
    }
    for batch in try Self.cloudStagedBatches(namespaceKey: key, context: context)
      where Self.isRetiredTextPayload(batch.payload)
    {
      context.delete(batch)
    }
    for event in try Self.cloudRecoveryEvents(namespaceKey: key, context: context)
      where Self.isRetiredTextPayload(event.payload)
    {
      context.delete(event)
    }
    let enrollments = try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
    if !enrollments.contains(where: { $0.namespaceKey == key }) {
      let snips = try context.fetch(FetchDescriptor<StoredSnipRecord>())
      let lists = try context.fetch(FetchDescriptor<StoredListRecord>())
      let references = Set(snips.map { CloudEntityReference(kind: .snip, domainID: $0.id) })
        .union(lists.map { CloudEntityReference(kind: .list, domainID: $0.id) })
        .union([CloudEntityReference(kind: .list, domainID: SnipList.inbox.id)])
      let enrollment = CloudFullEnrollmentState(
        namespaceState: CloudFullNamespaceState.notEnrolled.approvingEnrollment(),
        references: references
      )
      context.insert(StoredCloudFullEnrollment(
        namespaceKey: key, referencesData: try JSONEncoder().encode(enrollment)
      ))
    }
  }

  private static func isRetiredTextPayload(_ data: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return false
    }
    if object["marker"] as? String == "snipsnap-cloud-wire" {
      return object["format"] as? String == "legacyTextV1"
    }
    return object.count == 1 && ["fetched", "sent", "database", "zone", "modeRetryDeletion"]
      .contains { object[$0] != nil }
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

  package func clearCloudSyncState(namespaceKey: CloudSyncNamespaceKey) throws {
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
      context.delete(event)
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
      where record.namespaceKey == namespaceKey
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
