import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData


extension SwiftDataSnipLibrary {
  package func recordCloudFullRecovery(_ input: CloudFullRecoveryInput) throws {
    guard input.storageVersion == 1 else { throw CloudFullStorageError.invalidBatchReplay }
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try CloudWirePayloadEnvelope(
      format: .fullRecordV1,
      payload: encoder.encode(input)
    ).encoded()
    let eventKey = "full-recovery-\(input.batchID.uuidString.lowercased())"
    let existing = try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
      .first { $0.namespaceKey == input.namespaceKey && $0.eventKey == eventKey }
    if let existing {
      guard existing.payload == payload else { throw CloudFullStorageError.invalidBatchReplay }
      return
    }
    context.insert(
      StoredCloudRecoveryEvent(
        namespaceKey: input.namespaceKey,
        eventKey: eventKey,
        payload: payload
      )
    )
    try afterMutationBeforeSave()
    try context.save()
  }

  package func cloudFullRecoveryEvents(
    namespaceKey: CloudSyncNamespaceKey
  ) throws -> [CloudFullRecoveryInput] {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    return try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
      .filter { $0.namespaceKey == namespaceKey && $0.eventKey.hasPrefix("full-recovery-") }
      .map { event in
        guard let envelope = CloudWirePayloadEnvelope.decode(event.payload),
          envelope.format == .fullRecordV1
        else { throw CloudFullStorageError.invalidBatchReplay }
        let input = try JSONDecoder().decode(CloudFullRecoveryInput.self, from: envelope.payload)
        guard input.storageVersion == 1,
          input.namespaceKey == namespaceKey,
          event.eventKey == "full-recovery-\(input.batchID.uuidString.lowercased())"
        else { throw CloudFullStorageError.invalidBatchReplay }
        return input
      }
      .sorted { $0.batchID.uuidString < $1.batchID.uuidString }
  }

  package func stagedCloudFullBatches(
    namespaceKey: CloudSyncNamespaceKey
  ) throws -> [CloudFullBatchCommit] {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    return try context.fetch(FetchDescriptor<StoredCloudStagedBatch>())
      .filter { $0.namespaceKey == namespaceKey }
      .compactMap { record in
        guard let envelope = CloudWirePayloadEnvelope.decode(record.payload),
          envelope.format == .fullRecordV1
        else { return nil }
        let batch = try JSONDecoder().decode(CloudFullBatchCommit.self, from: envelope.payload)
        guard batch.namespaceKey == namespaceKey,
          batch.batchID == record.batchID,
          batch.storageVersion == 1
        else { throw CloudFullStorageError.invalidBatchReplay }
        return batch
      }
      .sorted { $0.batchID.uuidString < $1.batchID.uuidString }
  }

  package func stageCloudFullBatch(_ batch: CloudFullBatchCommit) throws {
    guard batch.storageVersion == 1 else { throw CloudFullStorageError.invalidBatchReplay }
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let payload = try Self.fullBatchData(batch)
    let id = "\(batch.namespaceKey)|\(batch.batchID.uuidString.lowercased())"
    let receiptID = StoredCloudFullBatchReceipt.key(
      namespaceKey: batch.namespaceKey,
      batchID: batch.batchID
    )
    if let receipt = try context.fetch(FetchDescriptor<StoredCloudFullBatchReceipt>())
      .first(where: { $0.id == receiptID })
    {
      guard receipt.digest == Self.batchReceiptDigest(batch, encoded: payload) else {
        throw CloudFullStorageError.invalidBatchReplay
      }
      return
    }
    if let current = try context.fetch(FetchDescriptor<StoredCloudStagedBatch>())
      .first(where: { $0.id == id })
    {
      guard current.payload == payload else { throw CloudFullStorageError.invalidBatchReplay }
      return
    }
    context.insert(
      StoredCloudStagedBatch(
        namespaceKey: batch.namespaceKey,
        batchID: batch.batchID,
        payload: payload
      )
    )
    try afterMutationBeforeSave()
    try context.save()
  }

  /// Replaces only an uncommitted plan for the same durable raw transport batch.
  package func replaceStagedCloudFullBatch(_ batch: CloudFullBatchCommit) throws {
    guard batch.storageVersion == 1, let raw = batch.rawBatchData else {
      throw CloudFullStorageError.invalidBatchReplay
    }
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let id = "\(batch.namespaceKey)|\(batch.batchID.uuidString.lowercased())"
    guard let current = try context.fetch(FetchDescriptor<StoredCloudStagedBatch>())
      .first(where: { $0.id == id }),
      let envelope = CloudWirePayloadEnvelope.decode(current.payload),
      envelope.format == .fullRecordV1
    else { throw CloudFullStorageError.invalidBatchReplay }
    let prior = try JSONDecoder().decode(CloudFullBatchCommit.self, from: envelope.payload)
    guard prior.rawBatchData == raw,
      try context.fetch(FetchDescriptor<StoredCloudFullBatchReceipt>())
        .allSatisfy({ $0.id != StoredCloudFullBatchReceipt.key(
          namespaceKey: batch.namespaceKey,
          batchID: batch.batchID
        ) })
    else { throw CloudFullStorageError.invalidBatchReplay }
    current.payload = try Self.fullBatchData(batch)
    try afterMutationBeforeSave()
    try context.save()
  }

