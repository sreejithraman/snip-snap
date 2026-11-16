import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  func failedEnableSetupReviewSnapshot() async throws -> FailedEnableSetupReviewSnapshot {
    let preimage = manifest
    let policy = failedEnableSemantics
    let registration = failedEnableSemanticRegistration
    let accountAvailable = await failedEnableAccountCheck?() == true
    guard manifest == preimage, failedEnableSemanticRegistration == registration,
      failedEnableSemantics?.reviewNamespace == policy?.reviewNamespace else {
      throw FailedEnableSetupReviewReadError.staleComparison
    }
    let activeID = manifest.activeStoreID
    var currentIssueIDs: Set<String> = []
    var currentFields: [String: FailedEnableSetupLocalVersion] = [:]
    if accountAvailable, let policy, let transition = manifest.transition,
      transition.sourceStoreID == activeID, transition.namespace == policy.reviewNamespace {
      do {
        let checked = try await withFailedEnableRead(transition: transition) { source, candidate in
          let evidence = try self.failedEnableFiles.read(activeID)
          guard try self.failedEnableContinuityMatches(evidence, source: source, sourceID: activeID) else {
            throw FailedEnableSetupReviewReadError.staleComparison
          }
          let drafts = try policy.reviewDrafts(FailedEnableReviewRead(source: source, candidate: candidate,
            transition: transition, evidence: evidence))
          let stored = evidence?.namespaces.first {
            $0.binding == FailedEnableBinding(policy.reviewNamespace)
          }?.reviews ?? []
          let rows = drafts.filter { draft in stored.contains {
            $0.id == draft.id && $0.issueDigest == draft.issueDigest && $0.local == draft.local
          } }
          var fields: [String: FailedEnableSetupLocalVersion] = [:]
          for row in rows {
            if let value = try policy.serverFields(for: row.reference, in: candidate) { fields[row.id] = value }
          }
          return FailedEnableSetupCheckedComparison(ids: Set(rows.map(\.id)), fields: fields)
        }
        currentIssueIDs = checked.ids
        currentFields = checked.fields
      } catch {
        // Local saved versions remain readable when the candidate cannot supply a checked comparison.
        currentIssueIDs = []
      }
    }
    guard failedEnableSemanticRegistration == registration else {
      throw FailedEnableSetupReviewReadError.staleComparison
    }
    do {
      var issues: [FailedEnableSetupIssue] = []
      var ids: Set<UUID> = []
      for sourceID in Set(failedEnableSourceIDs() + [activeID]).sorted(by: { $0.uuidString < $1.uuidString }) {
        guard let bundle = try failedEnableFiles.read(sourceID) else { continue }
        guard sourceID == activeID || bundle.transfers.contains(where: {
          $0.destinationStoreID == FailedEnableEncoding.uuid(activeID) && $0.state == .checked
        }) else { continue }
        for group in bundle.namespaces {
          let groupNamespace = try group.binding.domain
          let sameCloudScope = accountAvailable && manifest.accountIsolation == nil
            && policy?.reviewNamespace == groupNamespace
          for review in group.reviews {
            let cloudAvailable = sameCloudScope && currentIssueIDs.contains(review.id)
            let id = try FailedEnableEncoding.uuid(review.id)
            guard ids.insert(id).inserted,
              review.local.sourceStoreID == FailedEnableEncoding.uuid(sourceID),
              let reason = FailedEnableSetupReviewReason(rawValue: review.reason.rawValue)
            else { throw FailedEnableSetupReviewReadError.evidenceUnavailable }
            let local = try review.local.image.value.map(Self.setupLocalVersion)
            var earlier: [FailedEnableImage] = group.alternatives.filter {
              review.earlierAlternativeIDs.contains($0.id)
            }.compactMap(\.image.value)
            for previous in group.reviews where previous.reference == review.reference {
              if let image = previous.local.image.value, image != review.local.image.value,
                !earlier.contains(image) { earlier.append(image) }
              if previous.id != review.id {
                for map in previous.decision.value?.outputIDs ?? [] {
                  for transfer in bundle.transfers {
                    if let image = transfer.outputs.first(where: { $0.reference == map.output }),
                      !earlier.contains(image) { earlier.append(image) }
                  }
                }
              }
            }
            for capture in group.captures {
              for record in capture.records where record.reference == review.reference {
                if let image = record.source.value, image != review.local.image.value,
                  !earlier.contains(image) { earlier.append(image) }
              }
            }
            let choices: [FailedEnableSetupSelection]
            if cloudAvailable, sourceID == activeID, earlier.isEmpty,
              manifest.transition?.freezesSource != true,
              bundle.continuity.state == .verified, bundle.continuity.inFlight.value == nil,
              !failedEnableUncertainSources.contains(sourceID),
              review.local.sourceRevision == String(store(id: activeID)?.revision ?? UInt64.max),
              let policy {
              choices = try policy.choices(for: review)
            } else { choices = [] }
            let state: FailedEnableSetupServerState = if !cloudAvailable { .unavailable }
              else if currentFields[review.id] != nil { .value }
              else { .absent }
            let server = cloudAvailable ? currentFields[review.id] : nil
            let selection = try review.decision.value.map { try Self.setupReceipt(review: review, decision: $0) }
            issues.append(FailedEnableSetupIssue(id: id,
              entityID: try Self.setupEntityID(review.reference), reason: reason,
              localVersionAtReview: local, earlierLocalVersions: try earlier.map(Self.setupLocalVersion),
              serverState: state, serverFieldsAtReview: server, allowedChoices: choices,
              expectation: FailedEnableSetupExpectation(sourceStoreID: sourceID, issueID: id,
                issueDigest: review.issueDigest, sequence: bundle.sequence), selection: selection))
          }
        }
      }
      return FailedEnableSetupReviewSnapshot(sourceStoreID: activeID,
        issues: issues.sorted { $0.id.uuidString < $1.id.uuidString })
    } catch {
      throw FailedEnableSetupReviewReadError.evidenceUnavailable
    }
  }

  func chooseFailedEnableSetupReview(_ issueID: UUID, selection: FailedEnableSetupSelection,
    expecting expectation: FailedEnableSetupExpectation
  ) async throws -> FailedEnableSetupSelectionReceipt {
    guard let policy = failedEnableSemantics, let check = failedEnableAccountCheck,
      manifest.accountIsolation == nil else { throw FailedEnableSetupReviewReadError.accountUnavailable }
    let preimage = manifest
    let registration = failedEnableSemanticRegistration
    guard await check() else { throw FailedEnableSetupReviewReadError.accountUnavailable }
    guard manifest == preimage, failedEnableSemanticRegistration == registration,
      failedEnableSemantics?.reviewNamespace == policy.reviewNamespace,
      expectation.sourceStoreID == manifest.activeStoreID, expectation.issueID == issueID,
      let transition = manifest.transition, !transition.freezesSource,
      transition.sourceStoreID == manifest.activeStoreID,
      transition.namespace == policy.reviewNamespace
    else { throw FailedEnableSetupReviewReadError.staleComparison }
    return try await withFailedEnableRead(transition: transition) { source, candidate in
      guard self.failedEnableSemanticRegistration == registration else {
        throw FailedEnableSetupReviewReadError.staleComparison
      }
      let sourceID = self.manifest.activeStoreID
      guard let bundle = try self.failedEnableFiles.read(sourceID),
        let groupIndex = bundle.namespaces.firstIndex(where: {
          $0.binding == FailedEnableBinding(policy.reviewNamespace)
        }),
        let index = bundle.namespaces[groupIndex].reviews.firstIndex(where: {
          $0.id == FailedEnableEncoding.uuid(issueID)
        }) else { throw FailedEnableSetupReviewReadError.staleComparison }
      let review = bundle.namespaces[groupIndex].reviews[index]
      let current = try policy.reviewDrafts(FailedEnableReviewRead(source: source, candidate: candidate,
        transition: transition, evidence: bundle))
      guard current.contains(where: {
        $0.id == review.id && $0.issueDigest == review.issueDigest && $0.local == review.local
      }) else { throw FailedEnableSetupReviewReadError.staleComparison }
      let digest = try source.sourceDigest(sourceID: sourceID)
      let sourceImages = try source.images()
      guard try self.failedEnableContinuityMatches(bundle, source: source, sourceID: sourceID),
        sourceImages.first(where: { $0.reference == review.reference }) == review.local.image.value,
        review.issueDigest == expectation.issueDigest,
        review.local.sourceDigest == digest,
        review.local.sourceRevision == String(source.snapshot.revision)
      else { throw FailedEnableSetupReviewReadError.staleComparison }
      if let chosen = review.decision.value {
        guard chosen.choice.rawValue == selection.rawValue else {
          throw FailedEnableSetupReviewReadError.staleComparison
        }
        return try Self.setupReceipt(review: review, decision: chosen)
      }
      guard bundle.sequence == expectation.sequence,
        try policy.choices(for: review).contains(selection) else {
        throw FailedEnableSetupReviewReadError.staleComparison
      }
      var outputs: [FailedEnableCopyIDs] = []
      if selection == .recoverAsNew {
        guard case .snip(let image)? = review.local.image.value else {
          throw FailedEnableSetupReviewReadError.choiceUnavailable
        }
        let knownSnips = source.snapshot.snips + candidate.snapshot.snips
        var used = Set(knownSnips.flatMap { [$0.id, $0.requestID] }
          + (source.snapshot.lists + candidate.snapshot.lists).map(\.id)
          + knownSnips.flatMap(\.attachments).map(\.id)
          + candidate.storage.readyEntities.map { $0.reference.domainID })
        for namespace in bundle.namespaces {
          for row in namespace.reviews {
            for output in row.decision.value?.outputIDs ?? [] {
              used.insert(try output.output.domain.domainID)
              if let request = output.requestID.value { used.insert(try FailedEnableEncoding.uuid(request)) }
              for attachment in output.attachments { used.insert(try FailedEnableEncoding.uuid(attachment.newID)) }
            }
          }
        }
        func freshID() -> String {
          var id = UUID()
          while !used.insert(id).inserted { id = UUID() }
          return FailedEnableEncoding.uuid(id)
        }
        let outputID = freshID()
        let requestID = freshID()
        let attachments = image.attachments.map {
          FailedEnableAttachmentCopyID(originalID: $0.id, newID: freshID())
        }
        outputs = [FailedEnableCopyIDs(original: review.reference,
          output: FailedEnableReference(CloudEntityReference(kind: .snip,
            domainID: try FailedEnableEncoding.uuid(outputID))),
          requestID: .init(requestID), attachments: attachments)]
      }
      let decision = try policy.decision(for: review, selection: selection, outputIDs: outputs)
      try self.failedEnableFiles.update(sourceID) { current in
        guard var current, current == bundle else { throw FailedEnableSetupReviewReadError.staleComparison }
        current.namespaces[groupIndex].reviews[index] = Self.setupReview(review, decision: decision)
        return current
      }
      try self.crashHook(.afterFailedEnableReviewDecision)
      return try Self.setupReceipt(review: review, decision: decision)
    }
  }

  func keepFailedEnableSetupLocalOnly() throws {
    guard store(id: manifest.activeStoreID)?.kind == .localOnly else {
      throw FailedEnableSetupReviewReadError.choiceUnavailable
    }
    guard manifest.transition?.syncProtocol != .legacyTextV1 else {
      throw FailedEnableSetupReviewReadError.choiceUnavailable
    }
    guard writeAdmissionIsIdle(), failedEnablePublicationInFlight == nil,
      failedEnableSendInFlight == nil, fullReenableMergeInFlight == nil else {
      throw SyncModePersistenceError.transitionInProgress
    }
    // The retention guard keeps all reviewed candidate roots, including sole accepted bytes.
    // Cancel does not qualify observations or finish a pending candidate apply.
    try cancelPendingICloudEnable()
  }

  package func prepareFailedEnableReviewContinuation() async throws {
    guard let transition = manifest.transition, transition.sourceStoreID == manifest.activeStoreID,
      transition.phase != .pointerSwapped, transition.syncProtocol == .fullRecordV1,
      let policy = failedEnableSemantics,
      transition.namespace == policy.reviewNamespace,
      let bundle = try failedEnableFiles.read(transition.sourceStoreID),
      let group = bundle.namespaces.first(where: { $0.binding == FailedEnableBinding(policy.reviewNamespace) }),
      !group.reviews.isEmpty else { return }
    let preimage = manifest
    let registration = failedEnableSemanticRegistration
    guard await failedEnableAccountCheck?() == true else {
      throw FailedEnableSetupReviewReadError.accountUnavailable
    }
    guard manifest == preimage, failedEnableSemanticRegistration == registration else {
      throw FailedEnableEvidenceError.changed
    }
    let reset = try await withFailedEnableRead(transition: transition) { source, candidate in
      guard self.failedEnableSemanticRegistration == registration,
        try self.failedEnableFiles.read(transition.sourceStoreID) == bundle else {
        throw FailedEnableEvidenceError.changed
      }
      let rows = try policy.reviewDrafts(FailedEnableReviewRead(source: source, candidate: candidate,
        transition: transition, evidence: bundle))
      guard !rows.isEmpty, rows.allSatisfy({ $0.decision.value != nil }) else { return false }
      for row in rows {
        guard let chosen = row.decision.value,
          let selection = FailedEnableSetupSelection(rawValue: chosen.choice.rawValue),
          try policy.choices(for: row).contains(selection) else { return false }
      }
      guard let capture = group.captures.last(where: {
        $0.candidateStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
      }) else { return false }
      let transfer = bundle.transfers.last { $0.sourceCaptureIDs == [capture.id] }
      let isChosenPlan = rows.allSatisfy { review in
        guard let decision = review.decision.value else { return false }
        if decision.choice == .useDevice {
          return review.server.observation.value?.candidateStoreID != capture.candidateStoreID
        }
        return decision.outputIDs.allSatisfy { map in
          transfer?.outputs.contains(where: { $0.reference == map.output }) == true
        }
      }
      return !isChosenPlan
    }
    guard reset else { return }
    guard !transition.hasDurableFullReenableIntent else { throw FailedEnableEvidenceError.reviewRequired }
    // All roots stay retained. Fresh preparation cannot inherit insertion-only conflict rows.
    try abortUnactivatedCandidate(reason: nil)
  }

  func publishFailedEnableReviews(_ drafts: [FailedEnableReview],
    input: FailedEnablePreparationRead, captureRecords: [FailedEnableRecord]?
  ) throws {
    guard !drafts.isEmpty else { return }
    guard let namespace = input.transition.namespace else { throw FailedEnableEvidenceError.changed }
    let sourceID = input.transition.sourceStoreID
    let digest = try input.source.sourceDigest(sourceID: sourceID)
    let images = try input.source.images()
    let newBlobs = try failedEnableBlobs(images: images, bytes: input.source.snapshot.attachmentData)
    try failedEnableFiles.update(sourceID) { old in
      guard old == input.evidence else { throw FailedEnableEvidenceError.changed }
      var bundle = old ?? self.newFailedEnableBundle(sourceID: sourceID, source: input.source, digest: digest)
      let binding = FailedEnableBinding(namespace)
      if !bundle.namespaces.contains(where: { $0.binding == binding }) {
        bundle.namespaces.append(FailedEnableNamespace(binding: binding, captures: [], alternatives: [], reviews: []))
      }
      guard let groupIndex = bundle.namespaces.firstIndex(where: { $0.binding == binding }) else {
        throw FailedEnableEvidenceError.changed
      }
      var group = bundle.namespaces[groupIndex]
      for draft in drafts {
        if let previous = group.reviews.first(where: { $0.id == draft.id }),
          let image = previous.local.image.value, image != draft.local.image.value,
          !group.captures.flatMap(\.records).contains(where: { $0.source.value == image }),
          !group.alternatives.contains(where: { $0.image.value == image }) {
          let hashes: [String]
          if case .snip(let snip) = image { hashes = Array(Set(snip.attachments.map(\.availability.sha256))).sorted() }
          else { hashes = [] }
          group.alternatives.append(FailedEnableAlternative(id: FailedEnableEncoding.uuid(UUID()),
            reference: image.reference, image: .init(image), reason: .earlierLocalEdit,
            conflict: .init(nil), opaqueHistoricalBytes: .init(nil), attachmentHashes: hashes))
        }
        let earlier = group.alternatives.filter { $0.reference == draft.reference }.map(\.id).sorted()
        let row = Self.setupReview(draft, decision: earlier.isEmpty ? draft.decision.value : nil,
          earlier: earlier)
        group.reviews.removeAll { $0.id == row.id }
        group.reviews.append(row)
      }
      group.reviews.sort {
        ($0.reference.sortKey, $0.id) < ($1.reference.sortKey, $1.id)
      }
      if let records = captureRecords {
        let id = FailedEnableEncoding.uuid(UUID())
        struct Binding: Encodable {
          let captureID: String
          let sourceDigest: String
          let namespace: FailedEnableBinding
          let syncProtocol: SyncModeSyncProtocol
          let predecessors: [String]
          let records: [FailedEnableRecord]
          let candidateDeletes: [FailedEnableCandidateDelete]
        }
        let preparationDigest = try FailedEnableEncoding.digest(Binding(captureID: id,
          sourceDigest: digest, namespace: binding, syncProtocol: input.transition.syncProtocol,
          predecessors: [], records: records, candidateDeletes: []))
        let ordinal = try bundle.namespaces.flatMap(\.captures).map {
          try FailedEnableEncoding.revision($0.ordinal)
        }.max() ?? 0
        guard ordinal < UInt64.max else { throw FailedEnableEvidenceError.unsupported }
        group.captures.append(FailedEnableCapture(id: id, ordinal: String(ordinal + 1),
          transitionID: FailedEnableEncoding.uuid(input.transition.id),
          candidateStoreID: FailedEnableEncoding.uuid(input.transition.candidateStoreID),
          syncProtocol: input.transition.syncProtocol,
          freeze: FailedEnableFreeze(id: FailedEnableEncoding.uuid(input.token.id),
            sourceRevision: String(input.token.revision)),
          seenRequestIDs: input.source.seenRequestIDs.map(FailedEnableEncoding.uuid).sorted(),
          sourceDigest: digest, normalizer: 1, preparationDigest: preparationDigest,
          predecessors: [], armed: false, records: records, candidateDeletes: []))
      }
      bundle.namespaces[groupIndex] = group
      bundle.blobs.merge(newBlobs) { old, _ in old }
      return bundle
    }
  }

  static func setupReview(_ review: FailedEnableReview, decision: FailedEnableReviewDecision?,
    earlier: [String]? = nil
  ) -> FailedEnableReview {
    FailedEnableReview(id: review.id, reference: review.reference, identity: review.identity,
      reason: review.reason, issueDigest: review.issueDigest, local: review.local, server: review.server,
      earlierAlternativeIDs: earlier ?? review.earlierAlternativeIDs, decision: .init(decision))
  }

  func hasFailedEnableReviewDecision(_ record: FailedEnableRecord,
    capture: FailedEnableCapture, bundle: FailedEnableInstalledEvidence
  ) -> Bool {
    guard let transition = manifest.transition,
      let group = bundle.namespaces.first(where: { $0.binding == transition.namespace.map(FailedEnableBinding.init) }),
      record.preparation.baseKind == .unverified,
      let transfer = bundle.transfers.last(where: {
        $0.sourceCaptureIDs == [capture.id] && $0.state == .checked
          && $0.destinationStoreID == capture.candidateStoreID
      }) else { return false }
    return group.reviews.contains { review in
      guard review.reference == record.reference, let decision = review.decision.value,
        record.source.value == review.local.image.value,
        decision.selectedImage.value == record.source.value,
        review.local.sourceDigest == capture.sourceDigest,
        review.local.sourceRevision == capture.freeze.sourceRevision,
        review.earlierAlternativeIDs.isEmpty, decision.resolvedAlternativeIDs.isEmpty else { return false }
      if decision.choice == .useDevice {
        return review.server.state == .value && transfer.outputs.contains(where: { $0.reference == record.reference })
      }
      return decision.choice == .recoverAsNew && review.server.state == .deleted
        && decision.outputIDs.count == 1 && decision.outputIDs.allSatisfy { map in
          map.original == record.reference && transfer.outputs.contains(where: { $0.reference == map.output })
        }
    }
  }

  func failedEnableReviewSourceMap(plan: CloudFullReenableApplyPlan) throws -> [UUID: UUID] {
    guard let transition = manifest.transition,
      let bundle = try failedEnableFiles.read(transition.sourceStoreID),
      let group = bundle.namespaces.first(where: { $0.binding == transition.namespace.map(FailedEnableBinding.init) })
    else { return [:] }
    var result: [UUID: UUID] = [:]
    for review in group.reviews {
      for map in review.decision.value?.outputIDs ?? [] {
        let output = try map.output.domain
        guard plan.snips.contains(where: { $0.id == output.domainID }) else { continue }
        let source = try map.original.domain
        guard source == (try review.reference.domain), source.kind == .snip, output.kind == .snip,
          plan.snips.contains(where: { $0.id == output.domainID }),
          result.updateValue(source.domainID, forKey: output.domainID) == nil else {
          throw FailedEnableEvidenceError.changed
        }
      }
    }
    return result
  }

  static func setupEntityID(_ reference: FailedEnableReference) throws -> FailedEnableSetupEntityID {
    let value = try reference.domain
    return value.kind == .snip ? .snip(value.domainID) : .list(value.domainID)
  }

  static func setupLocalVersion(_ image: FailedEnableImage) throws -> FailedEnableSetupLocalVersion {
    switch image {
    case .snip(let snip): return .snip(try snip.domain)
    case .list(let list): return .list(try list.domain)
    }
  }

  static func setupReceipt(review: FailedEnableReview,
    decision: FailedEnableReviewDecision
  ) throws -> FailedEnableSetupSelectionReceipt {
    guard let selection = FailedEnableSetupSelection(rawValue: decision.choice.rawValue) else {
      throw FailedEnableSetupReviewReadError.choiceUnavailable
    }
    let outputs = try decision.outputIDs.map { map in
      FailedEnableSetupOutputIDs(original: try setupEntityID(map.original),
        output: try setupEntityID(map.output),
        requestID: try map.requestID.value.map(FailedEnableEncoding.uuid),
        attachments: try map.attachments.map {
          FailedEnableSetupAttachmentIDs(originalID: try FailedEnableEncoding.uuid($0.originalID),
            outputID: try FailedEnableEncoding.uuid($0.newID))
        })
    }
    return FailedEnableSetupSelectionReceipt(issueID: try FailedEnableEncoding.uuid(review.id),
      selection: selection, outputs: outputs)
  }
}

