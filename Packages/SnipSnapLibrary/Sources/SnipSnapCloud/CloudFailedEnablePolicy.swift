import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// Version 1 compares complete known values. It never creates an accepted archive.
struct CloudFailedEnablePolicy: FailedEnableSemantics {
  let namespace: CloudSyncNamespace
  let dataZone: CloudZoneID
  private static let snipKeys = ["createdAt", "id", "isDone", "originRaw", "pinnedAt", "placement",
    "requestID", "source", "text", "updatedAt"]
  private static let listKeys = ["colorPreset", "desiredName", "id", "orderKey", "systemImage", "updatedAt"]

  func prepare(_ input: FailedEnablePreparationRead) throws -> FailedEnablePreparedMerge {
    guard input.transition.namespace == namespace.binding,
      namespace.zones.contains(dataZone),
      input.transition.syncProtocol == .fullRecordV1,
      input.candidate.storage.deferredEntities.isEmpty,
      input.candidate.storage.quarantines.isEmpty
    else { throw FailedEnableEvidenceError.reviewRequired }
    let source = input.source.snapshot
    let stored = input.candidate.storage
    let accepted = Dictionary(uniqueKeysWithValues: stored.readyEntities.map { ($0.reference, $0) })
    let entries = try CloudDormantAcceptedBaseBundle.decode(source.opaqueSyncStatePayload).entries
      .filter { $0.namespaceKey == namespace.namespaceKey.rawValue }
    var bases: [CloudEntityReference: CloudAcceptedEntity] = [:]
    for entry in entries {
      let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: entry.payload)
      guard envelope.reference == entry.reference, envelope.identity == entry.identity else {
        throw FailedEnableEvidenceError.reviewRequired
      }
      bases[entry.reference] = Self.entity(envelope)
    }
    let group = input.evidence?.namespaces.first { $0.binding == FailedEnableBinding(namespace.binding) }
    if let group, !group.alternatives.isEmpty {
      throw FailedEnableEvidenceError.reviewRequired
    }
    let reviews = try reviewDrafts(input.reviewRead)
    guard reviews.allSatisfy({ $0.decision.value != nil }) else { throw FailedEnableEvidenceError.reviewRequired }
    let reviewed = Set(reviews.map(\.reference))
    guard Set((group?.reviews ?? []).map(\.reference)).isSubset(of: reviewed) else {
      throw FailedEnableEvidenceError.reviewRequired
    }
    var operational: [CloudEntityReference: FailedEnableFields] = [:]
    var predecessors: Set<String> = []
    if let group, !group.captures.isEmpty {
      guard input.continuityVerified, group.alternatives.isEmpty else {
        throw FailedEnableEvidenceError.reviewRequired
      }
      // The newest capture of a record is a barrier even when an older one qualified.
      var seen: Set<FailedEnableReference> = []
      for capture in group.captures.sorted(by: {
        (UInt64($0.ordinal) ?? 0) > (UInt64($1.ordinal) ?? 0)
      }) {
        guard capture.candidateDeletes.isEmpty else { throw FailedEnableEvidenceError.reviewRequired }
        for record in capture.records where seen.insert(record.reference).inserted {
          guard let image = record.source.value, record.sourceMembership == .present else { continue }
          if reviewed.contains(record.reference) { continue }
          if Self.definitelyUnsent(record, capture: capture, accepted: accepted[try record.reference.domain]) {
            continue
          }
          guard let observed = record.observedAccepted.value,
            try qualifies(record, observation: observed, candidate: nil),
            let prepared = record.preparation.value.value
          else { throw FailedEnableEvidenceError.reviewRequired }
          let reference = try record.reference.domain
          // Deletion needs its own bound candidate-delete plan; absence never means remote-only.
          guard accepted[reference] != nil,
            source.snips.contains(where: { $0.id == reference.domainID }) || reference.kind == .list,
            source.lists.contains(where: { $0.id == reference.domainID }) || reference.kind == .snip
          else { throw FailedEnableEvidenceError.reviewRequired }
          operational[reference] = try Self.normalizedSource(image, projection: prepared.fields)
          predecessors.insert(capture.id)
        }
      }
    }
    let checkedTurnOffReferences = Set((input.evidence?.transfers ?? []).filter {
      input.continuityVerified && $0.kind == .turnOff && $0.state == .checked
        && $0.destinationStoreID == FailedEnableEncoding.uuid(input.transition.sourceStoreID)
        && $0.namespace == FailedEnableBinding(namespace.binding)
        && $0.dormantDigest == FailedEnableEncoding.digest(source.opaqueSyncStatePayload)
    }.flatMap { $0.outputs.map(\.reference) })
    let sourceImages = try input.source.images()
    var normalization: [CloudEntityReference: FailedEnableFields] = [:]
    var anchorKinds: [CloudEntityReference: FailedEnableBaseKind] = [:]
    for image in sourceImages {
      let reference = try image.reference.domain
      if reviewed.contains(image.reference) {
        anchorKinds[reference] = .unverified
        if let server = accepted[reference] {
          normalization[reference] = try Self.normalizedSource(image, accepted: server)
        }
        continue
      }
      if operational[reference] != nil { anchorKinds[reference] = .sourceCapture; continue }
      if let server = accepted[reference] {
        let remote = try Self.fields(server, namespace: namespace.binding)
        let local = try Self.normalizedSource(image, accepted: server)
        normalization[reference] = local
        if Self.same(local, remote) {
          operational[reference] = local
          anchorKinds[reference] = .equalFetched
        } else if bases[reference] != nil && checkedTurnOffReferences.contains(image.reference) {
          anchorKinds[reference] = .checkedTurnOff
        } else {
          // Reading an inherited dormant B0 is not provenance.
          throw FailedEnableEvidenceError.reviewRequired
        }
      } else if bases[reference] == nil {
        anchorKinds[reference] = .noBaseEnrollment
      } else if !checkedTurnOffReferences.contains(image.reference) {
        throw FailedEnableEvidenceError.reviewRequired
      } else {
        anchorKinds[reference] = .checkedTurnOff
      }
    }
    let automaticSource = SnipLibraryTransferSnapshot(revision: source.revision,
      snips: source.snips.filter { !reviewed.contains(FailedEnableReference(
        CloudEntityReference(kind: .snip, domainID: $0.id))) }, lists: source.lists,
      attachmentData: source.attachmentData, legacyManualPositions: source.legacyManualPositions,
      opaqueSyncStateDigest: source.opaqueSyncStateDigest,
      opaqueSyncStatePayload: source.opaqueSyncStatePayload,
      additionalSeenRequestIDs: source.additionalSeenRequestIDs)
    let automatic = try CloudFullSyncPersistence.failedEnableApplyPlan(source: automaticSource,
      target: input.candidate.snapshot, stored: stored, namespace: namespace,
      transitionID: input.transition.id, operationalBases: operational)
    let plan = try applyingReviews(reviews, to: automatic, input: input)
    let planned = SnipLibraryTransferSnapshot(revision: source.revision,
      snips: plan.snips, lists: plan.lists, attachmentData: plan.attachmentData)
    var records: [FailedEnableRecord] = []
    for image in sourceImages {
      let reference = try image.reference.domain
      let server = accepted[reference]
      let base = bases[reference]
      let projected: FailedEnableFields
      if let normalized = normalization[reference] { projected = normalized }
      else if let base { projected = try Self.normalizedSource(image, accepted: base) }
      else { projected = try Self.unbasedSource(image) }
      let q = try Self.plannedValue(reference, in: planned, projection: projected)
      let conflict = plan.conflicts.first { $0.reference == reference }
      let conflictFields: [String]
      if let conflict {
        switch conflict.format {
        case .snipMergeV1:
          conflictFields = try JSONDecoder().decode(CloudSnipConflictPayload.self,
            from: conflict.payload).fields.map(\.rawValue).sorted()
        case .listMergeV1:
          conflictFields = try JSONDecoder().decode(CloudListConflictPayload.self,
            from: conflict.payload).fields.map(\.rawValue).sorted()
        case .legacyBindingV1: throw FailedEnableEvidenceError.reviewRequired
        }
      } else { conflictFields = [] }
      let recovered: [FailedEnableReference]
      if case .snip(let review)? = conflict?.recovery {
        recovered = [FailedEnableReference(CloudEntityReference(kind: .snip, domainID: review.id))]
      } else { recovered = [] }
      let kind: FailedEnableClassification = if conflict != nil { .realConflict }
        else if q == .absent { .deleteRecovery }
        else if let server, Self.same(q, try Self.fields(server, namespace: namespace.binding)) { .equalFetched }
        else { .nonconflicting }
      let presence = try server.map(Self.presence) ?? Dictionary(uniqueKeysWithValues:
        Self.keys(reference.kind).map { ($0, FailedEnablePresence.value) })
      let overrides: FailedEnableImmutableOverrides?
      if case .snip(let value) = projected {
        overrides = FailedEnableImmutableOverrides(requestID: value.requestID,
          createdAt: value.createdAt, originRaw: value.originRaw)
      } else { overrides = nil }
      let preparation = FailedEnablePreparation(normalizer: 1, classification: kind,
        knownFields: Self.keys(reference.kind),
        normalizedLocal: FailedEnableNormalizedLocal(immutableOverrides: .init(overrides),
          acceptedPresence: presence, defaults: presence.filter { $0.value == .missing }.map(\.key).sorted()),
        baseKind: anchorKinds[reference] ?? .unverified,
        baseDigest: .init(try operational[reference].map { try FailedEnableEncoding.digest($0) }
          ?? entries.first(where: { $0.reference == reference }).map { FailedEnableEncoding.digest($0.payload) }),
        fetchedDigest: .init(try server.map {
          try Self.acceptedRevisionDigest($0, namespaceRevision: stored.namespaceState.revision)
        }),
        value: .init(FailedEnablePreparedValue(fields: q,
          presence: q == .absent ? [:] : Dictionary(uniqueKeysWithValues:
            Self.keys(reference.kind).map { ($0, .value) }))),
        conflictFields: conflictFields, recoveryIdentities: recovered, reason: .init(nil))
      let identity = server?.identity ?? base?.identity ?? Self.identity(reference, zone: dataZone)
      records.append(FailedEnableRecord(reference: image.reference, identity: FailedEnableIdentity(identity),
        sourceMembership: .present, source: .init(image), originalAcceptedExists: base != nil,
        offlineChanged: try Self.changedFields(base: operational[reference]
          ?? base.map { try Self.fields($0, namespace: namespace.binding) }, local: projected),
        preparation: preparation, observedAccepted: .init(nil), unqualifiedObservation: .init(nil)))
    }
    return FailedEnablePreparedMerge(plan: plan,
      records: records.sorted { $0.reference.sortKey < $1.reference.sortKey },
      predecessors: predecessors.sorted())
  }

  func checkedTurnOffPayload(source: FailedEnableStoreRead) throws -> Data? {
    guard source.storage.deferredEntities.isEmpty, source.storage.quarantines.isEmpty else { return nil }
    let ready = Dictionary(uniqueKeysWithValues: source.storage.readyEntities.map { ($0.reference, $0) })
    for image in try source.images() {
      guard let accepted = ready[try image.reference.domain],
        Self.same(try Self.unbasedSource(image), try Self.fields(accepted, namespace: namespace.binding))
      else { return nil }
    }
    let prior = try CloudDormantAcceptedBaseBundle.decode(source.snapshot.opaqueSyncStatePayload)
    let accepted = try source.storage.readyEntities.map { entity in
      _ = try Self.fields(entity, namespace: namespace.binding)
      return CloudDormantAcceptedBaseBundle.Entry(namespaceKey: namespace.namespaceKey.rawValue,
        reference: entity.reference, identity: entity.identity,
        payload: try Self.existingEnvelope(entity))
    }
    return try prior.merging(CloudDormantAcceptedBaseBundle(entries: accepted)).encoded()
  }

  func validateExposure(capture: FailedEnableCapture, candidate: FailedEnableStoreRead,
    evidence: FailedEnableInstalledEvidence, requiresAccepted: Bool
  ) throws {
    guard capture.normalizer == 1, capture.candidateDeletes.isEmpty,
      candidate.storage.deferredEntities.isEmpty, candidate.storage.quarantines.isEmpty else {
      throw FailedEnableEvidenceError.reviewRequired
    }
    let capturedReferences = Set(capture.records.map(\.reference))
    for entity in candidate.storage.readyEntities {
      if let repair = entity.graphRepair,
        !capturedReferences.contains(FailedEnableReference(entity.reference)) {
        let accepted = try Self.canonicalFields(entity, namespace: namespace.binding)
        guard case .snip(let snip) = accepted,
          !entity.isDeferred, entity.wasMaterializedBeforeDeferral,
          entity.deferredLocalMutation == nil,
          repair.snipID == entity.reference.domainID,
          repair.missingListID != SnipList.inbox.id,
          repair.replacementListID != repair.missingListID,
          snip.placement.listID == FailedEnableEncoding.uuid(repair.missingListID),
          !candidate.snapshot.lists.contains(where: { $0.id == repair.missingListID }),
          candidate.snapshot.lists.contains(where: { $0.id == repair.replacementListID }),
          candidate.snapshot.snips.first(where: { $0.id == repair.snipID })?.listID
            == repair.replacementListID
        else { throw FailedEnableEvidenceError.reviewRequired }
      } else {
        _ = try Self.fields(entity, namespace: namespace.binding)
      }
    }
    try validateReviewedOutcomes(capture: capture, candidate: candidate,
      evidence: evidence, requiresAccepted: requiresAccepted)
    for record in capture.records where record.sourceMembership == .present {
      guard let prepared = record.preparation.value.value,
        Self.same(prepared.fields, try Self.plannedValue(record.reference.domain,
          in: candidate.snapshot, projection: prepared.fields))
      else { throw FailedEnableEvidenceError.reviewRequired }
    }
  }

  func observe(capture: FailedEnableCapture, candidate: FailedEnableStoreRead,
    candidateStoreID: UUID, namespace binding: ICloudSyncNamespaceBinding
  ) throws -> FailedEnableCapture {
    guard binding == namespace.binding, capture.normalizer == 1 else {
      throw FailedEnableEvidenceError.changed
    }
    var result = capture
    let committed = Dictionary(uniqueKeysWithValues:
      (candidate.storage.readyEntities + candidate.storage.deferredEntities).map { ($0.reference, $0) })
    for index in result.records.indices {
      let record = result.records[index]
      guard record.observedAccepted.value == nil,
        let entity = committed[try record.reference.domain],
        entity.identity == record.identity.domain
      else { continue }
      // A selected output's actual observation remains a replay checkpoint, never ancestry.
      if try retainsReviewedObservation(record) { continue }
      let observation = FailedEnableObservation(kind: .fullRecord,
        candidateStoreID: FailedEnableEncoding.uuid(candidateStoreID),
        namespaceRevision: String(candidate.storage.namespaceState.revision),
        localRevision: String(entity.localRevision), isDeferred: entity.isDeferred,
        hasUnresolvedLegacyAbsence: entity.hasUnresolvedLegacyAbsence,
        dependencyListID: .init(entity.dependencyListID.map(FailedEnableEncoding.uuid)),
        entityBase64: try Self.existingEnvelope(entity))
      if entity.graphRepair != nil || entity.deferredLocalMutation != nil {
        result.records[index].unqualifiedObservation = .init(observation)
        continue
      }
      if try qualifies(record, observation: observation, candidate: candidate) {
        result.records[index].observedAccepted = .init(observation)
        result.records[index].unqualifiedObservation = .init(nil)
      } else {
        result.records[index].unqualifiedObservation = .init(observation)
      }
    }
    return result
  }

  func qualifies(_ record: FailedEnableRecord, observation: FailedEnableObservation,
    candidate: FailedEnableStoreRead?
  ) throws -> Bool {
    guard record.sourceMembership == .present, record.source.value != nil,
      record.preparation.normalizer == 1,
      [.nonconflicting, .equalFetched].contains(record.preparation.classification),
      record.preparation.baseKind != .unverified,
      let q = record.preparation.value.value,
      observation.kind == .fullRecord, !observation.isDeferred,
      !observation.hasUnresolvedLegacyAbsence,
      record.preparation.knownFields == Self.keys(record.reference.kind),
      q.presence.keys.sorted() == Self.keys(record.reference.kind)
    else { return false }
    if case .snip(let image)? = record.source.value,
      image.attachments.contains(where: { $0.availability.kind != .embedded }) { return false }
    let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: observation.entityBase64)
    guard envelope.reference == (try record.reference.domain), envelope.identity == record.identity.domain,
      envelope.dependencyListID.map(FailedEnableEncoding.uuid) == observation.dependencyListID.value
    else { return false }
    let entity = Self.entity(envelope)
    let actual = try Self.fields(entity, namespace: namespace.binding)
    guard Self.same(q.fields, actual) else { return false }
    let presence = try Self.presence(entity)
    guard presence.allSatisfy({ key, value in
      value == q.presence[key] || value == .missing
        && record.preparation.normalizedLocal.defaults.contains(key)
    }) else { return false }
    if let candidate {
      let dependencyIsReady = envelope.dependencyListID.map { dependency in
        candidate.storage.readyEntities.contains {
          $0.reference == CloudEntityReference(kind: .list, domainID: dependency)
        }
      } ?? true
      guard !candidate.storage.conflicts.contains(where: { $0.reference == envelope.reference }),
        !candidate.storage.pendingDeletes.contains(where: { $0.reference == envelope.reference }),
        dependencyIsReady,
        Self.same(q.fields, try Self.plannedValue(envelope.reference,
          in: candidate.snapshot, projection: q.fields))
      else { return false }
    }
    return true
  }

  static func snipBase(_ value: FailedEnableFields?, fallback: CloudAcceptedEntity) throws -> CloudSnipMergeFields {
    if case .snip(let value)? = value { return try snip(value) }
    return try CloudFullSyncPersistence.snipFields(CloudFullSyncPersistence.snipRecord(fallback))
  }
  static func listBase(_ value: FailedEnableFields?, fallback: CloudAcceptedEntity) throws -> CloudListMergeFields {
    if case .list(let value)? = value { return try list(value) }
    return try CloudFullSyncPersistence.listFields(CloudFullSyncPersistence.listRecord(fallback))
  }
  static func keys(_ kind: CloudEntityKind) -> [String] { kind == .snip ? snipKeys : listKeys }
  static func identity(_ reference: CloudEntityReference, zone: CloudZoneID) -> CloudTextStorageIdentity {
    CloudTextStorageIdentity(zoneName: zone.name, ownerName: zone.ownerName,
      recordName: "\(reference.kind == .snip ? "s" : "l")-\(reference.domainID.uuidString.lowercased())")
  }
  static func entity(_ input: CloudAcceptedEntityInput) -> CloudAcceptedEntity {
    CloudAcceptedEntity(reference: input.reference, identity: input.identity, schemaVersion: input.schemaVersion,
      acceptedData: input.acceptedData, presenceData: input.presenceData, shadowData: input.shadowData,
      systemFields: input.systemFields, dependencyListID: input.dependencyListID,
      isDeferred: false, localRevision: 0)
  }
  static func existingEnvelope(_ entity: CloudAcceptedEntity) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(CloudFullSyncPersistence.acceptedInput(entity))
  }
  static func acceptedRevisionDigest(_ entity: CloudAcceptedEntity, namespaceRevision: UInt64) throws -> String {
    struct Revision: Encodable {
      let envelope: Data
      let localRevision: String
      let namespaceRevision: String
      let deferred: Bool
      let legacyAbsence: Bool
      let dependency: FailedEnableNullable<String>
    }
    return try FailedEnableEncoding.digest(Revision(
      envelope: existingEnvelope(entity), localRevision: String(entity.localRevision),
      namespaceRevision: String(namespaceRevision), deferred: entity.isDeferred,
      legacyAbsence: entity.hasUnresolvedLegacyAbsence,
      dependency: .init(entity.dependencyListID.map(FailedEnableEncoding.uuid))))
  }

  static func fields(_ entity: CloudAcceptedEntity, namespace: ICloudSyncNamespaceBinding) throws -> FailedEnableFields {
    guard entity.graphRepair == nil else { throw FailedEnableEvidenceError.unsupported }
    return try canonicalFields(entity, namespace: namespace)
  }

  private static func canonicalFields(_ entity: CloudAcceptedEntity,
    namespace: ICloudSyncNamespaceBinding
  ) throws -> FailedEnableFields {
    guard namespace.zones.contains(ICloudSyncZoneBinding(name: entity.identity.zoneName,
      ownerName: entity.identity.ownerName)), entity.schemaVersion <= CloudFullRecordCodec.schemaVersion,
      entity.schemaVersion >= 1,
      !entity.hasUnresolvedLegacyAbsence
    else { throw FailedEnableEvidenceError.unsupported }
    switch entity.reference.kind {
    case .snip:
      let record = try CloudFullSyncPersistence.snipRecord(entity)
      let archived = try JSONDecoder().decode(CloudTypedSnipRecord.self, from: entity.acceptedData)
      let presence = try JSONDecoder().decode(CloudTypedSnipRecord.self, from: entity.presenceData)
      guard record.binding == .canonical, record.domainID == entity.reference.domainID,
        CloudFullSyncPersistence.storageIdentity(record.id) == entity.identity,
        record.schemaVersion == entity.schemaVersion,
        archived == record, presence == record,
        entity.dependencyListID == (try CloudFullSyncPersistence.snipFields(record)).placement.listID
      else {
        throw FailedEnableEvidenceError.unsupported
      }
      return .snip(try wire(CloudFullSyncPersistence.snipFields(record)))
    case .list:
      let record = try CloudFullSyncPersistence.listRecord(entity)
      let archived = try JSONDecoder().decode(CloudTypedListRecord.self, from: entity.acceptedData)
      let presence = try JSONDecoder().decode(CloudTypedListRecord.self, from: entity.presenceData)
      guard record.binding == .canonical, record.domainID == entity.reference.domainID,
        CloudFullSyncPersistence.storageIdentity(record.id) == entity.identity,
        record.schemaVersion == entity.schemaVersion,
        archived == record, presence == record, entity.dependencyListID == nil else {
        throw FailedEnableEvidenceError.unsupported
      }
      return .list(try wire(CloudFullSyncPersistence.listFields(record)))
    }
  }
  static func presence(_ entity: CloudAcceptedEntity) throws -> [String: FailedEnablePresence] {
    func present<Value: Equatable & Sendable>(_ field: CloudFieldPresence<Value>) -> FailedEnablePresence {
      if case .missing = field { .missing } else { .value }
    }
    switch entity.reference.kind {
    case .snip:
      let r = try CloudFullSyncPersistence.snipRecord(entity)
      let snapshot = try CloudKitRecordMapper.snapshot(r.shadow.record())
      return ["id": .value, "requestID": present(r.requestID), "createdAt": present(r.createdAt),
        "originRaw": present(r.origin), "text": present(r.text), "source": present(r.source),
        "isDone": present(r.isDone), "pinnedAt": snapshot.encryptedFields["pinnedAt"] == nil ? .missing : .value,
        "placement": present(r.placement), "updatedAt": present(r.updatedAt)]
    case .list:
      let r = try CloudFullSyncPersistence.listRecord(entity)
      return ["id": .value, "desiredName": present(r.desiredName), "systemImage": present(r.systemImage),
        "colorPreset": r.color.map(present) ?? .missing, "orderKey": present(r.orderKey), "updatedAt": present(r.updatedAt)]
    }
  }
  private static func wire(_ f: CloudSnipMergeFields) throws -> FailedEnableSnipValue {
    try FailedEnableSnipValue(id: FailedEnableEncoding.uuid(f.id), requestID: FailedEnableEncoding.uuid(f.requestID),
      createdAt: FailedEnableEncoding.date(f.createdAt), originRaw: f.originRaw, text: f.text,
      source: .init(f.source.map(FailedEnableSource.init)), isDone: f.isDone,
      pinnedAt: .init(f.pinnedAt.map(FailedEnableEncoding.date)),
      placement: FailedEnablePlacement(listID: FailedEnableEncoding.uuid(f.placement.listID), orderKey: f.placement.orderKey.data),
      updatedAt: FailedEnableEncoding.date(f.updatedAt))
  }
  private static func wire(_ f: CloudListMergeFields) throws -> FailedEnableListValue {
    try FailedEnableListValue(id: FailedEnableEncoding.uuid(f.id), desiredName: f.desiredName,
      systemImage: f.systemImage, colorPreset: .init(f.color?.rawValue), orderKey: f.orderKey.data,
      updatedAt: FailedEnableEncoding.date(f.updatedAt))
  }
  static func snip(_ f: FailedEnableSnipValue) throws -> CloudSnipMergeFields {
    try CloudSnipMergeFields(id: FailedEnableEncoding.uuid(f.id), requestID: FailedEnableEncoding.uuid(f.requestID),
      createdAt: FailedEnableEncoding.date(f.createdAt), originRaw: f.originRaw, text: f.text,
      source: f.source.value?.domain, isDone: f.isDone, pinnedAt: f.pinnedAt.value.map(FailedEnableEncoding.date),
      placement: CloudSnipPlacement(listID: FailedEnableEncoding.uuid(f.placement.listID), orderKey: SnipOrderKey(data: f.placement.orderKey)),
      updatedAt: FailedEnableEncoding.date(f.updatedAt))
  }
  private static func list(_ f: FailedEnableListValue) throws -> CloudListMergeFields {
    try CloudListMergeFields(id: FailedEnableEncoding.uuid(f.id), desiredName: f.desiredName,
      systemImage: f.systemImage, color: f.colorPreset.value.flatMap(SnipListColorPreset.init(rawValue:)),
      orderKey: SnipOrderKey(data: f.orderKey), updatedAt: FailedEnableEncoding.date(f.updatedAt))
  }
  static func same(_ a: FailedEnableFields, _ b: FailedEnableFields) -> Bool {
    var a = a, b = b
    switch (a, b) {
    case (.snip(var x), .snip(var y)): x.updatedAt = ""; y.updatedAt = ""; a = .snip(x); b = .snip(y)
    case (.list(var x), .list(var y)): x.updatedAt = ""; y.updatedAt = ""; a = .list(x); b = .list(y)
    default: break
    }
    return a == b
  }
  static func unbasedSource(_ image: FailedEnableImage) throws -> FailedEnableFields {
    switch image {
    case .snip(let image): return .snip(try wire(CloudFullSyncPersistence.snipFields(image.domain, accepted: nil)))
    case .list(let image): return .list(try wire(CloudFullSyncPersistence.listFields(image.domain,
      updatedAt: Date(timeIntervalSinceReferenceDate: 0))))
    }
  }
  static func normalizedSource(_ image: FailedEnableImage, projection: FailedEnableFields) throws -> FailedEnableFields {
    switch (image, projection) {
    case (.snip, .snip(let accepted)):
      guard case .snip(var local) = try unbasedSource(image) else { throw FailedEnableEvidenceError.unsupported }
      local.requestID = accepted.requestID; local.createdAt = accepted.createdAt; local.originRaw = accepted.originRaw
      return .snip(local)
    case (.list, .list(let accepted)):
      guard case .list(var local) = try unbasedSource(image) else { throw FailedEnableEvidenceError.unsupported }
      local.updatedAt = accepted.updatedAt
      return .list(local)
    default: throw FailedEnableEvidenceError.unsupported
    }
  }
  static func normalizedSource(_ image: FailedEnableImage, accepted: CloudAcceptedEntity) throws -> FailedEnableFields {
    switch image {
    case .snip(let image):
      return .snip(try wire(CloudFullSyncPersistence.snipFields(image.domain,
        accepted: CloudFullSyncPersistence.snipRecord(accepted))))
    case .list(let image):
      let server = try CloudFullSyncPersistence.listFields(CloudFullSyncPersistence.listRecord(accepted))
      return .list(try wire(CloudFullSyncPersistence.listFields(image.domain, updatedAt: server.updatedAt)))
    }
  }
  private static func plannedValue(_ reference: CloudEntityReference,
    in snapshot: SnipLibraryTransferSnapshot, projection: FailedEnableFields
  ) throws -> FailedEnableFields {
    switch reference.kind {
    case .snip:
      guard let snip = snapshot.snips.first(where: { $0.id == reference.domainID }) else { return .absent }
      return try unbasedSource(.snip(FailedEnableSnipImage(snip, attachmentData: snapshot.attachmentData)))
    case .list:
      guard let list = snapshot.lists.first(where: { $0.id == reference.domainID }) else { return .absent }
      return try normalizedSource(.list(FailedEnableListImage(list)), projection: projection)
    }
  }
  static func changedFields(base: FailedEnableFields?, local: FailedEnableFields) throws -> [String] {
    guard let base else {
      switch local { case .snip: return snipKeys; case .list: return listKeys; case .absent: return [] }
    }
    let comparisons: [(String, Bool)]
    switch (base, local) {
    case (.snip(let a), .snip(let b)):
      comparisons = [("id", a.id != b.id), ("requestID", a.requestID != b.requestID),
        ("createdAt", a.createdAt != b.createdAt), ("originRaw", a.originRaw != b.originRaw),
        ("text", a.text != b.text), ("source", a.source != b.source),
        ("isDone", a.isDone != b.isDone), ("pinnedAt", a.pinnedAt != b.pinnedAt),
        ("placement", a.placement != b.placement)]
    case (.list(let a), .list(let b)):
      comparisons = [("id", a.id != b.id), ("desiredName", a.desiredName != b.desiredName),
        ("systemImage", a.systemImage != b.systemImage), ("colorPreset", a.colorPreset != b.colorPreset),
        ("orderKey", a.orderKey != b.orderKey)]
    default: throw FailedEnableEvidenceError.unsupported
    }
    return comparisons.filter { $0.1 }.map { $0.0 }.sorted()
  }
}
