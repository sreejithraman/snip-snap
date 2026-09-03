import Foundation
import SnipSnapCore
import SwiftData

extension SwiftDataSnipLibrary {
  package func acceptedCloudTextSnipIDs() throws -> Set<UUID> {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let records = try context.fetch(FetchDescriptor<StoredCloudTextRecord>())
    return Set(
      records.compactMap { record in
        record.acceptedText != nil || record.shadowData != nil || record.systemFields != nil
          ? record.snipID
          : nil
      }
    )
  }

  package func acceptedCloudTextValues() throws -> [UUID: String] {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    var values: [UUID: String] = [:]
    for record in try context.fetch(FetchDescriptor<StoredCloudTextRecord>()) {
      guard let text = record.acceptedText else { continue }
      guard values[record.snipID] == nil else { throw SnipLibraryError.invalidStore }
      values[record.snipID] = text
    }
    return values
  }

  package func cloudTextSyncSnapshot(
    namespaceKey: CloudSyncNamespaceKey
  ) throws -> CloudTextStorageSnapshot {
    let namespaceKey = namespaceKey.rawValue
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let loaded = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
    let records = try Self.cloudTextRecords(namespaceKey: namespaceKey, context: context)
      .map {
        CloudTextStorageRecord(
          identity: $0.identity,
          snipID: $0.snipID,
          schemaVersion: $0.schemaVersion,
          acceptedText: $0.acceptedText,
          shadowData: $0.shadowData,
          systemFields: $0.systemFields,
          recoveryData: $0.recoveryData
        )
      }
    let engineState = try Self.cloudEngineStates(namespaceKey: namespaceKey, context: context)
      .first?.envelopeData
    let stagedBatches = try Self.cloudStagedBatches(namespaceKey: namespaceKey, context: context)
      .map { CloudStagedBatchStorage(id: $0.batchID, payload: $0.payload) }
    let recoveryEvents = try Self.cloudRecoveryEvents(namespaceKey: namespaceKey, context: context)
      .map { CloudRecoveryEventStorage(key: $0.eventKey, payload: $0.payload) }
    let namespaceState = try Self.cloudNamespaceStates(namespaceKey: namespaceKey, context: context)
      .first
      .map { try $0.value() }
      ?? .notEnrolled
    return CloudTextStorageSnapshot(
      snips: loaded.state.snips,
      records: records,
      namespaceState: namespaceState,
      engineState: engineState,
      stagedBatches: stagedBatches,
      recoveryEvents: recoveryEvents
    )
  }

  package func saveCloudEngineState(
    namespaceKey: CloudSyncNamespaceKey,
    envelopeData: Data
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    try Self.replaceCloudEngineState(
      namespaceKey: namespaceKey,
      envelopeData: envelopeData,
      context: context
    )
    try context.save()
  }

  package func clearCloudEngineState(namespaceKey: CloudSyncNamespaceKey) throws {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    for state in try Self.cloudEngineStates(
      namespaceKey: namespaceKey.rawValue,
      context: context
    ) {
      context.delete(state)
    }
    try afterMutationBeforeSave()
    try context.save()
  }

  package func stageCloudTextBatch(
    namespaceKey: CloudSyncNamespaceKey,
    batchID: UUID,
    payload: Data
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let batches = try Self.cloudStagedBatches(namespaceKey: namespaceKey, context: context)
    if let existing = batches.first(where: { $0.batchID == batchID }) {
      guard existing.payload == payload else { throw SnipLibraryError.invalidStore }
      return
    }
    context.insert(
      StoredCloudStagedBatch(namespaceKey: namespaceKey, batchID: batchID, payload: payload)
    )
    try context.save()
  }

