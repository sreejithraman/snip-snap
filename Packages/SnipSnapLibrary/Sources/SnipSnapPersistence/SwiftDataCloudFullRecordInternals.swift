import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData


extension SwiftDataSnipLibrary {
static func entity(from record: StoredCloudEntityRecord) throws -> CloudAcceptedEntity {
    guard let reference = record.reference else { throw SnipLibraryError.invalidStore }
    return CloudAcceptedEntity(
      reference: reference,
      identity: record.identity,
      schemaVersion: record.schemaVersion,
      acceptedData: record.acceptedData,
      presenceData: record.presenceData,
      shadowData: record.shadowData,
      systemFields: record.systemFields,
      dependencyListID: record.dependencyListID,
      isDeferred: record.isDeferred,
      localRevision: record.localRevision
    )
  }

  static func insertConflictIfNeeded(
    _ value: CloudConflictInput,
    namespaceKey: String,
    context: ModelContext
  ) throws {
    let id = StoredCloudFullConflict.key(namespaceKey: namespaceKey, conflictKey: value.key)
    if let current = try context.fetch(FetchDescriptor<StoredCloudFullConflict>())
      .first(where: { $0.id == id })
    {
      guard current.kind == value.reference.kind.rawValue,
        current.domainID == value.reference.domainID,
        current.format == value.format.rawValue,
        current.payload == value.payload
      else { throw CloudFullStorageError.invalidConflictReplay }
      if let recovery = value.recovery {
        try insertRecoveryReviewIfNeeded(
          recovery,
          namespaceKey: namespaceKey,
          conflictKey: value.key,
          context: context
        )
      }
      return
    }
    context.insert(
      StoredCloudFullConflict(
        namespaceKey: namespaceKey,
        key: value.key,
        reference: value.reference,
        format: value.format,
        payload: value.payload
      )
    )
    if let recovery = value.recovery {
      try insertRecoveryReviewIfNeeded(
        recovery,
        namespaceKey: namespaceKey,
        conflictKey: value.key,
        context: context
      )
    }
  }

  static func quarantines(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [CloudStoredQuarantine] {
    try context.fetch(FetchDescriptor<StoredCloudMappingQuarantine>())
      .filter { $0.namespaceKey == namespaceKey }
      .map { record in
        guard let kind = CloudEntityKind(rawValue: record.kind),
          let format = CloudConflictFormat(rawValue: record.format)
        else {
          throw SnipLibraryError.invalidStore
        }
        let prefix = "\(namespaceKey)|quarantine|"
        guard record.id.hasPrefix(prefix) else { throw SnipLibraryError.invalidStore }
        return CloudStoredQuarantine(
          key: String(record.id.dropFirst(prefix.count)),
          reference: CloudEntityReference(kind: kind, domainID: record.domainID),
          identity: CloudTextStorageIdentity(
            zoneName: record.zoneName,
            ownerName: record.ownerName,
            recordName: record.recordName
          ),
          format: format,
          payload: record.payload
        )
      }.sorted { $0.key < $1.key }
  }

  static func insertQuarantineIfNeeded(
    _ value: CloudQuarantineInput,
    namespaceKey: String,
    context: ModelContext
  ) throws {
    let id = StoredCloudMappingQuarantine.key(namespaceKey: namespaceKey, key: value.key)
    if let current = try context.fetch(FetchDescriptor<StoredCloudMappingQuarantine>())
      .first(where: { $0.id == id })
    {
      guard current.kind == value.reference.kind.rawValue,
        current.domainID == value.reference.domainID,
        current.zoneName == value.identity.zoneName,
        current.ownerName == value.identity.ownerName,
        current.recordName == value.identity.recordName,
        current.format == value.format.rawValue,
        current.payload == value.payload
      else { throw CloudFullStorageError.invalidConflictReplay }
      return
    }
    context.insert(StoredCloudMappingQuarantine(namespaceKey: namespaceKey, value: value))
  }

  static func fullEnrollmentState(
    from data: Data?
  ) throws -> CloudFullEnrollmentState {
    guard let data else {
      return CloudFullEnrollmentState(namespaceState: .notEnrolled, references: [])
    }
    if let value = try? JSONDecoder().decode(CloudFullEnrollmentState.self, from: data) {
      guard value.storageVersion == 1, value.namespaceState.storageVersion == 1 else {
        throw SnipLibraryError.invalidStore
      }
      return value
    }
    let references = try JSONDecoder().decode(Set<CloudEntityReference>.self, from: data)
    return CloudFullEnrollmentState(
      namespaceState: CloudFullNamespaceState(
        revision: 0,
        phase: references.isEmpty ? .notEnrolled : .active
      ),
      references: references
    )
  }

  static func insertFullRecoveryIfNeeded(
    _ input: CloudFullRecoveryInput,
    context: ModelContext
  ) throws {
    let eventKey = "full-recovery-\(input.batchID.uuidString.lowercased())"
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try CloudWirePayloadEnvelope(
      format: .fullRecordV1,
      payload: encoder.encode(input)
    ).encoded()
    if let current = try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
      .first(where: {
        $0.namespaceKey == input.namespaceKey && $0.eventKey == eventKey
      })
    {
      guard current.payload == payload else { throw CloudFullStorageError.invalidBatchReplay }
      return
    }
    context.insert(
      StoredCloudRecoveryEvent(
        namespaceKey: input.namespaceKey,
        eventKey: eventKey,
        payload: payload
      )
    )
  }

  static func fullBatchData(_ value: CloudFullBatchCommit) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(value)
    return try CloudWirePayloadEnvelope(format: .fullRecordV1, payload: payload).encoded()
  }

