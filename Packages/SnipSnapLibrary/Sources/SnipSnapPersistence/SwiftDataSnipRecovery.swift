import Foundation
import SnipSnapCore
import SwiftData

private struct StoredSnipRecoveryReview: Codable, Equatable {
  let storageVersion: Int
  let conflictKey: String
  let recovery: SnipRecoveryRecord

  init(conflictKey: String, recovery: SnipRecoveryRecord) {
    storageVersion = 1
    self.conflictKey = conflictKey
    self.recovery = recovery
  }
}

extension SwiftDataSnipLibrary {
  private static let recoveryReviewPrefix = "review-recovery-"

  static func insertRecoveryReviewIfNeeded(
    _ recovery: SnipRecoveryRecord,
    namespaceKey: String,
    conflictKey: String,
    context: ModelContext
  ) throws {
    try validate(recovery)
    let eventKey = recoveryEventKey(recovery.id)
    let payload = try recoveryReviewData(
      StoredSnipRecoveryReview(conflictKey: conflictKey, recovery: recovery)
    )
    if let current = try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
      .first(where: { $0.namespaceKey == namespaceKey && $0.eventKey == eventKey })
    {
      guard current.payload == payload else { throw CloudFullStorageError.invalidConflictReplay }
      return
    }
    context.insert(
      StoredCloudRecoveryEvent(
        namespaceKey: namespaceKey,
        eventKey: eventKey,
        payload: payload
      )
    )
  }

  public func recoverySnapshot(in scope: SnipRecoveryScope) async throws -> SnipRecoverySnapshot {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let reviews = try Self.recoveryReviews(namespaceKey: scope.rawValue, context: context)
      .map(\.recovery)
    let snips = reviews.compactMap { review -> RecoveredSnip? in
      guard case .snip(let item) = review else { return nil }
      return item
    }
    let lists = reviews.compactMap { review -> RecoveredListEdit? in
      guard case .list(let item) = review else { return nil }
      return item
    }
    return SnipRecoverySnapshot(
      pendingSnips: snips.filter { $0.state == .pending }.sorted {
        $0.id.uuidString < $1.id.uuidString
      },
      promotedSnips: snips.filter { $0.state == .promoted }.sorted {
        $0.id.uuidString < $1.id.uuidString
      },
      pendingLists: lists.sorted { $0.id.uuidString < $1.id.uuidString }
    )
  }

  @discardableResult
  public func resolveRecovery(
    _ id: UUID,
    in scope: SnipRecoveryScope,
    choice: SnipRecoveryChoice
  ) async throws -> SnipLibrarySnapshot {
    guard let container, isAvailable else { throw SnipLibraryError.storeUnavailable }
    do {
      let lock = try SnipStoreFileLock(url: lockURL)
      defer { withExtendedLifetime(lock) {} }
      let context = Self.makeContext(container: container)
      guard let event = try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
        .first(where: {
          $0.namespaceKey == scope.rawValue && $0.eventKey == Self.recoveryEventKey(id)
        })
      else { throw SnipLibraryError.recoveryNotFound }
      let review = try Self.recoveryReview(from: event)
      guard review.recovery.id == id else { throw SnipLibraryError.recoveryChanged }
      let conflictID = StoredCloudFullConflict.key(
        namespaceKey: scope.rawValue,
        conflictKey: review.conflictKey
      )
      guard let conflict = try context.fetch(FetchDescriptor<StoredCloudFullConflict>())
        .first(where: { $0.id == conflictID })
      else { throw SnipLibraryError.recoveryChanged }

      let loaded = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
      var state = loaded.state
      var promotedReview: RecoveredSnip?
      switch review.recovery {
      case .snip(let recovery):
        guard recovery.state == .pending,
          conflict.kind == CloudEntityKind.snip.rawValue,
          conflict.domainID == recovery.currentSnipID
        else { throw SnipLibraryError.recoveryChanged }
        try Self.resolve(
          recovery,
          choice: choice,
          state: &state,
          promotedReview: &promotedReview
        )
      case .list(let recovery):
        guard conflict.kind == CloudEntityKind.list.rawValue,
          conflict.domainID == recovery.currentListID
        else { throw SnipLibraryError.recoveryChanged }
        try Self.resolve(recovery, choice: choice, state: &state)
      }

      try Self.validate(state)
      try Self.applyChanges(from: loaded, to: state, context: context)
      context.delete(conflict)
      if let promotedReview {
        event.payload = try Self.recoveryReviewData(
          StoredSnipRecoveryReview(
            conflictKey: review.conflictKey,
            recovery: .snip(promotedReview)
          )
        )
      } else {
        context.delete(event)
      }
      try afterMutationBeforeSave()
      try context.save()
      seenRequestIDs = state.seenRequestIDs
      lastKnownState = state
      rememberAttachments(in: state)
    } catch {
      throw error
    }
    return try await checkedSnapshot(sortedBy: .chronological)
  }