  package func reserveCloudTextRecords(
    namespaceKey: CloudSyncNamespaceKey,
    reservations: [CloudTextRecordReservation]
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard !reservations.isEmpty else { return }
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let records = try Self.cloudTextRecords(namespaceKey: namespaceKey, context: context)
    var bySnipID = Dictionary(uniqueKeysWithValues: records.map { ($0.snipID, $0) })
    var identities = Set(records.map(\.identity))
    for reservation in reservations {
      if let existing = bySnipID[reservation.snipID] {
        guard existing.identity == reservation.identity else {
          throw SnipLibraryError.invalidStore
        }
        continue
      }
      guard identities.insert(reservation.identity).inserted else {
        throw SnipLibraryError.invalidStore
      }
      let record = StoredCloudTextRecord(
        namespaceKey: namespaceKey,
        identity: reservation.identity,
        snipID: reservation.snipID
      )
      context.insert(record)
      bySnipID[reservation.snipID] = record
    }
    try afterMutationBeforeSave()
    try context.save()
  }

  package func transitionCloudTextNamespace(
    namespaceKey: CloudSyncNamespaceKey,
    expectedPhase: CloudNamespaceBootstrapPhase,
    value: CloudNamespaceStateStorage
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let states = try Self.cloudNamespaceStates(namespaceKey: namespaceKey, context: context)
    let existing = states.first
    let current = try existing?.value() ?? .notEnrolled
    guard current.phase == expectedPhase else { throw SnipLibraryError.invalidStore }
    if let existing {
      try existing.replace(with: value)
    } else {
      context.insert(try StoredCloudNamespaceState(namespaceKey: namespaceKey, value: value))
    }
    try afterMutationBeforeSave()
    try context.save()
  }

  package func discardUnacceptedCloudTextRecords(
    namespaceKey: CloudSyncNamespaceKey,
    liveSnipIDs: Set<UUID>
  ) throws -> Bool {
    let namespaceKey = namespaceKey.rawValue
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let records = try Self.cloudTextRecords(namespaceKey: namespaceKey, context: context)
      .filter { record in
        !liveSnipIDs.contains(record.snipID)
          && record.acceptedText == nil
          && record.shadowData == nil
          && record.systemFields == nil
          && record.recoveryData == nil
      }
    guard !records.isEmpty else { return false }
    for record in records { context.delete(record) }
    try afterMutationBeforeSave()
    try context.save()
    return true
  }

  package func applyCloudTextFetched(
    namespaceKey: CloudSyncNamespaceKey,
    mutations: [CloudTextFetchedMutation],
    recoveryEvents: [CloudRecoveryEventStorage],
    engineState: Data?,
    namespaceState: CloudNamespaceStateStorage?,
    stagedBatchID: UUID
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let loaded = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
    let cloudRecords = try Self.cloudTextRecords(namespaceKey: namespaceKey, context: context)
    var cloudByIdentity = Dictionary(
      uniqueKeysWithValues: cloudRecords.map { ($0.identity, $0) }
    )
    let storedSnips = Dictionary(uniqueKeysWithValues: loaded.snips.map { ($0.id, $0) })
    for mutation in mutations {
      switch mutation.local {
      case .insert(let snip):
        guard storedSnips[snip.id] == nil else { throw SnipLibraryError.invalidStore }
      case .replace(let id, let expectedText, _, _),
           .keep(let id, let expectedText),
           .delete(let id, let expectedText):
        guard storedSnips[id]?.content == expectedText else {
          throw SnipLibraryError.invalidStore
        }
      case .requireMissing(let id):
        guard storedSnips[id] == nil else { throw SnipLibraryError.invalidStore }
      case .none:
        break
      }
    }
    var deletedSnipIDs: Set<UUID> = []
    var candidateAttachmentIDs: Set<UUID> = []
    for mutation in mutations {
      Self.applyCloudTextRecordMutation(
        mutation.record,
        namespaceKey: namespaceKey,
        records: &cloudByIdentity,
        context: context
      )
      switch mutation.local {
      case .insert(let snip):
        context.insert(StoredSnipRecord(snip))
        context.insert(StoredRequestRecord(id: snip.requestID))
      case .replace(let id, _, let text, let updatedAt):
        guard let snip = storedSnips[id] else { throw SnipLibraryError.invalidStore }
        snip.content = text
        snip.updatedAt = updatedAt
      case .delete(let id, _):
        guard let snip = storedSnips[id] else { throw SnipLibraryError.invalidStore }
        context.delete(snip)
        deletedSnipIDs.insert(id)
        for reference in loaded.references where reference.snipID == id {
          candidateAttachmentIDs.insert(reference.attachmentID)
          context.delete(reference)
        }
      case .keep, .requireMissing, .none:
        break
      }
    }
    let retainedAttachmentIDs = Set(
      loaded.references
        .filter { !deletedSnipIDs.contains($0.snipID) }
        .map(\.attachmentID)
    )
    for attachment in loaded.attachments
      where candidateAttachmentIDs.contains(attachment.id)
        && !retainedAttachmentIDs.contains(attachment.id)
    {
      context.delete(attachment)
    }
    try Self.upsertRecoveryEvents(
      namespaceKey: namespaceKey,
      values: recoveryEvents,
      context: context
    )
    try Self.replaceCloudEngineState(
      namespaceKey: namespaceKey,
      envelopeData: engineState,
      context: context
    )
    try Self.replaceCloudNamespaceState(
      namespaceKey: namespaceKey,
      value: namespaceState,
      context: context
    )
    try Self.deleteStagedBatch(
      namespaceKey: namespaceKey,
      batchID: stagedBatchID,
      context: context
    )
    do {
      try afterMutationBeforeSave()
      try context.save()
    } catch {
      context.rollback()
      throw error
    }
    let refreshed = try Self.load(
      context: Self.makeContext(container: container),
      seenRequestIDs: seenRequestIDs
    )
    seenRequestIDs = refreshed.state.seenRequestIDs
    lastKnownState = refreshed.state
    let liveAttachmentIDs = Set(refreshed.state.snips.flatMap(\.attachments).map(\.id))
    Self.removeUnreferencedAttachmentDirectories(
      at: attachmentRootURL,
      keeping: Set(refreshed.state.snips.flatMap(\.attachments).map(\.relativePath))
    )
    knownAttachmentPaths = knownAttachmentPaths.filter { liveAttachmentIDs.contains($0.key) }
    rememberAttachments(in: refreshed.state)
  }