  package func cloudFullStorageSnapshot(
    namespaceKey: CloudSyncNamespaceKey
  ) throws -> CloudFullStorageSnapshot {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let records = try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
      .filter { $0.namespaceKey == namespaceKey }
    let entities = try records.map(Self.entity(from:)).sorted {
      ($0.reference.kind.rawValue, $0.reference.domainID.uuidString)
        < ($1.reference.kind.rawValue, $1.reference.domainID.uuidString)
    }
    let conflicts = try context.fetch(FetchDescriptor<StoredCloudFullConflict>())
      .filter { $0.namespaceKey == namespaceKey }
      .map { record -> CloudStoredConflict in
        guard let kind = CloudEntityKind(rawValue: record.kind),
          let format = CloudConflictFormat(rawValue: record.format)
        else {
          throw SnipLibraryError.invalidStore
        }
        let prefix = "\(namespaceKey)|conflict|"
        guard record.id.hasPrefix(prefix) else { throw SnipLibraryError.invalidStore }
        return CloudStoredConflict(
          key: String(record.id.dropFirst(prefix.count)),
          reference: CloudEntityReference(kind: kind, domainID: record.domainID),
          format: format,
          payload: record.payload
        )
      }.sorted { $0.key < $1.key }
    let enrollment = try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
      .first { $0.namespaceKey == namespaceKey }
    let fullEnrollment = try Self.fullEnrollmentState(from: enrollment?.referencesData)
    let pendingDeletes = try Self.cloudPendingDeletes(
      namespaceKey: namespaceKey,
      context: context
    )
      .map { record -> CloudPendingDelete in
        guard let value = record.value else { throw SnipLibraryError.invalidStore }
        return value
      }
      .sorted {
        ($0.reference.kind.rawValue, $0.reference.domainID.uuidString)
          < ($1.reference.kind.rawValue, $1.reference.domainID.uuidString)
      }
    return CloudFullStorageSnapshot(
      readyEntities: entities.filter { !$0.isDeferred },
      deferredEntities: entities.filter(\.isDeferred),
      pendingDeletes: pendingDeletes,
      conflicts: conflicts,
      enrolledEntities: fullEnrollment.references,
      quarantines: try Self.quarantines(namespaceKey: namespaceKey, context: context),
      namespaceState: fullEnrollment.namespaceState
    )
  }

  package func stageCloudPendingDeletes(
    namespaceKey: CloudSyncNamespaceKey,
    values: [CloudPendingDelete]
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard values.allSatisfy({ $0.storageVersion == 1 }) else {
      throw CloudFullStorageError.invalidBatchReplay
    }
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let current = try Self.cloudPendingDeletes(namespaceKey: namespaceKey, context: context)
    var byDomain = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    var domainByIdentity = Dictionary(uniqueKeysWithValues: current.map { ($0.identityID, $0.id) })
    for value in values {
      let domainKey = StoredCloudPendingDelete.domainKey(
        namespaceKey: namespaceKey,
        reference: value.reference
      )
      let identityKey = StoredCloudPendingDelete.identityKey(
        namespaceKey: namespaceKey,
        identity: value.identity
      )
      if let existing = byDomain[domainKey] {
        guard existing.identityID == identityKey else {
          throw CloudFullStorageError.invalidBatchReplay
        }
        continue
      }
      guard domainByIdentity[identityKey] == nil else {
        throw CloudFullStorageError.invalidBatchReplay
      }
      let record = StoredCloudPendingDelete(namespaceKey: namespaceKey, value: value)
      context.insert(record)
      byDomain[domainKey] = record
      domainByIdentity[identityKey] = domainKey
    }
    guard !values.isEmpty else { return }
    try afterMutationBeforeSave()
    try context.save()
  }

  package func clearCloudFullRecoveryEvents(
    namespaceKey: CloudSyncNamespaceKey,
    keys: Set<String>
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    for event in try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
      where event.namespaceKey == namespaceKey && keys.contains(event.eventKey)
    {
      context.delete(event)
    }
    try afterMutationBeforeSave()
    try context.save()
  }