  static func batchReceiptDigest(
    _ value: CloudFullBatchCommit,
    encoded: Data
  ) -> Data {
    Data(SHA256.hash(data: value.rawBatchData ?? encoded))
  }

  static func validateLocalMutation(
    _ mutation: CloudFullLocalMutation,
    precondition: CloudLocalPrecondition,
    for accepted: CloudAcceptedEntityInput,
    context: ModelContext
  ) throws {
    let reference = accepted.reference
    let mutationMatchesReference = switch mutation {
    case .none:
      switch precondition {
      case .none, .exactSnip, .exactList: true
      case .requireMissing: false
      }
    case .upsertSnip(let value):
      reference.kind == .snip && reference.domainID == value.snipID
    case .upsertList(let value):
      reference.kind == .list && reference.domainID == value.id
    case .removeSnip(let id):
      reference.kind == .snip && reference.domainID == id
    case .removeList(let id):
      reference.kind == .list && reference.domainID == id && id != SnipList.inbox.id
    case .recoverDeletedSnip(let original, let recovered, let attachmentIDs):
      reference.kind == .snip
        && reference.domainID == original.snipID
        && recovered.snipID != original.snipID
        && recovered.requestID != original.requestID
        && recovered.listID == SnipList.inbox.id
        && Set(attachmentIDs).count == attachmentIDs.count
    case .removeListAndMoveSnips(let list, let snips):
      reference.kind == .list
        && reference.domainID == list.listID
        && list.listID != SnipList.inbox.id
        && snips.allSatisfy { $0.listID == list.listID }
        && Set(snips.map(\.snipID)).count == snips.count
    }
    guard mutationMatchesReference else { throw CloudFullStorageError.invalidLocalMutation }
    let snips = try context.fetch(FetchDescriptor<StoredSnipRecord>())
    let lists = try context.fetch(FetchDescriptor<StoredListRecord>())
    let metadata = try context.fetch(FetchDescriptor<StoredLibraryMetadataRecord>())
    switch (mutation, precondition) {
    case (.none, .none):
      return
    case (.none, .exactSnip(let expected)):
      guard let record = snips.first(where: { $0.id == expected.snipID }),
        try matches(record, expected: expected, metadata: metadata)
      else { throw CloudFullStorageError.staleLocalEntity }
    case (.none, .exactList(let expected)):
      guard let record = lists.first(where: { $0.id == expected.listID }),
        try matches(record, expected: expected, metadata: metadata)
      else { throw CloudFullStorageError.staleLocalEntity }
    case (.upsertSnip(let value), .requireMissing):
      guard !snips.contains(where: { $0.id == value.snipID }) else {
        throw CloudFullStorageError.staleLocalEntity
      }
    case (.upsertSnip(let value), .exactSnip(let expected)):
      guard value.snipID == expected.snipID,
        let record = snips.first(where: { $0.id == value.snipID }),
        try matches(record, expected: expected, metadata: metadata)
      else { throw CloudFullStorageError.staleLocalEntity }
    case (.upsertList(let value), .requireMissing):
      guard !lists.contains(where: { $0.id == value.id }) else {
        throw CloudFullStorageError.staleLocalEntity
      }
    case (.upsertList(let value), .exactList(let expected)):
      guard value.id == expected.listID,
        let record = lists.first(where: { $0.id == value.id }),
        try matches(record, expected: expected, metadata: metadata)
      else { throw CloudFullStorageError.staleLocalEntity }
    case (.removeSnip(let id), .exactSnip(let expected)):
      guard id == expected.snipID,
        let record = snips.first(where: { $0.id == id }),
        try matches(record, expected: expected, metadata: metadata)
      else { throw CloudFullStorageError.staleLocalEntity }
    case (.removeList(let id), .exactList(let expected)):
      guard id == expected.listID,
        let record = lists.first(where: { $0.id == id }),
        try matches(record, expected: expected, metadata: metadata)
      else { throw CloudFullStorageError.staleLocalEntity }
    case (
      .recoverDeletedSnip(let original, let recovered, let attachmentIDs),
      .exactSnip(let expected)
    ):
      let originalID = original.snipID
      let references = try context.fetch(FetchDescriptor(
        predicate: #Predicate<StoredSnipAttachmentReference> { $0.snipID == originalID }
      ))
      guard original == expected,
        let record = snips.first(where: { $0.id == original.snipID }),
        !snips.contains(where: { $0.id == recovered.snipID }),
        try matches(record, expected: original, metadata: metadata),
        Set(references.map(\.attachmentID)) == Set(attachmentIDs)
      else { throw CloudFullStorageError.staleLocalEntity }
    case (.removeListAndMoveSnips(let expected, let movedSnips), .exactList(let precondition)):
      let listSnips = snips.filter { $0.listID == expected.listID }
      let listSnipsByID = Dictionary(uniqueKeysWithValues: listSnips.map { ($0.id, $0) })
      guard expected == precondition,
        let record = lists.first(where: { $0.id == expected.listID }),
        try matches(record, expected: expected, metadata: metadata),
        Set(listSnipsByID.keys) == Set(movedSnips.map(\.snipID)),
        try movedSnips.allSatisfy({ expectedSnip in
          guard let snip = listSnipsByID[expectedSnip.snipID] else {
            return false
          }
          return try matches(snip, expected: expectedSnip, metadata: metadata)
        })
      else { throw CloudFullStorageError.staleLocalEntity }
    default:
      throw CloudFullStorageError.invalidLocalMutation
    }
  }

