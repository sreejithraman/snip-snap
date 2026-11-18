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
    let unchangedAbsences = try unchangedTurnOffAbsences(input.reviewRead)
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
          if reviewed.contains(record.reference) || unchangedAbsences.contains(record.reference) { continue }
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



  private static func sameTurnOffBodies(_ lhs: [FailedEnableImage], _ rhs: [FailedEnableImage]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { sameTurnOffImage($0.0, $0.1) }
  }

  private static func sameTurnOffImage(_ lhs: FailedEnableImage, _ rhs: FailedEnableImage) -> Bool {
    switch (lhs, rhs) {
    case (.snip(let a), .snip(let b)):
      // Existing synthesized updatedAt is metadata. Every raw image stays retained.
      return a.kind == b.kind && a.id == b.id && a.requestID == b.requestID
        && a.createdAt == b.createdAt && a.originRaw == b.originRaw
        && a.text == b.text && a.source == b.source && a.isDone == b.isDone
        && a.pinnedAt == b.pinnedAt && a.listID == b.listID
        && a.orderKey == b.orderKey && a.attachments == b.attachments
    case (.list(let a), .list(let b)): return a == b
    default: return false
    }
  }

  /// Acquisition only. This selects a possible T0 lineage; it cannot admit any effect.
  func turnOffAbsenceCandidates(_ input: FailedEnableReviewRead) throws -> Set<FailedEnableReference> {
    guard input.transition.targetKind == .iCloudSync,
      input.transition.syncProtocol == .fullRecordV1,
      input.transition.namespace == namespace.binding, let evidence = input.evidence,
      evidence.sourceStoreID == FailedEnableEncoding.uuid(input.transition.sourceStoreID)
    else { return [] }
    let transfers = evidence.transfers.filter {
      $0.kind == .turnOff && $0.state == .checked
        && $0.destinationStoreID == evidence.sourceStoreID
        && $0.namespace == FailedEnableBinding(namespace.binding)
        && $0.dormantDigest == FailedEnableEncoding.digest(input.source.snapshot.opaqueSyncStatePayload)
    }
    guard transfers.count == 1, let turnOff = transfers.first,
      try Self.sameTurnOffBodies(input.source.images(), turnOff.outputs),
      input.source.snapshot.snips.allSatisfy({ $0.attachments.isEmpty })
    else { return [] }
    let bases = try CloudDormantAcceptedBaseBundle.decode(input.source.snapshot.opaqueSyncStatePayload).entries
      .filter { $0.namespaceKey == namespace.namespaceKey.rawValue }
    let accepted = input.candidate.storage.readyEntities + input.candidate.storage.deferredEntities
    let group = evidence.namespaces.first { $0.binding == FailedEnableBinding(namespace.binding) }
    return Set(try bases.compactMap { base in
      let reference = FailedEnableReference(base.reference)
      guard base.reference.kind == .snip,
        group?.reviews.contains(where: { $0.reference == reference }) != true,
        group?.alternatives.contains(where: { $0.reference == reference }) != true,
        turnOff.outputs.contains(where: { $0.reference == reference }),
        !accepted.contains(where: { $0.reference == base.reference || $0.identity == base.identity })
      else { return nil }
      // Leave genuinely unqualified histories to the existing review producer/choice route.
      let captures = (group?.captures ?? []).sorted {
        (UInt64($0.ordinal) ?? 0) > (UInt64($1.ordinal) ?? 0)
      }
      if let latest = captures.first(where: { $0.records.contains(where: { $0.reference == reference }) }),
        let record = latest.records.first(where: { $0.reference == reference }) {
        if let observation = record.observedAccepted.value {
          guard try qualifies(record, observation: observation, candidate: nil) else { return nil }
        } else {
          guard record.preparation.classification == .deleteRecovery,
            record.preparation.baseKind == .checkedTurnOff, record.offlineChanged.isEmpty,
            record.preparation.value.value?.fields == .absent,
            record.observedAccepted.value == nil, record.unqualifiedObservation.value == nil
          else { return nil }
        }
      }
      return reference
    })
  }

  private func hasTurnOffInventory(_ input: FailedEnableReviewRead,
    references: Set<FailedEnableReference>
  ) throws -> Bool {
    guard !references.isEmpty, input.candidate.storage.namespaceState.storageVersion == 1,
      !input.candidate.hasPendingBatches,
      input.candidate.storage.deferredEntities.isEmpty,
      input.candidate.storage.quarantines.isEmpty,
      let inventory = input.candidate.storage.namespaceState.initialFetchInventory,
      inventory.canProveAbsence,
      let data = input.candidate.engineState,
      let engine = try? JSONDecoder().decode(CloudEngineStateEnvelope.self, from: data),
      engine.namespace == namespace, !engine.requiresInitialFetch,
      input.candidate.storage.namespaceState.phase == .active
    else { return false }
    for reference in references {
      let typed = try reference.domain
      let identity = Self.identity(typed, zone: dataZone)
      guard typed.kind == .snip,
        !input.candidate.snapshot.snips.contains(where: { $0.id == typed.domainID }),
        !inventory.observed.contains(identity) else { return false }
    }
    for entity in input.candidate.storage.readyEntities {
      _ = try Self.fields(entity, namespace: namespace.binding)
      guard inventory.observed.contains(entity.identity) else { return false }
    }
    return true
  }

  func needsTurnOffInventory(_ input: FailedEnableReviewRead) throws -> Bool {
    let references = try turnOffAbsenceCandidates(input)
    guard !references.isEmpty else { return false }
    // candidateReady will fetch again. An incremental result would end even a currently
    // complete inventory, so that upcoming acquisition must itself start without a token.
    if input.transition.phase == .candidateReady { return true }
    return try !hasTurnOffInventory(input, references: references)
  }

  /// A narrow attachment-free, unchanged whole-body T0 case. No absent A is constructed.
  func unchangedTurnOffAbsences(_ input: FailedEnableReviewRead) throws -> Set<FailedEnableReference> {
    let references = try turnOffAbsenceCandidates(input)
    guard !references.isEmpty else { return [] }
    guard try hasTurnOffInventory(input, references: references),
      let retained = input.retainedTurnOff,
      let evidence = input.evidence,
      retained.store.kind == .iCloudSync, retained.store.syncProtocol == .fullRecordV1,
      retained.store.namespace == namespace.binding,
      retained.store.id != input.transition.sourceStoreID,
      retained.store.id != input.transition.candidateStoreID,
      [.retired, .deleting, .recovery].contains(retained.store.lifecycle),
      retained.source.snapshot.revision == retained.store.revision,
      let turnOff = evidence.transfers.first(where: {
        $0.kind == .turnOff && $0.state == .checked
          && $0.sourceStoreID == FailedEnableEncoding.uuid(retained.store.id)
          && $0.destinationStoreID == evidence.sourceStoreID
          && $0.namespace == FailedEnableBinding(namespace.binding)
      }),
      try Self.sameTurnOffBodies(retained.source.images(), turnOff.outputs),
      input.source.seenRequestIDs == retained.source.seenRequestIDs,
      input.source.snapshot.legacyManualPositions == retained.source.snapshot.legacyManualPositions,
      try checkedTurnOffPayload(source: retained.source) == input.source.snapshot.opaqueSyncStatePayload,
      retained.source.storage.conflicts.isEmpty,
      retained.source.storage.pendingDeletes.isEmpty,
      retained.source.storage.deferredEntities.isEmpty,
      retained.source.storage.quarantines.isEmpty, retained.source.recoveryDescriptors.isEmpty,
      !retained.source.hasPendingBatches,
      input.source.storage.conflicts.isEmpty, input.source.storage.pendingDeletes.isEmpty,
      input.source.storage.deferredEntities.isEmpty, input.source.storage.quarantines.isEmpty,
      input.source.recoveryDescriptors.isEmpty, input.source.snapshot.attachmentData.isEmpty,
      input.candidate.storage.conflicts.isEmpty, input.candidate.storage.pendingDeletes.isEmpty,
      input.candidate.recoveryDescriptors.isEmpty
    else { throw FailedEnableEvidenceError.reviewRequired }
    if let attempt = input.transition.sendAttempt {
      guard attempt.namespace == namespace.binding else { throw FailedEnableEvidenceError.reviewRequired }
      for operation in attempt.operations {
        for reference in references {
          let typed = try reference.domain
          guard operation.reference != typed,
            operation.recordIdentity != Self.identity(typed, zone: dataZone) else {
            throw FailedEnableEvidenceError.reviewRequired
          }
        }
      }
    }
    let rootImages = try retained.source.images()
    let candidateImages = try input.candidate.images()
    let rootAccepted = retained.source.storage.readyEntities
    let rootReferences = Set(rootImages.map(\.reference))
    let binding = FailedEnableBinding(namespace.binding)
    let rootID = FailedEnableEncoding.uuid(retained.store.id)
    let sourceID = FailedEnableEncoding.uuid(input.transition.sourceStoreID)
    // The old checked transfer did not certify old conflicts. Inspect its real root and
    // every related source-keyed frame now; different earlier local versions are barriers.
    for frame in retained.frames {
      let affectedHistory = frame.namespaces.contains(where: { group in
        group.binding == binding && (group.captures.flatMap(\.records).contains(where: {
          rootReferences.contains($0.reference)
        }) || group.alternatives.contains(where: { rootReferences.contains($0.reference) })
          || group.reviews.contains(where: { rootReferences.contains($0.reference) }))
      })
      let related = affectedHistory || frame.sourceStoreID == sourceID || frame.sourceStoreID == rootID
        || frame.namespaces.flatMap(\.captures).contains(where: { $0.candidateStoreID == rootID })
        || frame.transfers.contains(where: { $0.sourceStoreID == rootID || $0.destinationStoreID == rootID })
      guard related else { continue }
      guard frame.continuity.state == .verified, frame.continuity.inFlight.value == nil else {
        throw FailedEnableEvidenceError.reviewRequired
      }
      for group in frame.namespaces where group.binding == binding {
        guard group.alternatives.isEmpty, group.reviews.isEmpty else {
          throw FailedEnableEvidenceError.reviewRequired
        }
        for capture in group.captures {
          guard capture.normalizer == 1, capture.syncProtocol == .fullRecordV1,
            capture.candidateDeletes.isEmpty else { throw FailedEnableEvidenceError.reviewRequired }
          for record in capture.records {
            guard record.sourceMembership == .present,
              let image = record.source.value,
              rootImages.contains(where: { Self.sameTurnOffImage($0, image) }),
              let q = record.preparation.value.value else { throw FailedEnableEvidenceError.reviewRequired }
            if q.fields == .absent {
              guard frame.sourceStoreID == sourceID, references.contains(record.reference),
                record.preparation.classification == .deleteRecovery,
                record.preparation.baseKind == .checkedTurnOff, record.offlineChanged.isEmpty,
                q.presence.isEmpty, record.observedAccepted.value == nil,
                record.unqualifiedObservation.value == nil,
                record.preparation.conflictFields.isEmpty,
                record.preparation.recoveryIdentities.isEmpty else { throw FailedEnableEvidenceError.reviewRequired }
            } else {
              guard let observation = record.observedAccepted.value,
                try qualifies(record, observation: observation, candidate: nil)
              else { throw FailedEnableEvidenceError.reviewRequired }
              var covered = false
              if let actual = rootAccepted.first(where: { FailedEnableReference($0.reference) == record.reference }) {
                covered = try sameTurnOffHistoryObservation(observation, actual: actual,
                  namespaceRevision: retained.source.storage.namespaceState.revision, storeID: retained.store.id)
              }
              if !covered, let actual = input.candidate.storage.readyEntities.first(where: {
                FailedEnableReference($0.reference) == record.reference
              }) {
                covered = try sameTurnOffHistoryObservation(observation, actual: actual,
                  namespaceRevision: input.candidate.storage.namespaceState.revision,
                  storeID: input.transition.candidateStoreID)
              }
              guard covered else { throw FailedEnableEvidenceError.reviewRequired }
            }
          }
        }
      }
      for transfer in frame.transfers where transfer.namespace == binding {
        guard transfer.conflicts.isEmpty, transfer.recoveryDescriptors.isEmpty,
          transfer.outputs.allSatisfy({ output in
            rootImages.contains(where: { Self.sameTurnOffImage($0, output) })
              || candidateImages.contains(where: { Self.sameTurnOffImage($0, output) })
          }) else {
          throw FailedEnableEvidenceError.reviewRequired
        }
      }
    }
    return references
  }


  private func sameTurnOffHistoryObservation(_ saved: FailedEnableObservation,
    actual: CloudAcceptedEntity, namespaceRevision: UInt64, storeID: UUID
  ) throws -> Bool {
    let input = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: saved.entityBase64)
    let savedEntity = CloudAcceptedEntity(reference: input.reference, identity: input.identity,
      schemaVersion: input.schemaVersion, acceptedData: input.acceptedData,
      presenceData: input.presenceData, shadowData: input.shadowData, systemFields: input.systemFields,
      dependencyListID: input.dependencyListID, isDeferred: saved.isDeferred,
      hasUnresolvedLegacyAbsence: saved.hasUnresolvedLegacyAbsence,
      localRevision: try FailedEnableEncoding.revision(saved.localRevision))
    let current = FailedEnableObservation(kind: .fullRecord,
      candidateStoreID: FailedEnableEncoding.uuid(storeID), namespaceRevision: String(namespaceRevision),
      localRevision: String(actual.localRevision), isDeferred: actual.isDeferred,
      hasUnresolvedLegacyAbsence: actual.hasUnresolvedLegacyAbsence,
      dependencyListID: .init(actual.dependencyListID.map(FailedEnableEncoding.uuid)),
      entityBase64: try Self.existingEnvelope(actual))
    // Reuse the established full typed-JSON comparison. Actual archives, unknown fields,
    // presence and system/shadow bytes are read and retained, never rewritten.
    let savedRevision = try Self.acceptedRevisionDigest(savedEntity,
      namespaceRevision: FailedEnableEncoding.revision(saved.namespaceRevision))
    let currentRevision = try Self.acceptedRevisionDigest(actual, namespaceRevision: namespaceRevision)
    return try sameReviewServer(
      FailedEnableServerExpectation.make(state: .value, observation: .init(saved),
        acceptedRevisionDigest: .init(savedRevision)),
      FailedEnableServerExpectation.make(state: .value, observation: .init(current),
        acceptedRevisionDigest: .init(currentRevision)))
  }

  func validateTurnOffOutput(_ input: FailedEnableReviewRead, capture: FailedEnableCapture,
    applied: Bool
  ) throws -> Set<FailedEnableReference> {
    let tagged = Set(capture.records.filter {
      $0.preparation.classification == .deleteRecovery && $0.preparation.baseKind == .checkedTurnOff
    }.map(\.reference))
    if tagged.isEmpty { return [] }
    let references = try unchangedTurnOffAbsences(input)
    guard tagged.isSubset(of: references) else { throw FailedEnableEvidenceError.reviewRequired }
    guard let evidence = input.evidence,
      capture.transitionID == FailedEnableEncoding.uuid(input.transition.id),
      capture.candidateStoreID == FailedEnableEncoding.uuid(input.transition.candidateStoreID),
      capture.sourceDigest == (try input.source.sourceDigest(sourceID: input.transition.sourceStoreID)),
      capture.freeze.sourceRevision == String(input.source.snapshot.revision),
      capture.freeze.id == input.transition.freezeToken.map({ FailedEnableEncoding.uuid($0.id) }),
      let transfer = evidence.transfers.last(where: {
      $0.kind == .candidate && $0.sourceCaptureIDs == [capture.id]
        && $0.sourceStoreID == evidence.sourceStoreID
        && $0.destinationStoreID == FailedEnableEncoding.uuid(input.transition.candidateStoreID)
        && $0.namespace == FailedEnableBinding(namespace.binding)
    }), !applied || transfer.state == .checked else { throw FailedEnableEvidenceError.reviewRequired }
    let sourceImages = try input.source.images()
    let bases = try CloudDormantAcceptedBaseBundle.decode(input.source.snapshot.opaqueSyncStatePayload).entries
      .filter { $0.namespaceKey == namespace.namespaceKey.rawValue }
    for record in capture.records where tagged.contains(record.reference) {
      guard let base = bases.first(where: { FailedEnableReference($0.reference) == record.reference }),
        case .snip(let local)? = record.source.value,
        base.identity == record.identity.domain,
        record.preparation.baseDigest.value == FailedEnableEncoding.digest(base.payload),
        record.preparation.normalizedLocal.immutableOverrides.value == FailedEnableImmutableOverrides(
          requestID: local.requestID, createdAt: local.createdAt, originRaw: local.originRaw),
        record.preparation.normalizedLocal.acceptedPresence == Dictionary(uniqueKeysWithValues:
          Self.keys(.snip).map { ($0, FailedEnablePresence.value) }),
        record.preparation.normalizedLocal.defaults.isEmpty,
        record.sourceMembership == .present, record.originalAcceptedExists,
        record.offlineChanged.isEmpty, record.preparation.normalizer == 1,
        record.preparation.knownFields == Self.keys(.snip),
        record.preparation.fetchedDigest.value == nil, record.preparation.reason.value == nil,
        record.preparation.conflictFields.isEmpty, record.preparation.recoveryIdentities.isEmpty,
        record.source.value == sourceImages.first(where: { $0.reference == record.reference }),
        record.preparation.value.value?.fields == .absent,
        record.preparation.value.value?.presence.isEmpty == true,
        record.observedAccepted.value == nil, record.unqualifiedObservation.value == nil,
        record.identity.domain == Self.identity(try record.reference.domain, zone: dataZone),
        !transfer.outputs.contains(where: { $0.reference == record.reference })
      else { throw FailedEnableEvidenceError.reviewRequired }
    }
    if applied {
      guard try input.candidate.images() == transfer.outputs,
        FailedEnableEncoding.digest(input.candidate.snapshot.opaqueSyncStatePayload) == transfer.dormantDigest
      else { throw FailedEnableEvidenceError.reviewRequired }
    }
    return tagged
  }

  /// Truth about an already committed private apply only; never current absence authority.
  func validatePastTurnOffApply(_ input: FailedEnableReviewRead, capture: FailedEnableCapture) throws {
    guard let evidence = input.evidence,
      capture.transitionID == FailedEnableEncoding.uuid(input.transition.id),
      capture.candidateStoreID == FailedEnableEncoding.uuid(input.transition.candidateStoreID),
      let transfer = evidence.transfers.last(where: {
        $0.kind == .candidate && $0.sourceCaptureIDs == [capture.id]
          && $0.sourceStoreID == evidence.sourceStoreID && $0.destinationStoreID == capture.candidateStoreID
          && $0.namespace == FailedEnableBinding(namespace.binding)
      }), let receipt = input.candidate.reenableReceiptDigest,
      FailedEnableEncoding.hex(receipt) == transfer.planDigest,
      try input.candidate.images() == transfer.outputs,
      FailedEnableEncoding.digest(input.candidate.snapshot.opaqueSyncStatePayload) == transfer.dormantDigest,
      transfer.conflicts.isEmpty, transfer.recoveryDescriptors.isEmpty,
      input.candidate.storage.conflicts.isEmpty, input.candidate.recoveryDescriptors.isEmpty,
      input.candidate.storage.deferredEntities.isEmpty, input.candidate.storage.quarantines.isEmpty,
      capture.candidateDeletes.isEmpty else { throw FailedEnableEvidenceError.reviewRequired }
    for record in capture.records {
      guard let q = record.preparation.value.value else { throw FailedEnableEvidenceError.reviewRequired }
      guard Self.same(q.fields, try Self.plannedValue(record.reference.domain,
        in: input.candidate.snapshot, projection: q.fields)) else {
        throw FailedEnableEvidenceError.reviewRequired
      }
    }
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

  func validateExposure(_ input: FailedEnableReviewRead, capture: FailedEnableCapture,
    requiresAccepted: Bool
  ) throws -> Set<FailedEnableReference> {
    guard let evidence = input.evidence else { throw FailedEnableEvidenceError.reviewRequired }
    if capture.records.contains(where: {
      $0.reference.kind == .list && $0.preparation.classification == .deleteRecovery
        && $0.preparation.baseKind == .checkedTurnOff && !$0.offlineChanged.isEmpty
    }) {
      try validateExposure(capture: capture, candidate: input.candidate,
        evidence: evidence, requiresAccepted: requiresAccepted)
      return [try validateDeletedListExposure(input, capture: capture, evidence: evidence,
        requiresAccepted: requiresAccepted)]
    }
    if capture.records.contains(where: {
      $0.preparation.classification == .deleteRecovery && $0.preparation.baseKind == .checkedTurnOff
        && !$0.offlineChanged.isEmpty
    }) {
      try validateExposure(capture: capture, candidate: input.candidate,
        evidence: evidence, requiresAccepted: requiresAccepted)
      return [try validateEditedDeletionExposure(input, capture: capture, evidence: evidence,
        requiresAccepted: requiresAccepted)]
    }
    let absent = try validateTurnOffOutput(input, capture: capture, applied: true)
    try validateExposure(capture: capture, candidate: input.candidate,
      evidence: evidence, requiresAccepted: requiresAccepted)
    guard requiresAccepted, capture.records.contains(where: {
      $0.preparation.classification == .realConflict && $0.preparation.baseKind == .checkedTurnOff
    }) else { return absent }
    return absent.union([try validateSameFieldConflictPublication(input, capture: capture, evidence: evidence)])
  }

  /// The original snip returns to its already accepted Inbox value, so no operation is admitted.
  private func validateDeletedListExposure(_ input: FailedEnableReviewRead,
    capture: FailedEnableCapture, evidence: FailedEnableInstalledEvidence, requiresAccepted: Bool
  ) throws -> FailedEnableReference {
    let transition = input.transition
    let source = input.source
    let candidate = input.candidate
    let sourceID = FailedEnableEncoding.uuid(transition.sourceStoreID)
    let candidateID = FailedEnableEncoding.uuid(transition.candidateStoreID)
    let binding = FailedEnableBinding(namespace.binding)
    let namespaceKey = namespace.namespaceKey.rawValue
    let inbox = CloudEntityReference(kind: .list, domainID: SnipList.inboxID)
    let state = candidate.storage.namespaceState
    // At firstSendStarted the caller is admitting an actual outbound batch. Reject
    // that whole batch before arming, including saves/deletes of the list by either identity.
    guard transition.phase == (requiresAccepted ? .firstSendComplete : .enrollmentApproved),
      !capture.armed, transition.sendAttempt == nil,
      transition.namespace == namespace.binding, transition.targetKind == .iCloudSync,
      transition.syncProtocol == .fullRecordV1,
      let freeze = transition.freezeToken, freeze.sourceStoreID == transition.sourceStoreID,
      freeze.revision == source.snapshot.revision,
      capture.syncProtocol == .fullRecordV1, capture.predecessors.isEmpty,
      capture.transitionID == FailedEnableEncoding.uuid(transition.id), capture.candidateStoreID == candidateID,
      capture.freeze.id == FailedEnableEncoding.uuid(freeze.id),
      capture.freeze.sourceRevision == String(freeze.revision),
      try capture.sourceDigest == source.sourceDigest(sourceID: transition.sourceStoreID),
      evidence.purpose == .installedEvidence, evidence.sourceStoreID == sourceID,
      evidence.namespaces.count == 1, let group = evidence.namespaces.first,
      group.binding == binding, group.captures == [capture], group.alternatives.isEmpty, group.reviews.isEmpty,
      evidence.blobs.isEmpty, source.snapshot.attachmentData.isEmpty, candidate.snapshot.attachmentData.isEmpty,
      evidence.transfers.count == 2, let off = evidence.transfers.first(where: { $0.kind == .turnOff }),
      off.state == .checked, off.namespace == binding, off.destinationStoreID == sourceID,
      off.sourceStoreID != sourceID, off.sourceStoreID != candidateID, off.sourceCaptureIDs.isEmpty,
      off.conflicts.isEmpty, off.recoveryDescriptors.isEmpty,
      off.dormantDigest == FailedEnableEncoding.digest(source.snapshot.opaqueSyncStatePayload),
      try off.planDigest == FailedEnableEncoding.digest(off.outputs),
      let transfer = evidence.transfers.first(where: { $0.kind == .candidate }),
      transfer.state == .checked, transfer.namespace == binding, transfer.sourceStoreID == sourceID,
      transfer.destinationStoreID == candidateID, transfer.sourceCaptureIDs == [capture.id],
      let receipt = candidate.reenableReceiptDigest, FailedEnableEncoding.hex(receipt) == transfer.planDigest,
      transfer.dormantDigest == FailedEnableEncoding.digest(candidate.snapshot.opaqueSyncStatePayload),
      candidate.snapshot.opaqueSyncStatePayload == source.snapshot.opaqueSyncStatePayload,
      try candidate.images() == transfer.outputs,
      transfer.conflicts.isEmpty, candidate.storage.conflicts.isEmpty, candidate.storage.pendingDeletes.isEmpty,
      !candidate.hasPendingBatches, state.storageVersion == 1, state.phase == .active, !state.zoneCreationPending,
      let inventory = state.initialFetchInventory, inventory.canProveAbsence,
      let data = candidate.engineState,
      let engine = try? JSONDecoder().decode(CloudEngineStateEnvelope.self, from: data),
      engine.namespace == namespace, !engine.requiresInitialFetch,
      let deleted = capture.records.first(where: { $0.preparation.classification == .deleteRecovery }),
      deleted.preparation.baseKind == .checkedTurnOff, !deleted.offlineChanged.isEmpty,
      case .list(let listImage)? = deleted.source.value,
      source.snapshot.snips.count == 1, let moved = source.snapshot.snips.first, moved.attachments.isEmpty
    else { throw FailedEnableEvidenceError.reviewRequired }

    let list = try listImage.domain
    let listReference = CloudEntityReference(kind: .list, domainID: list.id)
    let listIdentity = Self.identity(listReference, zone: dataZone)
    let snipReference = CloudEntityReference(kind: .snip, domainID: moved.id)
    let survivors: Set<CloudEntityReference> = [inbox, snipReference]
    let references = survivors.union([listReference])
    let sourceImages = try source.images()
    var inInbox = moved
    inInbox.listID = inbox.domainID
    let inboxImage = FailedEnableImage.list(FailedEnableListImage(.inbox))
    let snipImage = FailedEnableImage.snip(try FailedEnableSnipImage(inInbox, attachmentData: [:]))
    guard listReference != inbox, try deleted.reference.domain == listReference,
      deleted.identity.domain == listIdentity, moved.listID == list.id,
      source.snapshot.lists.count == 2, source.snapshot.lists.contains(.inbox), source.snapshot.lists.contains(list),
      candidate.snapshot.lists == [.inbox], candidate.snapshot.snips == [inInbox],
      capture.records.count == 3, try Set(capture.records.map { try $0.reference.domain }) == references,
      capture.records.compactMap({ $0.source.value }) == sourceImages,
      off.outputs.count == 3, off.outputs.contains(inboxImage), off.outputs.contains(snipImage),
      let priorListImage = off.outputs.first(where: { $0.reference == deleted.reference }),
      inventory.observed == Set(survivors.map({ Self.identity($0, zone: dataZone) })),
      Set(candidate.storage.readyEntities.map(\.reference)) == survivors,
      transition.approvedSnipIDs.isSubset(of: [moved.id]),
      candidate.storage.enrolledEntities == Set(transition.approvedSnipIDs.map {
        CloudEntityReference(kind: .snip, domainID: $0)
      }).union([inbox]), state.revision > 0
    else { throw FailedEnableEvidenceError.reviewRequired }

    let entries = try CloudDormantAcceptedBaseBundle.decode(source.snapshot.opaqueSyncStatePayload).entries
    guard entries.count == 3, Set(entries.map(\.reference)) == references,
      entries.allSatisfy({ $0.namespaceKey == namespaceKey }) else { throw FailedEnableEvidenceError.reviewRequired }
    let decoder = JSONDecoder()
    let fetchedRevision = state.revision - 1  // Apply does not advance enrollment; approval does once.
    for record in capture.records {
      let reference = try record.reference.domain
      let identity = Self.identity(reference, zone: dataZone)
      guard record.identity.domain == identity, record.sourceMembership == .present, record.originalAcceptedExists,
        record.preparation.knownFields == Self.keys(reference.kind), record.preparation.reason.value == nil,
        record.preparation.conflictFields.isEmpty, record.preparation.recoveryIdentities.isEmpty,
        record.unqualifiedObservation.value == nil,
        let entry = entries.first(where: { $0.reference == reference }), entry.identity == identity
      else { throw FailedEnableEvidenceError.reviewRequired }
      let envelope = try decoder.decode(CloudAcceptedEntityInput.self, from: entry.payload)
      let ancestor = Self.entity(envelope)
      let fields = try Self.fields(ancestor, namespace: namespace.binding)
      let presence = try Self.presence(ancestor)
      guard envelope.reference == reference, envelope.identity == identity,
        presence.keys.sorted() == Self.keys(reference.kind), presence.values.allSatisfy({ $0 == .value }),
        record.preparation.normalizedLocal.acceptedPresence == presence,
        record.preparation.normalizedLocal.defaults.isEmpty
      else { throw FailedEnableEvidenceError.reviewRequired }
      if reference == listReference {
        guard record.preparation.baseDigest.value == FailedEnableEncoding.digest(entry.payload),
          record.preparation.fetchedDigest.value == nil, record.observedAccepted.value == nil,
          record.preparation.normalizedLocal.immutableOverrides.value == nil,
          record.preparation.value.value?.fields == .absent,
          record.preparation.value.value?.presence.isEmpty == true,
          try Self.same(fields, Self.unbasedSource(priorListImage)),
          try Self.changedFields(base: fields, local: Self.unbasedSource(.list(listImage))) == record.offlineChanged
        else { throw FailedEnableEvidenceError.reviewRequired }
        let prior = try CloudFullSyncPersistence.listFields(CloudFullSyncPersistence.listRecord(ancestor))
        let recovered = CloudFullSyncPersistence.listFields(list, updatedAt: prior.updatedAt)
        try validateDeletedListRows(candidate, transfer: transfer, transitionID: transition.id,
          movedSnipID: moved.id, recoveredList: recovered)
      } else {
        let image = reference == inbox ? inboxImage : snipImage
        guard record.preparation.classification == .equalFetched,
          record.preparation.baseKind == (reference == inbox ? .equalFetched : .checkedTurnOff),
          let observation = record.observedAccepted.value,
          let row = candidate.storage.readyEntities.first(where: { $0.reference == reference }),
          row.identity == identity, row.schemaVersion == envelope.schemaVersion,
          row.dependencyListID == envelope.dependencyListID,
          row.shadowData == envelope.shadowData, row.systemFields == envelope.systemFields,
          try Self.fields(row, namespace: namespace.binding) == fields, try Self.presence(row) == presence,
          try Self.same(fields, Self.unbasedSource(image)),
          record.preparation.value.value?.fields == fields, record.preparation.value.value?.presence == presence,
          try qualifies(record, observation: observation, candidate: candidate),
          try matchesConflictObservation(observation, row: row, candidateID: candidateID, revision: fetchedRevision),
          try record.preparation.fetchedDigest.value == Self.acceptedRevisionDigest(row, namespaceRevision: fetchedRevision)
        else { throw FailedEnableEvidenceError.reviewRequired }
        if reference == snipReference {
          guard record.offlineChanged == ["placement"],
            record.preparation.baseDigest.value == FailedEnableEncoding.digest(entry.payload),
            record.preparation.normalizedLocal.immutableOverrides.value == FailedEnableImmutableOverrides(
              requestID: FailedEnableEncoding.uuid(moved.requestID),
              createdAt: FailedEnableEncoding.date(moved.createdAt), originRaw: moved.origin.rawValue)
          else { throw FailedEnableEvidenceError.reviewRequired }
        } else if !record.offlineChanged.isEmpty {
          throw FailedEnableEvidenceError.reviewRequired
        }
      }
    }
    return deleted.reference
  }

  private func validateDeletedListRows(_ candidate: FailedEnableStoreRead, transfer: FailedEnableTransfer,
    transitionID: UUID, movedSnipID: UUID, recoveredList: CloudListMergeFields
  ) throws {
    guard candidate.recoveryRows.count == 2, transfer.recoveryDescriptors.count == 2 else {
      throw FailedEnableEvidenceError.reviewRequired
    }
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let namespaceKey = namespace.namespaceKey.rawValue
    let links = try transfer.recoveryDescriptors.map { try decoder.decode(CloudFullRecoveryInput.self, from: $0) }
    let expected: [(CloudFullRecoveryKind, UUID, UUID)] = [
      (.modeDeletedListPlacement, movedSnipID, UUID(uuidString: "22222222-2222-5222-8222-222222222222")!),
      (.modeRecoveredList, recoveredList.id, UUID(uuidString: "33333333-3333-5333-8333-333333333333")!),
    ]
    for (kind, sourceID, salt) in expected {
      let batchID = SnipLibraryTransferPlanner.derivedUUID(
        transitionID: SnipLibraryTransferPlanner.derivedUUID(transitionID: transitionID, sourceID: salt),
        sourceID: sourceID)
      let key = "full-recovery-\(batchID.uuidString.lowercased())"
      guard let link = links.first(where: { $0.kind == kind }), link.storageVersion == 1,
        link.batchID == batchID, link.namespaceKey == namespaceKey, link.outboundData.isEmpty,
        let row = candidate.recoveryRows.first(where: { $0.eventKey == key }), row.id == "\(namespaceKey)|\(key)",
        try transfer.recoveryDescriptors.contains(FailedEnableEncoding.json(link)),
        try row.payload == CloudWirePayloadEnvelope(format: .fullRecordV1, payload: encoder.encode(link)).encoded(),
        let body = try JSONSerialization.jsonObject(with: link.resultData) as? [String: Any],
        body["storageVersion"] as? Int == 1, body["sourceID"] as? String == sourceID.uuidString,
        body["deletedListID"] as? String == recoveredList.id.uuidString
      else { throw FailedEnableEvidenceError.reviewRequired }
      var keys: Set<String> = ["storageVersion", "sourceID", "deletedListID"]
      if kind == .modeRecoveredList {
        keys.insert("recoveredList")
        var metadataKeys: Set<String> = ["id", "desiredName", "systemImage", "orderKey", "updatedAt"]
        if recoveredList.color != nil { metadataKeys.insert("colorPreset") }
        guard let metadata = body["recoveredList"] as? [String: Any],
          Set(metadata.keys) == metadataKeys,
          try decoder.decode(CloudListMergeFields.self, from: JSONSerialization.data(withJSONObject: metadata)) == recoveredList
        else { throw FailedEnableEvidenceError.reviewRequired }
      }
      guard Set(body.keys) == keys else { throw FailedEnableEvidenceError.reviewRequired }
    }
  }

  /// A checked turn-off whose edited snip is already copied into ordinary Inbox recovery.
  /// The absent original never becomes accepted-value ancestry.
  private func validateEditedDeletionExposure(_ input: FailedEnableReviewRead,
    capture: FailedEnableCapture, evidence: FailedEnableInstalledEvidence, requiresAccepted: Bool
  ) throws -> FailedEnableReference {
    let transition = input.transition
    let candidate = input.candidate
    let sourceID = FailedEnableEncoding.uuid(transition.sourceStoreID)
    let candidateID = FailedEnableEncoding.uuid(transition.candidateStoreID)
    let binding = FailedEnableBinding(namespace.binding)
    let namespaceKey = namespace.namespaceKey.rawValue
    let inbox = CloudEntityReference(kind: .list, domainID: SnipList.inboxID)
    let inboxIdentity = Self.identity(inbox, zone: dataZone)
    let state = candidate.storage.namespaceState
    let allowedPhases: [SyncModeTransitionPhase] = requiresAccepted
      ? [.firstSendComplete] : [.enrollmentApproved, .firstSendStarted]
    guard allowedPhases.contains(transition.phase), transition.namespace == namespace.binding,
      transition.targetKind == .iCloudSync, transition.syncProtocol == .fullRecordV1,
      let freeze = transition.freezeToken, freeze.sourceStoreID == transition.sourceStoreID,
      input.source.snapshot.revision == freeze.revision,
      capture.syncProtocol == .fullRecordV1, capture.predecessors.isEmpty,
      capture.transitionID == FailedEnableEncoding.uuid(transition.id), capture.candidateStoreID == candidateID,
      capture.freeze.id == FailedEnableEncoding.uuid(freeze.id),
      capture.freeze.sourceRevision == String(freeze.revision),
      try capture.sourceDigest == input.source.sourceDigest(sourceID: transition.sourceStoreID),
      evidence.purpose == .installedEvidence, evidence.sourceStoreID == sourceID,
      evidence.namespaces.count == 1, let group = evidence.namespaces.first,
      group.binding == binding, group.captures == [capture], group.reviews.isEmpty, group.alternatives.isEmpty,
      evidence.transfers.count == 2, let off = evidence.transfers.first(where: { $0.kind == .turnOff }),
      off.state == .checked, off.namespace == binding, off.destinationStoreID == sourceID,
      off.sourceStoreID != sourceID, off.sourceStoreID != candidateID, off.sourceCaptureIDs.isEmpty,
      off.conflicts.isEmpty, off.recoveryDescriptors.isEmpty,
      off.dormantDigest == FailedEnableEncoding.digest(input.source.snapshot.opaqueSyncStatePayload),
      try off.planDigest == FailedEnableEncoding.digest(off.outputs),
      let transfer = evidence.transfers.first(where: { $0.kind == .candidate }),
      transfer.state == .checked, transfer.namespace == binding, transfer.sourceStoreID == sourceID,
      transfer.destinationStoreID == candidateID, transfer.sourceCaptureIDs == [capture.id],
      let receipt = candidate.reenableReceiptDigest, FailedEnableEncoding.hex(receipt) == transfer.planDigest,
      transfer.dormantDigest == FailedEnableEncoding.digest(candidate.snapshot.opaqueSyncStatePayload),
      try candidate.images() == transfer.outputs,
      transfer.conflicts.isEmpty, candidate.storage.conflicts.isEmpty, candidate.storage.pendingDeletes.isEmpty,
      !candidate.hasPendingBatches, state.storageVersion == 1, state.phase == .active,
      let inventory = state.initialFetchInventory, inventory.canProveAbsence,
      let data = candidate.engineState,
      let engine = try? JSONDecoder().decode(CloudEngineStateEnvelope.self, from: data),
      engine.namespace == namespace, !engine.requiresInitialFetch,
      input.source.snapshot.lists == [.inbox], candidate.snapshot.lists == [.inbox],
      capture.records.count == 2, try input.source.images() == capture.records.compactMap({ $0.source.value }),
      let original = capture.records.first(where: { $0.preparation.classification == .deleteRecovery }),
      original.sourceMembership == .present, original.originalAcceptedExists,
      original.preparation.baseKind == .checkedTurnOff, !original.offlineChanged.isEmpty,
      original.preparation.knownFields == Self.snipKeys,
      original.preparation.fetchedDigest.value == nil, original.preparation.reason.value == nil,
      original.preparation.conflictFields.isEmpty, original.preparation.recoveryIdentities.isEmpty,
      original.preparation.value.value?.fields == .absent,
      original.preparation.value.value?.presence.isEmpty == true,
      original.observedAccepted.value == nil, original.unqualifiedObservation.value == nil,
      case .snip(let localImage)? = original.source.value
    else { throw FailedEnableEvidenceError.reviewRequired }

    let reference = try original.reference.domain
    let originalIdentity = Self.identity(reference, zone: dataZone)
    let local = try localImage.domain
    // The complete initial inventory held only Inbox. A subsequent send preserves that
    // inventory, but its newly accepted recovered row is not a fetched member.
    guard reference == CloudEntityReference(kind: .snip, domainID: local.id), local.listID == inbox.domainID,
      original.identity.domain == originalIdentity, inventory.observed == [inboxIdentity],
      !candidate.storage.readyEntities.contains(where: { $0.reference == reference || $0.identity == originalIdentity }),
      let inboxRecord = capture.records.first(where: { $0.reference == FailedEnableReference(inbox) }),
      inboxRecord.preparation.classification == .equalFetched, inboxRecord.preparation.baseKind == .equalFetched,
      let inboxObservation = inboxRecord.observedAccepted.value,
      let inboxRow = candidate.storage.readyEntities.first(where: { $0.reference == inbox }),
      inboxRow.identity == inboxIdentity, try qualifies(inboxRecord, observation: inboxObservation, candidate: candidate)
    else { throw FailedEnableEvidenceError.reviewRequired }
    let fetchedRevision = try FailedEnableEncoding.revision(inboxObservation.namespaceRevision)
    guard fetchedRevision < state.revision,
      try matchesConflictObservation(inboxObservation, row: inboxRow, candidateID: candidateID, revision: fetchedRevision),
      try inboxRecord.preparation.fetchedDigest.value == Self.acceptedRevisionDigest(inboxRow,
        namespaceRevision: fetchedRevision)
    else { throw FailedEnableEvidenceError.reviewRequired }

    let entries = try CloudDormantAcceptedBaseBundle.decode(input.source.snapshot.opaqueSyncStatePayload).entries
    guard entries.count == 2, Set(entries.map(\.reference)) == [inbox, reference],
      entries.allSatisfy({ $0.namespaceKey == namespaceKey }),
      let ancestor = entries.first(where: { $0.reference == reference }),
      ancestor.identity == originalIdentity,
      original.preparation.baseDigest.value == FailedEnableEncoding.digest(ancestor.payload),
      off.outputs.count == 2, off.outputs.contains(.list(FailedEnableListImage(.inbox))),
      let oldImage = off.outputs.first(where: { $0.reference == original.reference }),
      case .snip(let oldSnip) = oldImage, oldSnip.attachments.isEmpty
    else { throw FailedEnableEvidenceError.reviewRequired }
    let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: ancestor.payload)
    let base = Self.entity(envelope)
    let baseFields = try Self.fields(base, namespace: namespace.binding)
    let localFields = try Self.unbasedSource(.snip(localImage))
    guard envelope.reference == reference, envelope.identity == originalIdentity,
      envelope.dependencyListID == inbox.domainID,
      Self.same(baseFields, try Self.unbasedSource(oldImage)),
      try Self.presence(base).values.allSatisfy({ $0 == .value }),
      localImage.requestID == oldSnip.requestID, localImage.createdAt == oldSnip.createdAt,
      localImage.originRaw == oldSnip.originRaw,
      original.preparation.normalizedLocal.immutableOverrides.value == FailedEnableImmutableOverrides(
        requestID: oldSnip.requestID, createdAt: oldSnip.createdAt, originRaw: oldSnip.originRaw),
      original.preparation.normalizedLocal.acceptedPresence == Dictionary(uniqueKeysWithValues:
        Self.snipKeys.map { ($0, FailedEnablePresence.value) }),
      original.preparation.normalizedLocal.defaults.isEmpty,
      try Self.changedFields(base: baseFields, local: localFields) == original.offlineChanged
    else { throw FailedEnableEvidenceError.reviewRequired }

    let recoveredID = SnipLibraryTransferPlanner.derivedUUID(transitionID: transition.id, sourceID: local.id)
    let recoveredRequest = SnipLibraryTransferPlanner.derivedUUID(transitionID: recoveredID, sourceID: local.requestID)
    let recovered = CloudEntityReference(kind: .snip, domainID: recoveredID)
    let recoveredIdentity = Self.identity(recovered, zone: dataZone)
    let output = Snip(id: recoveredID, requestID: recoveredRequest, createdAt: local.createdAt,
      updatedAt: local.updatedAt, content: local.content, origin: local.origin, source: local.source,
      listID: inbox.domainID, isDone: local.isDone, pinnedAt: local.pinnedAt,
      manualSortKey: local.manualSortKey, attachments: local.attachments)
    let bytes = input.source.snapshot.attachmentData
    guard recovered != reference, recoveredRequest != local.requestID,
      !input.source.seenRequestIDs.contains(recoveredRequest),
      transition.approvedSnipIDs == [recoveredID], candidate.snapshot.snips == [output],
      candidate.snapshot.attachmentData == bytes,
      localImage.attachments.allSatisfy({ $0.availability.kind == .embedded }),
      Set(bytes.keys) == Set(output.attachments.map(\.id)),
      Set(evidence.blobs.keys) == Set(localImage.attachments.map(\.availability.sha256)),
      bytes.values.allSatisfy({ evidence.blobs[FailedEnableEncoding.digest($0)] == $0 })
    else { throw FailedEnableEvidenceError.reviewRequired }
    try validateEditedDeletionRow(candidate, transfer: transfer,
      transitionID: transition.id, sourceID: local.id, recoveredID: recoveredID)

    let savedRecovery = SyncModeSendOperation(reference: recovered, recordIdentity: recoveredIdentity, kind: .save)
    let attempt = transition.sendAttempt
    if let attempt {
      guard attempt.namespace == namespace.binding,
        !attempt.operations.contains(where: { $0.reference == reference || $0.recordIdentity == originalIdentity })
      else { throw FailedEnableEvidenceError.reviewRequired }
    }
    if let accepted = candidate.storage.readyEntities.first(where: { $0.reference == recovered }) {
      guard Set(candidate.storage.readyEntities.map(\.reference)) == [inbox, recovered],
        capture.armed, attempt?.operations.contains(savedRecovery) == true,
        accepted.identity == recoveredIdentity, accepted.dependencyListID == inbox.domainID,
        accepted.deferredLocalMutation == nil, accepted.schemaVersion == CloudFullRecordCodec.schemaVersion,
        try Self.fields(accepted, namespace: namespace.binding) == Self.unbasedSource(
          .snip(FailedEnableSnipImage(output, attachmentData: bytes))),
        try Self.presence(accepted).values.allSatisfy({ $0 == .value })
      else { throw FailedEnableEvidenceError.reviewRequired }
    } else {
      guard !requiresAccepted, Set(candidate.storage.readyEntities.map(\.reference)) == [inbox]
      else { throw FailedEnableEvidenceError.reviewRequired }
    }
    return original.reference
  }

  private func validateEditedDeletionRow(_ candidate: FailedEnableStoreRead, transfer: FailedEnableTransfer,
    transitionID: UUID, sourceID: UUID, recoveredID: UUID
  ) throws {
    let namespaceKey = namespace.namespaceKey.rawValue
    let salt = UUID(uuidString: "11111111-1111-5111-8111-111111111111")!
    let linkID = SnipLibraryTransferPlanner.derivedUUID(
      transitionID: SnipLibraryTransferPlanner.derivedUUID(transitionID: transitionID, sourceID: salt),
      sourceID: sourceID)
    let key = "full-recovery-\(linkID.uuidString.lowercased())"
    guard transfer.recoveryDescriptors.count == 1, let descriptor = transfer.recoveryDescriptors.first,
      candidate.recoveryRows.count == 1, let row = candidate.recoveryRows.first,
      row.eventKey == key, row.id == "\(namespaceKey)|\(key)"
    else { throw FailedEnableEvidenceError.reviewRequired }
    let link = try JSONDecoder().decode(CloudFullRecoveryInput.self, from: descriptor)
    let body = try JSONSerialization.jsonObject(with: link.resultData) as? [String: Any]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let modeBytes = try CloudWirePayloadEnvelope(format: .fullRecordV1, payload: encoder.encode(link)).encoded()
    guard link.storageVersion == 1, link.namespaceKey == namespaceKey, link.batchID == linkID,
      link.kind == .modeRecoveredSnip, link.outboundData.isEmpty,
      let body, Set(body.keys) == ["storageVersion", "sourceID", "recoveredID"],
      body["storageVersion"] as? Int == 1, body["sourceID"] as? String == sourceID.uuidString,
      body["recoveredID"] as? String == recoveredID.uuidString,
      try descriptor == FailedEnableEncoding.json(link), row.payload == modeBytes
    else { throw FailedEnableEvidenceError.reviewRequired }
  }

  /// The existing ADR-0014 text conflict in Inbox, with one original and one recovered snip.
  /// Publication of the pair does not make the conflicted record accepted-value ancestry.
  private func validateSameFieldConflictPublication(_ input: FailedEnableReviewRead,
    capture: FailedEnableCapture, evidence: FailedEnableInstalledEvidence
  ) throws -> FailedEnableReference {
    let transition = input.transition
    let candidate = input.candidate
    let sourceID = FailedEnableEncoding.uuid(transition.sourceStoreID)
    let candidateID = FailedEnableEncoding.uuid(transition.candidateStoreID)
    let binding = FailedEnableBinding(namespace.binding)
    let inbox = CloudEntityReference(kind: .list, domainID: SnipList.inboxID)
    let currentRevision = candidate.storage.namespaceState.revision
    guard transition.phase == .firstSendComplete, transition.namespace == namespace.binding,
      transition.syncProtocol == .fullRecordV1, transition.targetKind == .iCloudSync,
      let freeze = transition.freezeToken, freeze.sourceStoreID == transition.sourceStoreID,
      capture.armed, capture.syncProtocol == .fullRecordV1, capture.predecessors.isEmpty,
      capture.transitionID == FailedEnableEncoding.uuid(transition.id),
      capture.candidateStoreID == candidateID, capture.freeze.id == FailedEnableEncoding.uuid(freeze.id),
      capture.freeze.sourceRevision == String(freeze.revision),
      input.source.snapshot.revision == freeze.revision,
      try input.source.sourceDigest(sourceID: transition.sourceStoreID) == capture.sourceDigest,
      evidence.purpose == .installedEvidence, evidence.sourceStoreID == sourceID,
      evidence.namespaces.count == 1, let group = evidence.namespaces.first,
      group.binding == binding, group.captures == [capture],
      group.reviews.isEmpty, group.alternatives.isEmpty, evidence.blobs.isEmpty,
      evidence.transfers.count == 2,
      let off = evidence.transfers.first(where: { $0.kind == .turnOff }),
      off.state == .checked, off.namespace == binding, off.destinationStoreID == sourceID,
      off.sourceStoreID != sourceID, off.sourceStoreID != candidateID, off.sourceCaptureIDs.isEmpty,
      off.conflicts.isEmpty, off.recoveryDescriptors.isEmpty,
      off.dormantDigest == FailedEnableEncoding.digest(input.source.snapshot.opaqueSyncStatePayload),
      let transfer = evidence.transfers.first(where: { $0.kind == .candidate }),
      transfer.state == .checked, transfer.namespace == binding, transfer.sourceStoreID == sourceID,
      transfer.destinationStoreID == candidateID, transfer.sourceCaptureIDs == [capture.id],
      let receipt = candidate.reenableReceiptDigest, FailedEnableEncoding.hex(receipt) == transfer.planDigest,
      transfer.dormantDigest == FailedEnableEncoding.digest(candidate.snapshot.opaqueSyncStatePayload),
      try candidate.images() == transfer.outputs,
      !candidate.hasPendingBatches, candidate.storage.namespaceState.phase == .active,
      candidate.storage.pendingDeletes.isEmpty, input.source.snapshot.lists == [.inbox],
      candidate.snapshot.lists == [.inbox],
      capture.records.count == 2,
      let original = capture.records.first(where: { $0.preparation.classification == .realConflict }),
      original.sourceMembership == .present, original.originalAcceptedExists,
      original.preparation.baseKind == .checkedTurnOff, original.offlineChanged == ["text"],
      original.preparation.conflictFields == ["text"], original.observedAccepted.value == nil,
      case .snip(let localImage)? = original.source.value, localImage.attachments.isEmpty,
      let originalFields = original.preparation.value.value,
      original.preparation.knownFields == Self.snipKeys, original.preparation.reason.value == nil,
      original.preparation.normalizedLocal.immutableOverrides.value == FailedEnableImmutableOverrides(
        requestID: localImage.requestID, createdAt: localImage.createdAt, originRaw: localImage.originRaw),
      originalFields.presence.keys.sorted() == Self.snipKeys,
      originalFields.presence.values.allSatisfy({ $0 == .value })
    else { throw FailedEnableEvidenceError.reviewRequired }

    let reference = try original.reference.domain
    let originalIdentity = Self.identity(reference, zone: dataZone)
    let local = try localImage.domain
    let recoveredID = SnipLibraryTransferPlanner.derivedUUID(transitionID: transition.id, sourceID: local.id)
    let recovered = CloudEntityReference(kind: .snip, domainID: recoveredID)
    let recoveredIdentity = Self.identity(recovered, zone: dataZone)
    // The one capture and its still-frozen intent bound the accumulated attempt. An earlier
    // failed setup could have cleared its attempt, so additional captures are unsupported here.
    guard reference == CloudEntityReference(kind: .snip, domainID: local.id), local.listID == inbox.domainID,
      original.identity.domain == originalIdentity, recovered != reference,
      original.preparation.recoveryIdentities == [FailedEnableReference(recovered)],
      try input.source.images() == capture.records.compactMap({ $0.source.value }),
      let attempt = transition.sendAttempt, attempt.namespace == namespace.binding,
      attempt.operations == [SyncModeSendOperation(reference: recovered,
        recordIdentity: recoveredIdentity, kind: .save)],
      Set(candidate.storage.readyEntities.map(\.reference)) == [inbox, reference, recovered],
      let server = candidate.storage.readyEntities.first(where: { $0.reference == reference }),
      server.identity == originalIdentity, server.dependencyListID == inbox.domainID,
      let copy = candidate.storage.readyEntities.first(where: { $0.reference == recovered }),
      copy.identity == recoveredIdentity, copy.dependencyListID == inbox.domainID,
      try Self.fields(server, namespace: namespace.binding) == originalFields.fields,
      try Self.presence(server) == original.preparation.normalizedLocal.acceptedPresence,
      original.preparation.normalizedLocal.defaults.isEmpty,
      let current = original.unqualifiedObservation.value,
      try matchesConflictObservation(current, row: server, candidateID: candidateID, revision: currentRevision)
    else { throw FailedEnableEvidenceError.reviewRequired }

    // The immutable equal-fetched Inbox observation supplies the checked preparation revision.
    // Verify its own fetched digest at that revision before using it for the original's digest.
    // Enrollment and send move the namespace revision; the late observation cannot supply this preimage.
    guard let inboxRecord = capture.records.first(where: { $0.reference == FailedEnableReference(inbox) }),
      inboxRecord.preparation.classification == .equalFetched,
      inboxRecord.preparation.baseKind == .equalFetched,
      let observation = inboxRecord.observedAccepted.value,
      let inboxRow = candidate.storage.readyEntities.first(where: { $0.reference == inbox }),
      inboxRow.identity == Self.identity(inbox, zone: dataZone),
      try qualifies(inboxRecord, observation: observation, candidate: candidate)
    else { throw FailedEnableEvidenceError.reviewRequired }
    let fetchedRevision = try FailedEnableEncoding.revision(observation.namespaceRevision)
    guard fetchedRevision < currentRevision,
      try matchesConflictObservation(observation, row: inboxRow, candidateID: candidateID, revision: fetchedRevision),
      try inboxRecord.preparation.fetchedDigest.value == Self.acceptedRevisionDigest(inboxRow,
        namespaceRevision: fetchedRevision),
      try original.preparation.fetchedDigest.value == Self.acceptedRevisionDigest(server,
        namespaceRevision: fetchedRevision)
    else { throw FailedEnableEvidenceError.reviewRequired }

    let entries = try CloudDormantAcceptedBaseBundle.decode(input.source.snapshot.opaqueSyncStatePayload).entries
    guard entries.count == 2, Set(entries.map(\.reference)) == [inbox, reference],
      entries.allSatisfy({ $0.namespaceKey == namespace.namespaceKey.rawValue }),
      let ancestor = entries.first(where: { $0.reference == reference }),
      ancestor.identity == originalIdentity,
      original.preparation.baseDigest.value == FailedEnableEncoding.digest(ancestor.payload),
      off.outputs.count == 2, off.outputs.contains(.list(FailedEnableListImage(.inbox))),
      try off.planDigest == FailedEnableEncoding.digest(off.outputs),
      let baseImage = off.outputs.first(where: { $0.reference == original.reference }),
      case .snip(let baseSnip) = baseImage, baseSnip.attachments.isEmpty
    else { throw FailedEnableEvidenceError.reviewRequired }
    let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: ancestor.payload)
    guard envelope.reference == reference, envelope.identity == originalIdentity,
      try Self.same(Self.fields(Self.entity(envelope), namespace: namespace.binding), Self.unbasedSource(baseImage)),
      try Self.presence(Self.entity(envelope)).values.allSatisfy({ $0 == .value })
    else { throw FailedEnableEvidenceError.reviewRequired }
    let base = try CloudFullSyncPersistence.snipFields(CloudFullSyncPersistence.snipRecord(Self.entity(envelope)))
    let localFields = CloudFullSyncPersistence.snipFields(local, accepted: nil)
    let serverFields = try CloudFullSyncPersistence.snipFields(CloudFullSyncPersistence.snipRecord(server))
    var expectedLocal = base
    expectedLocal.text = localFields.text
    expectedLocal.updatedAt = localFields.updatedAt
    var expectedServer = base
    expectedServer.text = serverFields.text
    expectedServer.updatedAt = serverFields.updatedAt
    let originalKey = CloudConflictKey.make(namespaceKey: namespace.namespaceKey,
      recordID: CloudRecordID.snip(local.id, in: dataZone), ancestorSystemFields: envelope.systemFields,
      serverSystemFields: server.systemFields)
    let recoveredRequest = SnipLibraryTransferPlanner.derivedUUID(transitionID: recoveredID, sourceID: local.requestID)
    let output = Snip(id: recoveredID, requestID: recoveredRequest, createdAt: local.createdAt,
      updatedAt: local.updatedAt, content: local.content, origin: local.origin, source: local.source,
      listID: local.listID, isDone: local.isDone, pinnedAt: local.pinnedAt, manualSortKey: local.manualSortKey)
    guard localFields == expectedLocal, serverFields == expectedServer,
      Set([base.text, localFields.text, serverFields.text]).count == 3,
      recoveredRequest != local.requestID,
      candidate.snapshot.snips.count == 2, candidate.snapshot.snips.contains(output),
      try Self.plannedValue(reference, in: candidate.snapshot, projection: originalFields.fields) == originalFields.fields,
      try Self.fields(copy, namespace: namespace.binding) == Self.unbasedSource(
        .snip(FailedEnableSnipImage(output, attachmentData: [:]))),
      try Self.presence(copy).values.allSatisfy({ $0 == .value })
    else { throw FailedEnableEvidenceError.reviewRequired }
    try validateSameFieldConflictRows(candidate, transfer: transfer, reference: reference,
      key: originalKey, transitionID: transition.id, local: localFields, server: serverFields, output: output)
    return original.reference
  }

  private func matchesConflictObservation(_ observation: FailedEnableObservation,
    row: CloudAcceptedEntity, candidateID: String, revision: UInt64
  ) throws -> Bool {
    guard observation.kind == .fullRecord, observation.candidateStoreID == candidateID,
      observation.namespaceRevision == String(revision), observation.localRevision == String(row.localRevision),
      !observation.isDeferred, !observation.hasUnresolvedLegacyAbsence,
      !row.isDeferred, !row.hasUnresolvedLegacyAbsence, row.deferredLocalMutation == nil, row.graphRepair == nil,
      observation.dependencyListID.value == row.dependencyListID.map(FailedEnableEncoding.uuid)
    else { return false }
    return try observation.entityBase64 == Self.existingEnvelope(row)
  }

  private func validateSameFieldConflictRows(_ candidate: FailedEnableStoreRead,
    transfer: FailedEnableTransfer, reference: CloudEntityReference, key: String, transitionID: UUID,
    local: CloudSnipMergeFields, server: CloudSnipMergeFields, output: Snip
  ) throws {
    let decoder = JSONDecoder()
    let review = SnipRecoveryRecord.snip(RecoveredSnip(id: output.id,
      currentSnipID: reference.domainID, recovered: output, conflictingFields: [.text]))
    guard transfer.conflicts.count == 1, let conflictBytes = transfer.conflicts.first,
      candidate.storage.conflicts.count == 1, let row = candidate.storage.conflicts.first,
      row.key == key, row.reference == reference, row.format == .snipMergeV1,
      transfer.recoveryDescriptors.count == 1, let linkBytes = transfer.recoveryDescriptors.first,
      candidate.recoveryRows.count == 2
    else { throw FailedEnableEvidenceError.reviewRequired }
    let conflict = try decoder.decode(CloudConflictInput.self, from: conflictBytes)
    let payload = try decoder.decode(CloudSnipConflictPayload.self, from: row.payload)
    let link = try decoder.decode(CloudFullRecoveryInput.self, from: linkBytes)
    let linkBody = try JSONSerialization.jsonObject(with: link.resultData) as? [String: Any]
    let salt = UUID(uuidString: "11111111-1111-5111-8111-111111111111")!
    let linkID = SnipLibraryTransferPlanner.derivedUUID(
      transitionID: SnipLibraryTransferPlanner.derivedUUID(transitionID: transitionID, sourceID: salt),
      sourceID: reference.domainID)
    guard conflict.key == key, conflict.reference == reference, conflict.format == .snipMergeV1,
      conflict.payload == row.payload, conflict.recovery == review,
      payload.fields == [.text], payload.local == local, payload.server == server,
      link.storageVersion == 1, link.namespaceKey == namespace.namespaceKey.rawValue,
      link.batchID == linkID, link.kind == .modeRecoveredSnip, link.outboundData.isEmpty,
      let linkBody, Set(linkBody.keys) == ["storageVersion", "sourceID", "recoveredID"],
      linkBody["storageVersion"] as? Int == 1,
      linkBody["sourceID"] as? String == reference.domainID.uuidString,
      linkBody["recoveredID"] as? String == output.id.uuidString
    else { throw FailedEnableEvidenceError.reviewRequired }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    // Encode the existing review payload for byte comparison; no stored representation is added.
    struct ReviewPayload: Encodable {
      let storageVersion = 1
      let conflictKey: String
      let recovery: SnipRecoveryRecord
    }
    let namespaceKey = namespace.namespaceKey.rawValue
    let modeKey = "full-recovery-\(linkID.uuidString.lowercased())"
    let reviewKey = "review-recovery-\(output.id.uuidString.lowercased())"
    let modeBytes = try CloudWirePayloadEnvelope(format: .fullRecordV1, payload: encoder.encode(link)).encoded()
    let reviewBytes = try CloudWirePayloadEnvelope(format: .fullRecordV1,
      payload: encoder.encode(ReviewPayload(conflictKey: key, recovery: review))).encoded()
    guard Set(candidate.recoveryRows.map(\.eventKey)) == [modeKey, reviewKey],
      candidate.recoveryRows.allSatisfy({ $0.id == "\(namespaceKey)|\($0.eventKey)" }),
      candidate.recoveryRows.first(where: { $0.eventKey == modeKey })?.payload == modeBytes,
      candidate.recoveryRows.first(where: { $0.eventKey == reviewKey })?.payload == reviewBytes
    else { throw FailedEnableEvidenceError.reviewRequired }
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