  private static func resolve(
    _ recovery: RecoveredSnip,
    choice: SnipRecoveryChoice,
    state: inout SnipLibraryState,
    promotedReview: inout RecoveredSnip?
  ) throws {
    guard let index = state.snips.firstIndex(where: { $0.id == recovery.currentSnipID }) else {
      throw SnipLibraryError.snipNotFound
    }
    let provisional = state.snips.first { $0.id == recovery.id }
    if let provisional, provisional != recovery.recovered {
      throw SnipLibraryError.recoveryChanged
    }
    switch choice {
    case .keepCurrent:
      state.snips.removeAll { $0.id == recovery.id }
      return
    case .keepBoth:
      if let provisional {
        promotedReview = recovery.promoted(recovered: provisional)
        return
      }
      var promoted = recovery.recovered
      if !state.lists.contains(where: { $0.id == promoted.listID }) {
        promoted.listID = SnipList.inboxID
      }
      state.snips.append(promoted)
      state.seenRequestIDs.insert(promoted.requestID)
      promotedReview = recovery.promoted(recovered: promoted)
      return
    case .useRecovered:
      apply(recovery.recovered, fields: recovery.conflictingFields, to: &state.snips[index], state: state)
      state.snips.removeAll { $0.id == recovery.id }
    case .editSnip(let edited):
      apply(edited, fields: recovery.conflictingFields, to: &state.snips[index], state: state)
      state.snips.removeAll { $0.id == recovery.id }
    case .editList:
      throw SnipLibraryError.invalidRecoveryChoice
    }
  }

  private static func resolve(
    _ recovery: RecoveredListEdit,
    choice: SnipRecoveryChoice,
    state: inout SnipLibraryState
  ) throws {
    guard let index = state.lists.firstIndex(where: { $0.id == recovery.currentListID }) else {
      throw SnipLibraryError.invalidList
    }
    let candidate: SnipList
    switch choice {
    case .keepCurrent:
      return
    case .useRecovered:
      candidate = recovery.recovered
    case .editList(let edited):
      candidate = edited
    case .keepBoth, .editSnip:
      throw SnipLibraryError.invalidRecoveryChoice
    }
    if recovery.conflictingFields.contains(.name) {
      let cleanName = SnipListNameAllocator.cleaned(candidate.desiredName)
      guard !cleanName.isEmpty else { throw SnipLibraryError.invalidList }
      state.lists[index].name = cleanName
    }
    if recovery.conflictingFields.contains(.icon) {
      state.lists[index].systemImage = candidate.systemImage
    }
    if recovery.conflictingFields.contains(.color) {
      state.lists[index].color = candidate.color
    }
    state = SnipLibraryState(
      snips: state.snips,
      lists: state.lists,
      seenRequestIDs: state.seenRequestIDs
    )
  }

  private static func apply(
    _ candidate: Snip,
    fields: Set<RecoveredSnipField>,
    to current: inout Snip,
    state: SnipLibraryState
  ) {
    if fields.contains(.text) { current.content = candidate.content }
    if fields.contains(.source) { current.source = candidate.source }
    if fields.contains(.done) { current.isDone = candidate.isDone }
    if fields.contains(.placement) {
      current.listID = state.lists.contains(where: { $0.id == candidate.listID })
        ? candidate.listID : SnipList.inboxID
      current.manualSortKey = candidate.manualSortKey
    }
    current.updatedAt = max(current.updatedAt, candidate.updatedAt)
  }

  private static func recoveryReviews(
    namespaceKey: String,
    context: ModelContext
  ) throws -> [StoredSnipRecoveryReview] {
    try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
      .filter {
        $0.namespaceKey == namespaceKey && $0.eventKey.hasPrefix(recoveryReviewPrefix)
      }
      .map(recoveryReview(from:))
  }

  private static func recoveryReview(
    from event: StoredCloudRecoveryEvent
  ) throws -> StoredSnipRecoveryReview {
    guard let envelope = CloudWirePayloadEnvelope.decode(event.payload),
      envelope.format == .fullRecordV1
    else { throw SnipLibraryError.invalidStore }
    let review = try JSONDecoder().decode(
      StoredSnipRecoveryReview.self,
      from: envelope.payload
    )
    guard review.storageVersion == 1,
      event.eventKey == recoveryEventKey(review.recovery.id)
    else { throw SnipLibraryError.invalidStore }
    try validate(review.recovery)
    return review
  }

  private static func validate(_ recovery: SnipRecoveryRecord) throws {
    switch recovery {
    case .snip(let item):
      guard item.id == item.recovered.id,
        item.id != item.currentSnipID,
        !item.conflictingFields.isEmpty
      else { throw CloudFullStorageError.invalidConflictReplay }
    case .list(let item):
      guard item.recovered.id == item.currentListID,
        !item.conflictingFields.isEmpty
      else { throw CloudFullStorageError.invalidConflictReplay }
    }
  }

  private static func recoveryReviewData(_ review: StoredSnipRecoveryReview) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try CloudWirePayloadEnvelope(
      format: .fullRecordV1,
      payload: encoder.encode(review)
    ).encoded()
  }

  private static func recoveryEventKey(_ id: UUID) -> String {
    "\(recoveryReviewPrefix)\(id.uuidString.lowercased())"
  }

}