  static func matches(
    _ record: StoredSnipRecord,
    expected: CloudLocalSnipMutation,
    metadata: [StoredLibraryMetadataRecord]
  ) throws -> Bool {
    let metadataID = StoredLibraryMetadataRecord.identifier(kind: .snip, domainID: record.id)
    guard let orderData = metadata.first(where: { $0.id == metadataID })?.orderKeyData else {
      return false
    }
    let orderKey = try SnipOrderKey(data: orderData)
    return record.id == expected.snipID
      && record.requestID == expected.requestID
      && record.createdAt == expected.createdAt
      && record.content == expected.content
      && record.origin == expected.origin.rawValue
      && record.sourceApplicationName == expected.source?.applicationName
      && record.sourceWindowTitle == expected.source?.windowTitle
      && record.sourceURL == expected.source?.url
      && record.listID == expected.listID
      && record.isDone == expected.isDone
      && orderKey == expected.orderKey
  }

  static func matches(
    _ record: StoredListRecord,
    expected: CloudLocalListMutation,
    metadata: [StoredLibraryMetadataRecord]
  ) throws -> Bool {
    let metadataID = StoredLibraryMetadataRecord.identifier(kind: .list, domainID: record.id)
    guard let value = metadata.first(where: { $0.id == metadataID }) else { return false }
    let orderKey = try SnipOrderKey(data: value.orderKeyData)
    return record.id == expected.listID
      && (value.desiredName ?? record.name) == expected.desiredName
      && record.systemImage == expected.systemImage
      && record.color == expected.color
      && orderKey == expected.orderKey
  }