  package func applyCloudTextSent(
    namespaceKey: CloudSyncNamespaceKey,
    mutations: [CloudTextRecordMutation],
    recoveryEvents: [CloudRecoveryEventStorage],
    engineState: Data?,
    namespaceState: CloudNamespaceStateStorage?,
    stagedBatchID: UUID
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let cloudRecords = try Self.cloudTextRecords(namespaceKey: namespaceKey, context: context)
    var cloudByIdentity = Dictionary(
      uniqueKeysWithValues: cloudRecords.map { ($0.identity, $0) }
    )
    for mutation in mutations {
      Self.applyCloudTextRecordMutation(
        mutation,
        namespaceKey: namespaceKey,
        records: &cloudByIdentity,
        context: context
      )
    }
    try Self.upsertRecoveryEvents(
      namespaceKey: namespaceKey,
      values: recoveryEvents,
      context: context
    )
    try Self.replaceCloudEngineState(
      namespaceKey: namespaceKey,
      envelopeData: engineState,
      context: context
    )
    try Self.replaceCloudNamespaceState(
      namespaceKey: namespaceKey,
      value: namespaceState,
      context: context
    )
    try Self.deleteStagedBatch(
      namespaceKey: namespaceKey,
      batchID: stagedBatchID,
      context: context
    )
    do {
      try afterMutationBeforeSave()
      try context.save()
    } catch {
      context.rollback()
      throw error
    }
  }