  static func cloudPendingDeletes(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredCloudPendingDelete] {
    let key = namespaceKey
    return try context.fetch(
      FetchDescriptor(predicate: #Predicate<StoredCloudPendingDelete> { $0.namespaceKey == key })
    )
  }

  package func setCloudEnrollment(
    namespaceKey: CloudSyncNamespaceKey,
    references: Set<CloudEntityReference>,
    localDependencies: [UUID: UUID] = [:]
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let snips = references.filter { $0.kind == .snip }
    let entities = try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
      .filter { $0.namespaceKey == namespaceKey }
    var dependencies = Dictionary(uniqueKeysWithValues: entities.compactMap { entity in
      entity.kind == CloudEntityKind.snip.rawValue
        ? entity.dependencyListID.map { (entity.domainID, $0) }
        : nil
    })
    dependencies.merge(localDependencies) { _, supplied in supplied }
    guard snips.allSatisfy({ snip in
      dependencies[snip.domainID].map {
        references.contains(CloudEntityReference(kind: .list, domainID: $0))
      } ?? false
    }) else { throw CloudFullStorageError.invalidEnrollment }

    let current = try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
      .first(where: { $0.namespaceKey == namespaceKey })
    let prior = try Self.fullEnrollmentState(from: current?.referencesData)
    let phase: CloudNamespaceBootstrapPhase = prior.namespaceState.phase == .active
      ? .active : .seeding
    let state = CloudFullNamespaceState(
      revision: prior.namespaceState.revision + 1,
      phase: phase,
      zoneCreationPending: prior.namespaceState.phase == .remoteCheckedMissingZone
        || prior.namespaceState.zoneCreationPending
    )
    let data = try JSONEncoder().encode(
      CloudFullEnrollmentState(namespaceState: state, references: references)
    )
    if let current {
      current.referencesData = data
    } else {
      context.insert(StoredCloudFullEnrollment(namespaceKey: namespaceKey, referencesData: data))
    }
    try afterMutationBeforeSave()
    try context.save()
  }

  package func storeDormantCloudBase(
    namespaceKey: CloudSyncNamespaceKey,
    reference: CloudEntityReference,
    identity: CloudTextStorageIdentity,
    payload: Data
  ) throws {
    let rawNamespaceKey = namespaceKey.rawValue
    try storeDormantCloudBases(
      namespaceKey: namespaceKey,
      bases: [CloudDormantBase(
        namespaceKey: rawNamespaceKey,
        reference: reference,
        identity: identity,
        payload: payload
      )]
    )
  }

  package func storeDormantCloudBases(
    namespaceKey: CloudSyncNamespaceKey,
    bases: [CloudDormantBase],
    afterStagingFirst: @Sendable () throws -> Void = {}
  ) throws {
    let namespaceKey = namespaceKey.rawValue
    guard bases.allSatisfy({ $0.namespaceKey == namespaceKey }) else {
      throw CloudFullStorageError.invalidBatchReplay
    }
    _ = try CloudDormantAcceptedBaseBundle(entries: bases.map { base in
      CloudDormantAcceptedBaseBundle.Entry(
        namespaceKey: base.namespaceKey,
        reference: base.reference,
        identity: base.identity,
        payload: base.payload
      )
    })
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let records = try context.fetch(FetchDescriptor<StoredCloudDormantBaseRecord>())
    let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    var recordIDByIdentity: [String: String] = [:]
    for record in records {
      guard recordIDByIdentity.updateValue(record.id, forKey: record.identityID) == nil else {
        throw CloudFullStorageError.duplicateDormantBinding
      }
    }
    let prepared = try bases.map { base -> (CloudDormantBase, String, String) in
      let id = StoredCloudDormantBaseRecord.key(
        namespaceKey: namespaceKey,
        reference: base.reference
      )
      let identityID = StoredCloudDormantBaseRecord.identityKey(
        namespaceKey: namespaceKey,
        identity: base.identity
      )
      if let current = recordsByID[id], current.identityID != identityID {
        throw CloudFullStorageError.duplicateDormantBinding
      }
      if let boundID = recordIDByIdentity[identityID], boundID != id {
        throw CloudFullStorageError.duplicateDormantBinding
      }
      return (base, id, identityID)
    }
    do {
      for (index, value) in prepared.enumerated() {
        let (base, id, _) = value
        if let current = recordsByID[id] {
          current.zoneName = base.identity.zoneName
          current.ownerName = base.identity.ownerName
          current.recordName = base.identity.recordName
          current.payload = base.payload
        } else {
          context.insert(StoredCloudDormantBaseRecord(
            namespaceKey: namespaceKey,
            reference: base.reference,
            identity: base.identity,
            payload: base.payload
          ))
        }
        if index == 0, prepared.count > 1 {
          try afterStagingFirst()
        }
      }
      try afterMutationBeforeSave()
      try context.save()
    } catch {
      context.rollback()
      throw error
    }
  }

  package func dormantCloudBases() throws -> [CloudDormantBase] {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    return try context.fetch(FetchDescriptor<StoredCloudDormantBaseRecord>()).map { record in
      guard let kind = CloudEntityKind(rawValue: record.kind) else {
        throw SnipLibraryError.invalidStore
      }
      return CloudDormantBase(
        namespaceKey: record.namespaceKey,
        reference: CloudEntityReference(kind: kind, domainID: record.domainID),
        identity: CloudTextStorageIdentity(
          zoneName: record.zoneName,
          ownerName: record.ownerName,
          recordName: record.recordName
        ),
        payload: record.payload
      )
    }.sorted {
      ($0.namespaceKey, $0.reference.kind.rawValue, $0.reference.domainID.uuidString)
        < ($1.namespaceKey, $1.reference.kind.rawValue, $1.reference.domainID.uuidString)
    }
  }

}