  static func applyLocalMutation(
    _ mutation: CloudFullLocalMutation,
    context: ModelContext
  ) throws {
    switch mutation {
    case .none:
      return
    case .upsertSnip(let value):
      let records = try context.fetch(FetchDescriptor<StoredSnipRecord>())
      if let record = records.first(where: { $0.id == value.snipID }) {
        record.requestID = value.requestID
        record.createdAt = value.createdAt
        record.updatedAt = value.updatedAt
        record.content = value.content
        record.origin = value.origin.rawValue
        record.sourceApplicationName = value.source?.applicationName
        record.sourceWindowTitle = value.source?.windowTitle
        record.sourceURL = value.source?.url
        record.listID = value.listID
        record.isDone = value.isDone
      } else {
        context.insert(
          StoredSnipRecord(
            Snip(
              id: value.snipID,
              requestID: value.requestID,
              createdAt: value.createdAt,
              updatedAt: value.updatedAt,
              content: value.content,
              origin: value.origin,
              source: value.source,
              listID: value.listID,
              isDone: value.isDone,
              manualSortKey: value.orderKey
            )
          )
        )
      }
      if !((try context.fetch(FetchDescriptor<StoredRequestRecord>())).contains {
        $0.id == value.requestID
      }) {
        context.insert(StoredRequestRecord(id: value.requestID))
      }
      try upsertMetadata(
        kind: .snip,
        domainID: value.snipID,
        orderKey: value.orderKey,
        desiredName: nil,
        context: context
      )
    case .upsertList(let value):
      let records = try context.fetch(FetchDescriptor<StoredListRecord>())
      if let record = records.first(where: { $0.id == value.id }) {
        record.name = value.resolvedName
        record.systemImage = value.systemImage
        record.color = value.color
      } else {
        context.insert(StoredListRecord(value))
      }
      try upsertMetadata(
        kind: .list,
        domainID: value.id,
        orderKey: value.sortKey,
        desiredName: value.desiredName,
        context: context
      )
    case .removeSnip(let id):
      let references = try context.fetch(FetchDescriptor<StoredSnipAttachmentReference>())
      guard !references.contains(where: { $0.snipID == id }) else {
        throw CloudFullStorageError.invalidLocalMutation
      }
      for record in try context.fetch(FetchDescriptor<StoredSnipRecord>()) where record.id == id {
        context.delete(record)
      }
      try removeMetadata(kind: .snip, domainID: id, context: context)
    case .removeList(let id):
      for record in try context.fetch(FetchDescriptor<StoredListRecord>()) where record.id == id {
        context.delete(record)
      }
      try removeMetadata(kind: .list, domainID: id, context: context)
    case .recoverDeletedSnip(let original, let recovered, _):
      let originalID = original.snipID
      for record in try context.fetch(FetchDescriptor(
        predicate: #Predicate<StoredSnipRecord> { $0.id == originalID }
      )) {
        context.delete(record)
      }
      context.insert(StoredSnipRecord(Snip(
        id: recovered.snipID,
        requestID: recovered.requestID,
        createdAt: recovered.createdAt,
        updatedAt: recovered.updatedAt,
        content: recovered.content,
        origin: recovered.origin,
        source: recovered.source,
        listID: recovered.listID,
        isDone: recovered.isDone,
        manualSortKey: recovered.orderKey
      )))
      for reference in try context.fetch(FetchDescriptor(
        predicate: #Predicate<StoredSnipAttachmentReference> { $0.snipID == originalID }
      )) {
        reference.snipID = recovered.snipID
        reference.id = StoredSnipAttachmentReference.identifier(
          snipID: recovered.snipID,
          attachmentID: reference.attachmentID
        )
      }
      let recoveredRequestID = recovered.requestID
      let request = try context.fetch(FetchDescriptor(
        predicate: #Predicate<StoredRequestRecord> { $0.id == recoveredRequestID }
      ))
      if request.isEmpty {
        context.insert(StoredRequestRecord(id: recovered.requestID))
      }
      try removeMetadata(kind: .snip, domainID: original.snipID, context: context)
      try upsertMetadata(
        kind: .snip,
        domainID: recovered.snipID,
        orderKey: recovered.orderKey,
        desiredName: nil,
        context: context
      )
    case .removeListAndMoveSnips(let list, _):
      let listID = list.listID
      for record in try context.fetch(FetchDescriptor(
        predicate: #Predicate<StoredSnipRecord> { $0.listID == listID }
      )) {
        record.listID = SnipList.inbox.id
      }
      for record in try context.fetch(FetchDescriptor(
        predicate: #Predicate<StoredListRecord> { $0.id == listID }
      )) {
        context.delete(record)
      }
      try removeMetadata(kind: .list, domainID: list.listID, context: context)
    }
  }