// Value construction only. Publication remains private to the durable owner above.
extension FailedEnableLocalExpectation {
  package static func make(sourceStoreID: String, sourceRevision: String, sourceDigest: String,
    membership: FailedEnableMembership, image: FailedEnableNullable<FailedEnableImage>
  ) -> Self {
    Self(sourceStoreID: sourceStoreID, sourceRevision: sourceRevision, sourceDigest: sourceDigest,
      membership: membership, image: image)
  }
}

extension FailedEnableServerExpectation {
  package static func make(state: FailedEnableServerState,
    observation: FailedEnableNullable<FailedEnableObservation>,
    acceptedRevisionDigest: FailedEnableNullable<String>
  ) -> Self {
    Self(state: state, observation: observation, acceptedRevisionDigest: acceptedRevisionDigest)
  }
}

extension FailedEnableReviewDecision {
  package static func make(choice: FailedEnableReviewChoice, fieldMask: [String],
    selectedImage: FailedEnableNullable<FailedEnableImage>, outputIDs: [FailedEnableCopyIDs],
    resolvedAlternativeIDs: [String]
  ) -> Self {
    Self(choice: choice, fieldMask: fieldMask, selectedImage: selectedImage,
      outputIDs: outputIDs, resolvedAlternativeIDs: resolvedAlternativeIDs)
  }
}

extension FailedEnableReview {
  package static func make(id: String, reference: FailedEnableReference,
    identity: FailedEnableNullable<FailedEnableIdentity>, reason: FailedEnableReviewReason,
    issueDigest: String, local: FailedEnableLocalExpectation, server: FailedEnableServerExpectation,
    earlierAlternativeIDs: [String], decision: FailedEnableNullable<FailedEnableReviewDecision>
  ) -> Self {
    Self(id: id, reference: reference, identity: identity, reason: reason, issueDigest: issueDigest,
      local: local, server: server, earlierAlternativeIDs: earlierAlternativeIDs, decision: decision)
  }
}

private struct FailedEnableSetupCheckedComparison: Sendable {
  let ids: Set<String>
  let fields: [String: FailedEnableSetupLocalVersion]
}