  package func clearCloudTextSyncState(namespaceKey: CloudSyncNamespaceKey) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    for record in try Self.cloudTextRecords(namespaceKey: namespaceKey, context: context) {
      context.delete(record)
    }
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
    try context.save()
  }

  package func removeCloudTextRecoveryEvents(
    namespaceKey: CloudSyncNamespaceKey,
    keys: Set<String>
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard !keys.isEmpty else { return }
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    for event in try Self.cloudRecoveryEvents(namespaceKey: namespaceKey, context: context)
      where keys.contains(event.eventKey)
    {
      context.delete(event)
    }
    try afterMutationBeforeSave()
    try context.save()
  }

  package func prepareCloudTextModeRetry(
    namespaceKey: CloudSyncNamespaceKey,
    supersededSnipIDs: Set<UUID>,
    liveSnipIDs: Set<UUID>,
    deletionRecoveryData: Data
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard !supersededSnipIDs.isEmpty else { return }
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    for record in try Self.cloudTextRecords(namespaceKey: namespaceKey, context: context)
      where supersededSnipIDs.contains(record.snipID)
    {
      if liveSnipIDs.contains(record.snipID) {
        record.recoveryData = nil
      } else if record.acceptedText != nil || record.shadowData != nil || record.systemFields != nil {
        record.recoveryData = deletionRecoveryData
      } else {
        context.delete(record)
      }
    }
    try afterMutationBeforeSave()
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

  private static func replaceCloudNamespaceState(
    namespaceKey: String,
    value: CloudNamespaceStateStorage?,
    context: ModelContext
  ) throws {
    guard let value else { return }
    let states = try Self.cloudNamespaceStates(namespaceKey: namespaceKey, context: context)
    if let existing = states.first {
      try existing.replace(with: value)
    } else {
      context.insert(try StoredCloudNamespaceState(namespaceKey: namespaceKey, value: value))
    }
  }

  private static func applyCloudTextRecordMutation(
    _ mutation: CloudTextRecordMutation,
    namespaceKey: String,
    records: inout [CloudTextStorageIdentity: StoredCloudTextRecord],
    context: ModelContext
  ) {
    switch mutation {
    case .accept(let value):
      _ = upsertCloudTextRecord(
        namespaceKey: namespaceKey,
        value: value,
        records: &records,
        context: context
      )
    case .acceptAndRecover(let value, let recoveryData):
      let record = upsertCloudTextRecord(
        namespaceKey: namespaceKey,
        value: value,
        records: &records,
        context: context
      )
      record.recoveryData = recoveryData
    case .clearAndRecover(let identity, let recoveryData):
      guard let record = records[identity] else { return }
      record.acceptedText = nil
      record.shadowData = nil
      record.systemFields = nil
      record.recoveryData = recoveryData
    case .recover(let identity, let recoveryData):
      records[identity]?.recoveryData = recoveryData
    case .remove(let identity):
      guard let record = records.removeValue(forKey: identity) else { return }
      context.delete(record)
    }
  }

  private static func upsertCloudTextRecord(
    namespaceKey: String,
    value: CloudTextFetchedValue,
    records: inout [CloudTextStorageIdentity: StoredCloudTextRecord],
    context: ModelContext
  ) -> StoredCloudTextRecord {
    let record: StoredCloudTextRecord
    if let existing = records[value.identity] {
      record = existing
    } else {
      record = StoredCloudTextRecord(
        namespaceKey: namespaceKey,
        identity: value.identity,
        snipID: value.snipID
      )
      context.insert(record)
      records[value.identity] = record
    }
    record.accept(value)
    return record
  }

  private static func upsertRecoveryEvents(
    namespaceKey: String,
    values: [CloudRecoveryEventStorage],
    context: ModelContext
  ) throws {
    let existing = try Self.cloudRecoveryEvents(namespaceKey: namespaceKey, context: context)
    var byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.eventKey, $0) })
    for value in values {
      if let record = byKey[value.key] {
        record.payload = value.payload
      } else {
        let record = StoredCloudRecoveryEvent(
          namespaceKey: namespaceKey,
          eventKey: value.key,
          payload: value.payload
        )
        context.insert(record)
        byKey[value.key] = record
      }
    }
  }

  private static func deleteStagedBatch(
    namespaceKey: String,
    batchID: UUID,
    context: ModelContext
  ) throws {
    guard let batch = try Self.cloudStagedBatches(namespaceKey: namespaceKey, context: context)
      .first(where: { $0.batchID == batchID })
    else {
      throw SnipLibraryError.invalidStore
    }
    context.delete(batch)
  }

  private static func cloudTextRecords(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredCloudTextRecord] {
    let key = namespaceKey
    return try context.fetch(
      FetchDescriptor(predicate: #Predicate<StoredCloudTextRecord> { $0.namespaceKey == key })
    )
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