  static func upsertMetadata(
    kind: StoredLibraryMetadataKind,
    domainID: UUID,
    orderKey: SnipOrderKey,
    desiredName: String?,
    context: ModelContext
  ) throws {
    let id = StoredLibraryMetadataRecord.identifier(kind: kind, domainID: domainID)
    if let current = try context.fetch(FetchDescriptor<StoredLibraryMetadataRecord>())
      .first(where: { $0.id == id })
    {
      current.update(orderKey: orderKey, desiredName: desiredName)
    } else {
      context.insert(
        StoredLibraryMetadataRecord(
          kind: kind,
          domainID: domainID,
          orderKey: orderKey,
          desiredName: desiredName
        )
      )
    }
  }

  static func removeMetadata(
    kind: StoredLibraryMetadataKind,
    domainID: UUID,
    context: ModelContext
  ) throws {
    let id = StoredLibraryMetadataRecord.identifier(kind: kind, domainID: domainID)
    for record in try context.fetch(FetchDescriptor<StoredLibraryMetadataRecord>())
      where record.id == id
    {
      context.delete(record)
    }
  }

  static func resolveStoredListNames(context: ModelContext) throws {
    let records = try context.fetch(FetchDescriptor<StoredListRecord>())
    let metadata = try context.fetch(FetchDescriptor<StoredLibraryMetadataRecord>())
    let byID = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
    let lists = try records.map { record -> SnipList in
      let value = byID[StoredLibraryMetadataRecord.identifier(kind: .list, domainID: record.id)]
      return SnipList(
        id: record.id,
        desiredName: value?.desiredName ?? record.name,
        resolvedName: record.name,
        systemImage: record.systemImage,
        color: record.color,
        sortKey: try value.map { try SnipOrderKey(data: $0.orderKeyData) }
          ?? .legacy(Int64(record.position))
      )
    }
    let resolved = SnipListNameAllocator.resolving(lists)
    for list in resolved {
      records.first(where: { $0.id == list.id })?.name = list.resolvedName
    }
  }
}
