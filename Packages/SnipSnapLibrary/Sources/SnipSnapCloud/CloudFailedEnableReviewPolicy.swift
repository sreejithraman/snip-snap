import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension CloudFailedEnablePolicy {
  var reviewNamespace: ICloudSyncNamespaceBinding { namespace.binding }

  static let reviewedSnipFields = ["isDone", "pinnedAt", "placement", "source", "text"]

  static func definitelyUnsent(_ record: FailedEnableRecord, capture: FailedEnableCapture,
    accepted: CloudAcceptedEntity?
  ) -> Bool {
    !capture.armed && accepted == nil && !record.originalAcceptedExists
      && record.preparation.baseKind == .noBaseEnrollment
      && record.preparation.fetchedDigest.value == nil
      && record.observedAccepted.value == nil && record.unqualifiedObservation.value == nil
      && record.preparation.classification == .nonconflicting
  }

  func reviewDrafts(_ input: FailedEnableReviewRead) throws -> [FailedEnableReview] {
    guard input.transition.namespace == namespace.binding,
      input.transition.syncProtocol == .fullRecordV1,
      input.candidate.storage.deferredEntities.isEmpty,
      input.candidate.storage.quarantines.isEmpty,
      [.remoteChecked, .remoteCheckedMissingZone, .seeding, .active]
        .contains(input.candidate.storage.namespaceState.phase)
    else { throw FailedEnableEvidenceError.reviewRequired }
    let binding = FailedEnableBinding(namespace.binding)
    let group = input.evidence?.namespaces.first { $0.binding == binding }
    let images = try input.source.images()
    let sourceDigest = try input.source.sourceDigest(sourceID: input.transition.sourceStoreID)
    let accepted = Dictionary(uniqueKeysWithValues: input.candidate.storage.readyEntities.map { ($0.reference, $0) })
    let oldReviews = Dictionary(grouping: group?.reviews ?? [], by: \.reference)
    var latest: [FailedEnableReference: (FailedEnableCapture, FailedEnableRecord)] = [:]
    for capture in (group?.captures ?? []).sorted(by: {
      (UInt64($0.ordinal) ?? 0) > (UInt64($1.ordinal) ?? 0)
    }) {
      for record in capture.records where latest[record.reference] == nil {
        latest[record.reference] = (capture, record)
      }
    }
    var result: [FailedEnableReview] = []
    for image in images {
      let reference = try image.reference.domain
      let server = accepted[reference]
      guard let saved = latest[image.reference] else { continue }
      let (capture, record) = saved
      guard [.nonconflicting, .equalFetched].contains(record.preparation.classification)
        || oldReviews[image.reference] != nil else { continue }
      if oldReviews[image.reference] == nil {
        if let observation = record.observedAccepted.value,
          try qualifies(record, observation: observation, candidate: nil) { continue }
        if Self.definitelyUnsent(record, capture: capture, accepted: server) { continue }
      }
      let observation: FailedEnableObservation?
      if let server {
        _ = try Self.fields(server, namespace: namespace.binding)
        observation = FailedEnableObservation(kind: .fullRecord,
          candidateStoreID: FailedEnableEncoding.uuid(input.transition.candidateStoreID),
          namespaceRevision: String(input.candidate.storage.namespaceState.revision),
          localRevision: String(server.localRevision), isDeferred: server.isDeferred,
          hasUnresolvedLegacyAbsence: server.hasUnresolvedLegacyAbsence,
          dependencyListID: .init(server.dependencyListID.map(FailedEnableEncoding.uuid)),
          entityBase64: try Self.existingEnvelope(server))
      } else { observation = nil }
      let state: FailedEnableServerState = server == nil ? .deleted : .value
      let rows = oldReviews[image.reference] ?? []
      var earlier: [FailedEnableImage] = []
      for saved in group?.captures ?? [] {
        for value in saved.records where value.reference == image.reference {
          if let version = value.source.value, version != image, !earlier.contains(version) { earlier.append(version) }
        }
      }
      for row in rows {
        if let version = row.local.image.value, version != image, !earlier.contains(version) { earlier.append(version) }
        let sameLocal = row.local.sourceDigest == sourceDigest
        let sameServer = row.server.state == state && row.server.observation.value?.entityBase64 == observation?.entityBase64
        if !sameLocal || !sameServer {
          for map in row.decision.value?.outputIDs ?? [] {
            for transfer in input.evidence?.transfers ?? [] {
              if let version = transfer.outputs.first(where: { $0.reference == map.output }),
                !earlier.contains(version) { earlier.append(version) }
            }
          }
        }
      }
      for alternative in group?.alternatives ?? [] where alternative.reference == image.reference {
        if let version = alternative.image.value, !earlier.contains(version) { earlier.append(version) }
      }
      let earlierVersions = try earlier.map { (try FailedEnableEncoding.digest($0), $0) }
        .sorted { $0.0 < $1.0 }.map(\.1)
      struct Comparison: Encodable {
        let sourceID: String
        let namespace: FailedEnableBinding
        let sourceDigest: String
        let reference: FailedEnableReference
        let server: Data?
        let state: FailedEnableServerState
        let earlierVersions: [FailedEnableImage]
      }
      let digest = try FailedEnableEncoding.digest(Comparison(
        sourceID: FailedEnableEncoding.uuid(input.transition.sourceStoreID), namespace: binding,
        sourceDigest: sourceDigest, reference: image.reference,
        server: observation?.entityBase64, state: state, earlierVersions: earlierVersions))
      var completedChoice: FailedEnableReview?
      if let server {
        let actual = try Self.fields(server, namespace: namespace.binding)
        for row in rows where row.local.sourceDigest == sourceDigest && row.decision.value?.choice == .useDevice {
          for transfer in input.evidence?.transfers ?? [] where transfer.state == .checked {
            guard let savedCapture = group?.captures.first(where: { transfer.sourceCaptureIDs == [$0.id] }),
              savedCapture.records.contains(where: { $0.reference == image.reference
                && $0.source.value == image && $0.preparation.baseKind == .unverified }),
              row.server.observation.value?.candidateStoreID != transfer.destinationStoreID,
              let output = transfer.outputs.first(where: { $0.reference == image.reference }) else { continue }
            if Self.same(actual, try Self.unbasedSource(output)) { completedChoice = row }
          }
        }
      }
      let prior = completedChoice ?? rows.first(where: { $0.issueDigest == digest })
        ?? rows.first(where: { $0.decision.value == nil })
      // Re-fetching the same value in another candidate is not a new server edit.
      let sameComparison = completedChoice != nil || prior?.issueDigest == digest
      let serverExpectation: FailedEnableServerExpectation
      if sameComparison, prior?.decision.value != nil, let prior {
        serverExpectation = prior.server
      } else {
        serverExpectation = FailedEnableServerExpectation.make(state: state,
          observation: .init(observation), acceptedRevisionDigest: .init(try server.map {
            try Self.acceptedRevisionDigest($0,
              namespaceRevision: input.candidate.storage.namespaceState.revision)
          }))
      }
      let hasEarlier = !earlierVersions.isEmpty
      let id: String
      if let prior { id = prior.id }
      else { id = try Self.reviewID(sourceID: input.transition.sourceStoreID,
        reference: image.reference, binding: binding, comparison: digest) }
      result.append(FailedEnableReview.make(id: id,
        reference: image.reference, identity: .init(record.identity),
        reason: hasEarlier ? .earlierLocalVersion : .unknownOutcome,
        issueDigest: completedChoice?.issueDigest ?? digest,
        local: FailedEnableLocalExpectation.make(
          sourceStoreID: FailedEnableEncoding.uuid(input.transition.sourceStoreID),
          sourceRevision: String(input.source.snapshot.revision), sourceDigest: sourceDigest,
          membership: .present, image: .init(image)),
        server: serverExpectation, earlierAlternativeIDs: group?.alternatives.filter {
          $0.reference == image.reference
        }.map(\.id).sorted() ?? [],
        decision: .init(sameComparison ? prior?.decision.value : nil)))
    }
    return result.sorted { $0.reference.sortKey < $1.reference.sortKey }
  }

  func reviewCaptureRecords(_ input: FailedEnablePreparationRead,
    reviews: [FailedEnableReview]
  ) throws -> [FailedEnableRecord] {
    let images = try input.source.images()
    let entries = try CloudDormantAcceptedBaseBundle.decode(input.source.snapshot.opaqueSyncStatePayload)
      .entries.filter { $0.namespaceKey == namespace.namespaceKey.rawValue }
    let affected = Set(reviews.map(\.reference))
    let group = input.evidence?.namespaces.first { $0.binding == FailedEnableBinding(namespace.binding) }
    var records: [FailedEnableRecord] = []
    for image in images {
      let reference = try image.reference.domain
      let needsReview = affected.contains(image.reference)
      let server = input.candidate.storage.readyEntities.first { $0.reference == reference }
      if !needsReview {
        guard let server,
          !input.candidate.storage.conflicts.contains(where: { $0.reference == reference }),
          !input.candidate.storage.pendingDeletes.contains(where: { $0.reference == reference }),
          group?.alternatives.contains(where: { $0.reference == image.reference }) != true else { continue }
        let remote = try Self.fields(server, namespace: namespace.binding)
        let current = try Self.normalizedSource(image, accepted: server)
        guard Self.same(current, remote) else { continue }
        let prior = (group?.captures ?? []).sorted {
          (UInt64($0.ordinal) ?? 0) > (UInt64($1.ordinal) ?? 0)
        }.flatMap(\.records).first { $0.reference == image.reference }
        if let prior {
          guard let observation = prior.observedAccepted.value,
            try qualifies(prior, observation: observation, candidate: nil) else { continue }
        }
      }
      let entry = entries.first { $0.reference == reference }
      let base: CloudAcceptedEntity?
      if let entry {
        let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: entry.payload)
        guard envelope.reference == reference, envelope.identity == entry.identity else {
          throw FailedEnableEvidenceError.unsupported
        }
        base = Self.entity(envelope)
      } else { base = nil }
      let local: FailedEnableFields
      if let server { local = try Self.normalizedSource(image, accepted: server) }
      else { local = try Self.unbasedSource(image) }
      let presence = try server.map(Self.presence) ?? Dictionary(uniqueKeysWithValues:
        Self.keys(reference.kind).map { ($0, FailedEnablePresence.value) })
      let overrides: FailedEnableImmutableOverrides?
      if case .snip(let value) = local {
        overrides = FailedEnableImmutableOverrides(requestID: value.requestID,
          createdAt: value.createdAt, originRaw: value.originRaw)
      } else { overrides = nil }
      let normalization = FailedEnableNormalizedLocal(immutableOverrides: .init(overrides),
        acceptedPresence: presence, defaults: presence.filter { $0.value == .missing }.map(\.key).sorted())
      let q: FailedEnablePreparedValue? = needsReview ? nil : FailedEnablePreparedValue(fields: local,
        presence: Dictionary(uniqueKeysWithValues: Self.keys(reference.kind).map { ($0, .value) }))
      let preparation = FailedEnablePreparation(normalizer: 1,
        classification: needsReview ? .unsupported : .equalFetched,
        knownFields: Self.keys(reference.kind), normalizedLocal: normalization,
        baseKind: needsReview ? .unverified : .equalFetched,
        baseDigest: .init(needsReview ? entry.map { FailedEnableEncoding.digest($0.payload) } : nil),
        fetchedDigest: .init(try server.map {
          try Self.acceptedRevisionDigest($0, namespaceRevision: input.candidate.storage.namespaceState.revision)
        }), value: .init(q), conflictFields: [], recoveryIdentities: [],
        reason: .init(needsReview ? "Automatic preparation is unavailable until the retained comparison is resolved" : nil))
      let observation: FailedEnableObservation?
      if let server {
        observation = FailedEnableObservation(kind: .fullRecord,
          candidateStoreID: FailedEnableEncoding.uuid(input.transition.candidateStoreID),
          namespaceRevision: String(input.candidate.storage.namespaceState.revision),
          localRevision: String(server.localRevision), isDeferred: server.isDeferred,
          hasUnresolvedLegacyAbsence: server.hasUnresolvedLegacyAbsence,
          dependencyListID: .init(server.dependencyListID.map(FailedEnableEncoding.uuid)),
          entityBase64: try Self.existingEnvelope(server))
      } else { observation = nil }
      var record = FailedEnableRecord(reference: image.reference,
        identity: FailedEnableIdentity(server?.identity ?? Self.identity(reference, zone: dataZone)),
        sourceMembership: .present, source: .init(image), originalAcceptedExists: base != nil,
        offlineChanged: try Self.changedFields(base: base.map { try Self.fields($0, namespace: namespace.binding) },
          local: local), preparation: preparation, observedAccepted: .init(nil),
        unqualifiedObservation: .init(observation))
      if !needsReview {
        guard let observation, try qualifies(record, observation: observation, candidate: input.candidate) else { continue }
        record.observedAccepted = .init(observation)
        record.unqualifiedObservation = .init(nil)
      }
      records.append(record)
    }
    return records.sorted { $0.reference.sortKey < $1.reference.sortKey }
  }

  private static func reviewID(sourceID: UUID, reference: FailedEnableReference,
    binding: FailedEnableBinding, comparison: String
  ) throws -> String {
    // A completed choice keeps its comparison identity when a later comparison is needed.
    let bytes = try FailedEnableEncoding.json(binding)
    let hash = FailedEnableEncoding.digest(Data((sourceID.uuidString + reference.sortKey + comparison).utf8) + bytes)
    let hex = String(hash.prefix(32))
    return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.suffix(12))"
  }

  func choices(for review: FailedEnableReview) throws -> [FailedEnableSetupSelection] {
    guard review.reason == .unknownOutcome, review.earlierAlternativeIDs.isEmpty,
      review.local.membership == .present, case .snip? = review.local.image.value
    else { return [] }
    switch review.server.state {
    case .value:
      guard let observation = review.server.observation.value,
        !observation.isDeferred, !observation.hasUnresolvedLegacyAbsence else { return [] }
      let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: observation.entityBase64)
      guard envelope.reference == (try review.reference.domain),
        envelope.identity == review.identity.value?.domain else { return [] }
      _ = try Self.fields(Self.entity(envelope), namespace: namespace.binding)
      return [.useDevice]
    case .deleted:
      return review.server.observation.value == nil ? [.recoverAsNew] : []
    case .unknown, .unavailable: return []
    }
  }

  func serverFields(for reference: FailedEnableReference,
    in candidate: FailedEnableStoreRead
  ) throws -> FailedEnableSetupLocalVersion? {
    let domain = try reference.domain
    guard let accepted = candidate.storage.readyEntities.first(where: { $0.reference == domain }) else { return nil }
    switch try Self.fields(accepted, namespace: namespace.binding) {
    case .snip(let value): return .snip(try Self.reviewSnip(value, attachments: []))
    case .list(let value):
      return .list(SnipList(id: try FailedEnableEncoding.uuid(value.id), desiredName: value.desiredName,
        resolvedName: value.desiredName, systemImage: value.systemImage,
        color: value.colorPreset.value.flatMap(SnipListColorPreset.init(rawValue:)),
        sortKey: try SnipOrderKey(data: value.orderKey)))
    case .absent: return nil
    }
  }

  func decision(for review: FailedEnableReview, selection: FailedEnableSetupSelection,
    outputIDs: [FailedEnableCopyIDs]
  ) throws -> FailedEnableReviewDecision {
    guard try choices(for: review).contains(selection),
      let choice = FailedEnableReviewChoice(rawValue: selection.rawValue) else {
      throw FailedEnableSetupReviewReadError.choiceUnavailable
    }
    return FailedEnableReviewDecision.make(choice: choice, fieldMask: Self.reviewedSnipFields,
      selectedImage: review.local.image, outputIDs: outputIDs, resolvedAlternativeIDs: [])
  }

  static func reviewSnip(_ value: FailedEnableSnipValue, attachments: [SnipAttachment]) throws -> Snip {
    let fields = try Self.snip(value)
    guard let origin = SnipOrigin(rawValue: fields.originRaw) else {
      throw FailedEnableEvidenceError.unsupported
    }
    return Snip(id: fields.id, requestID: fields.requestID, createdAt: fields.createdAt,
      updatedAt: fields.updatedAt, content: fields.text, origin: origin,
      source: fields.source, listID: fields.placement.listID, isDone: fields.isDone,
      pinnedAt: fields.pinnedAt, manualSortKey: fields.placement.orderKey, attachments: attachments)
  }

  func applyingReviews(_ reviews: [FailedEnableReview], to automatic: CloudFullReenableApplyPlan,
    input: FailedEnablePreparationRead
  ) throws -> CloudFullReenableApplyPlan {
    var snips = automatic.snips
    var bytes = automatic.attachmentData
    var approved = automatic.result.approvedSnipIDs
    var recovered = automatic.result.recoveredSourceSnipIDs
    for review in reviews {
      guard let decision = review.decision.value,
        try choices(for: review).contains(where: { $0.rawValue == decision.choice.rawValue }),
        decision.selectedImage.value == review.local.image.value,
        decision.fieldMask == Self.reviewedSnipFields,
        case .snip(let image)? = decision.selectedImage.value else {
        throw FailedEnableEvidenceError.reviewRequired
      }
      let reference = try review.reference.domain
      var snip = try image.domain
      if decision.choice == .useDevice {
        guard let server = input.candidate.storage.readyEntities.first(where: {
          $0.reference == reference
        }) else { throw FailedEnableEvidenceError.changed }
        snip = try Self.reviewSnip(Self.normalizedSource(.snip(image), accepted: server).snipValue,
          attachments: snip.attachments)
      } else {
        guard decision.outputIDs.count == 1, let map = decision.outputIDs.first,
          map.original == review.reference, map.output.kind == .snip,
          let request = map.requestID.value else { throw FailedEnableEvidenceError.unsupported }
        let attachmentMap = Dictionary(uniqueKeysWithValues: map.attachments.map { ($0.originalID, $0.newID) })
        var attachments: [SnipAttachment] = []
        for old in image.attachments {
          guard let newID = attachmentMap[old.id], let data = input.evidence?.blobs[old.availability.sha256]
          else { throw FailedEnableEvidenceError.unavailable }
          let id = try FailedEnableEncoding.uuid(newID)
          bytes[id] = data
          let oldDomain = try old.domain
          attachments.append(SnipAttachment(id: id, fileName: old.fileName,
            relativePath: "\(id.uuidString)/\(URL(fileURLWithPath: old.fileName).lastPathComponent)",
            contentType: old.contentType.value, byteCount: oldDomain.byteCount))
        }
        let listID = automatic.lists.contains(where: { $0.id == snip.listID }) ? snip.listID : SnipList.inbox.id
        snip = Snip(id: try map.output.domain.domainID, requestID: try FailedEnableEncoding.uuid(request),
          createdAt: snip.createdAt, updatedAt: snip.updatedAt, content: snip.content,
          origin: snip.origin, source: snip.source, listID: listID, isDone: snip.isDone,
          pinnedAt: snip.pinnedAt, manualSortKey: snip.manualSortKey, attachments: attachments)
        recovered.insert(try review.reference.domain.domainID)
      }
      if decision.choice == .recoverAsNew,
        let existing = input.candidate.snapshot.snips.first(where: { $0.id == snip.id }) {
        guard existing == snip, existing.attachments.allSatisfy({ attachment in
          input.candidate.snapshot.attachmentData[attachment.id] == bytes[attachment.id]
        }) else { throw FailedEnableEvidenceError.reviewRequired }
      }
      let original = reference.domainID
      snips.removeAll { $0.id == original || $0.id == snip.id }
      snips.append(snip)
      approved.insert(snip.id)
    }
    return try CloudFullReenableApplyPlan(transitionID: automatic.transitionID,
      namespaceKey: automatic.namespaceKey, expectedNamespaceRevision: automatic.expectedNamespaceRevision,
      targetRevision: automatic.targetRevision, targetDigest: automatic.targetDigest,
      snips: snips, lists: automatic.lists, attachmentData: bytes,
      dormantPayload: automatic.dormantPayload, acceptedCAS: automatic.acceptedCAS,
      conflicts: automatic.conflicts, recoveryInputs: automatic.recoveryInputs,
      result: SnipLibraryTransferResult(approvedSnipIDs: approved, recoveredSourceSnipIDs: recovered))
  }

  func validateReviewedOutcomes(capture: FailedEnableCapture, candidate: FailedEnableStoreRead,
    evidence: FailedEnableInstalledEvidence, requiresAccepted: Bool
  ) throws {
    guard let group = evidence.namespaces.first(where: { $0.binding == FailedEnableBinding(namespace.binding) }),
      group.alternatives.isEmpty,
      Set(group.reviews.map(\.reference)).isSubset(of: Set(capture.records.filter {
        $0.preparation.baseKind == .unverified
      }.map(\.reference))),
      let transfer = evidence.transfers.last(where: {
        $0.kind == .candidate && $0.sourceCaptureIDs == [capture.id] && $0.state == .checked
          && $0.destinationStoreID == capture.candidateStoreID
      }) else { throw FailedEnableEvidenceError.reviewRequired }
    let images = try candidate.images()
    for record in capture.records where record.preparation.baseKind == .unverified {
      var covered = false
      for review in group.reviews where review.reference == record.reference {
        guard let decision = review.decision.value,
          review.local.sourceDigest == capture.sourceDigest,
          review.local.sourceRevision == capture.freeze.sourceRevision,
          decision.selectedImage.value == review.local.image.value,
          record.source.value == review.local.image.value,
          try choices(for: review).contains(where: { $0.rawValue == decision.choice.rawValue }) else { continue }
        let output = decision.choice == .recoverAsNew ? decision.outputIDs.first?.output : review.reference
        guard let output, let planned = transfer.outputs.first(where: { $0.reference == output }),
          let actual = images.first(where: { $0.reference == output }), actual == planned else { continue }
        let reference = try output.domain
        guard !candidate.storage.conflicts.contains(where: { $0.reference == reference }),
          !candidate.storage.pendingDeletes.contains(where: { $0.reference == reference }) else {
          throw FailedEnableEvidenceError.reviewRequired
        }
        if decision.choice == .recoverAsNew {
          let original = try review.reference.domain
          guard !candidate.snapshot.snips.contains(where: { $0.id == original.domainID }),
            !candidate.storage.readyEntities.contains(where: { $0.reference == original }) else { continue }
        }
        if let accepted = candidate.storage.readyEntities.first(where: { $0.reference == reference }) {
          let value = try Self.fields(accepted, namespace: namespace.binding)
          let q = try Self.unbasedSource(planned)
          let matchesOutput = Self.same(value, q)
          let envelope = try Self.existingEnvelope(accepted)
          let matchesPreimage = review.server.observation.value?.entityBase64 == envelope
          guard matchesOutput || (!requiresAccepted && decision.choice == .useDevice && matchesPreimage) else { continue }
          if requiresAccepted, let dependency = accepted.dependencyListID {
            guard candidate.storage.readyEntities.contains(where: {
              $0.reference == CloudEntityReference(kind: .list, domainID: dependency)
            }) else { throw FailedEnableEvidenceError.reviewRequired }
          }
        } else {
          guard !requiresAccepted, decision.choice == .recoverAsNew else { continue }
        }
        covered = true
        break
      }
      guard covered else { throw FailedEnableEvidenceError.reviewRequired }
    }
  }

}

private extension FailedEnableFields {
  var snipValue: FailedEnableSnipValue {
    get throws {
      guard case .snip(let value) = self else { throw FailedEnableEvidenceError.unsupported }
      return value
    }
  }
}
