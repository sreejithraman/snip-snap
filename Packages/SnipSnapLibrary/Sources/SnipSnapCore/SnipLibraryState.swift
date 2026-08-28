import Foundation

package struct SnipLibraryState {
  package var snips: [Snip]
  package var lists: [SnipList]
  package var seenRequestIDs: Set<UUID>

  package init(snips: [Snip], lists: [SnipList], seenRequestIDs: Set<UUID>) {
    self.snips = snips
    self.lists = lists
    self.seenRequestIDs = seenRequestIDs
  }

  package func allSnips(sortMode: SnipSortMode) -> [Snip] {
    let byList = Dictionary(grouping: snips, by: \.listID)
    return allLists().flatMap { Snip.sorted(byList[$0.id] ?? [], by: sortMode) }
  }

  package func allLists() -> [SnipList] {
    lists.sorted { $0.position < $1.position }
  }

  package mutating func perform(
    _ command: SnipLibraryCommand,
    prepareAttachments: ([URL], [Snip]) throws -> [SnipAttachment],
    pruneAttachments: (Set<UUID>, [Snip]) -> Void
  ) throws -> SnipLibraryOutcome {
    switch command {
    case .add(
      let content, let origin, let source, let listID, let attachmentURLs, let requestID, let now):
      let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleanContent.isEmpty || !attachmentURLs.isEmpty else {
        throw SnipLibraryError.emptyContent
      }
      guard !seenRequestIDs.contains(requestID) else { return .add(.duplicate) }
      try validateList(id: listID)
      let attachments = try prepareAttachments(attachmentURLs, snips)
      let snip = Snip(
        requestID: requestID,
        createdAt: now,
        content: origin == .selection ? content : cleanContent,
        origin: origin,
        source: source,
        listID: listID,
        manualPosition: nextTopPosition(in: listID),
        attachments: attachments
      )
      snips.append(snip)
      seenRequestIDs.insert(requestID)
      return .add(.added(snip.id))

    case .createList(let name, let systemImage):
      let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleanName.isEmpty else { throw SnipLibraryError.invalidList }
      guard !lists.contains(where: { $0.name.caseInsensitiveCompare(cleanName) == .orderedSame })
      else { throw SnipLibraryError.duplicateList }
      let list = SnipList(
        id: UUID(),
        name: cleanName,
        systemImage: systemImage.isEmpty ? "circle.grid.2x2.fill" : systemImage,
        position: (lists.map(\.position).max() ?? 0) + 1
      )
      lists.append(list)
      return .listCreated(list)

    case .restoreList(let list):
      guard list.id != SnipList.inboxID,
        !lists.contains(where: { $0.id == list.id }),
        !lists.contains(where: { $0.name.caseInsensitiveCompare(list.name) == .orderedSame })
      else { throw SnipLibraryError.invalidList }
      for index in lists.indices where lists[index].position >= list.position {
        lists[index].position += 1
      }
      lists.append(list)
      return .none

    case .updateList(let id, let name, let systemImage):
      guard id != SnipList.inboxID,
        let index = lists.firstIndex(where: { $0.id == id })
      else { throw SnipLibraryError.invalidList }
      let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleanName.isEmpty else { throw SnipLibraryError.invalidList }
      guard
        !lists.contains(where: {
          $0.id != id && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
        })
      else { throw SnipLibraryError.duplicateList }
      lists[index].name = cleanName
      lists[index].systemImage = systemImage
      return .none

    case .deleteList(let id):
      guard id != SnipList.inboxID, lists.contains(where: { $0.id == id }) else {
        throw SnipLibraryError.invalidList
      }
      let movingIDs = Snip.sorted(snips.filter { $0.listID == id }, by: .manual).map(\.id)
      let firstPosition =
        nextTopPosition(in: SnipList.inboxID)
        - Int64(max(0, movingIDs.count - 1))
      lists.removeAll { $0.id == id }
      for (offset, snipID) in movingIDs.enumerated() {
        guard let index = snips.firstIndex(where: { $0.id == snipID }) else { continue }
        snips[index].listID = SnipList.inboxID
        snips[index].manualPosition = firstPosition + Int64(offset)
      }
      for index in lists.indices { lists[index].position = index }
      return .none

    case .update(let id, let content, let attachmentURLs, let expectedUpdatedAt, let now):
      let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let index = snips.firstIndex(where: { $0.id == id }) else {
        throw SnipLibraryError.snipNotFound
      }
      if let expectedUpdatedAt, snips[index].updatedAt != expectedUpdatedAt {
        throw SnipLibraryError.snipChanged
      }
      let willHaveAttachments =
        attachmentURLs.map { !$0.isEmpty }
        ?? !snips[index].attachments.isEmpty
      guard !cleanContent.isEmpty || willHaveAttachments else {
        throw SnipLibraryError.emptyContent
      }
      let attachments = try attachmentURLs.map { try prepareAttachments($0, snips) }
      snips[index].content = cleanContent
      if let attachments { snips[index].attachments = attachments }
      snips[index].updatedAt = now
      return .none

    case .delete(let ids):
      guard !ids.isEmpty else { return .none }
      snips.removeAll { ids.contains($0.id) }
      return .none

    case .restore(let restored):
      guard !restored.isEmpty else { return .none }
      try validateImportedSnips(restored)
      let existingIDs = Set(snips.map(\.id))
      let additions = restored.filter { !existingIDs.contains($0.id) }
      for listID in Set(additions.map(\.listID)) { try validateList(id: listID) }
      snips.append(contentsOf: additions)
      seenRequestIDs.formUnion(additions.map(\.requestID))
      return .none

    case .restoreReplacing(let restored, let id, let expectedUpdatedAt):
      guard !restored.isEmpty else { return .none }
      try validateImportedSnips(restored)
      guard let replaced = snips.first(where: { $0.id == id }) else {
        throw SnipLibraryError.snipNotFound
      }
      guard replaced.updatedAt == expectedUpdatedAt else { throw SnipLibraryError.snipChanged }
      let existingIDs = Set(snips.lazy.filter { $0.id != id }.map(\.id))
      let additions = restored.filter { !existingIDs.contains($0.id) }
      for listID in Set(additions.map(\.listID)) { try validateList(id: listID) }
      snips.removeAll { $0.id == id }
      snips.append(contentsOf: additions)
      seenRequestIDs.formUnion(restored.map(\.requestID))
      return .none

    case .merge(let ids, let now):
      let selected = Snip.sorted(snips.filter { ids.contains($0.id) }, by: .chronological)
      guard selected.count >= 2 else { throw SnipLibraryError.requiresMultipleSnips }
      let listIDs = Set(selected.map(\.listID))
      let listID = listIDs.count == 1 ? selected[0].listID : SnipList.inboxID
      let position =
        listIDs.count == 1
        ? selected.map(\.manualPosition).min() ?? 0
        : nextTopPosition(in: listID)
      var seenAttachments: Set<UUID> = []
      let attachments = selected.flatMap(\.attachments)
        .filter { seenAttachments.insert($0.id).inserted }
      let merged = Snip(
        createdAt: now,
        content: SnipFormatter.format(snips: selected),
        origin: .quickEntry,
        listID: listID,
        manualPosition: position,
        attachments: attachments
      )
      snips.removeAll { ids.contains($0.id) }
      snips.append(merged)
      seenRequestIDs.insert(merged.requestID)
      return .merged(merged)

    case .setDone(let ids, let done):
      update(ids: ids) { $0.isDone = done }
      return .none

    case .toggleDone(let id):
      guard let snip = snips.first(where: { $0.id == id }) else {
        throw SnipLibraryError.snipNotFound
      }
      update(ids: [id]) { $0.isDone = !snip.isDone }
      return .none

    case .toggleDoneMany(let ids):
      let selected = snips.filter { ids.contains($0.id) }
      guard !selected.isEmpty else { return .none }
      let done = selected.contains { !$0.isDone }
      update(ids: ids) { $0.isDone = done }
      return .none

    case .moveChronologically(let ids, let listID):
      guard !ids.isEmpty else { return .none }
      try validateList(id: listID)
      let ordered = ids.filter { id in snips.contains { $0.id == id && $0.listID != listID } }
      guard !ordered.isEmpty else { return .none }
      let top = nextTopPosition(in: listID, excluding: Set(ordered)) - Int64(ordered.count - 1)
      for (offset, id) in ordered.enumerated() {
        guard let index = snips.firstIndex(where: { $0.id == id }) else { continue }
        snips[index].listID = listID
        snips[index].manualPosition = top + Int64(offset)
      }
      return .none

    case .place(let ids, let listID, let destinationID, let sortMode):
      guard !ids.isEmpty else { return .none }
      try validateList(id: listID)
      let movingSet = Set(ids)
      let orderedMoving = ids.filter { id in snips.contains { $0.id == id } }
      guard !orderedMoving.isEmpty else { return .none }
      let sourceLists = Set(snips.filter { movingSet.contains($0.id) }.map(\.listID))
      var destination = Snip.sorted(
        snips.filter { $0.listID == listID && !movingSet.contains($0.id) },
        by: sortMode
      ).map(\.id)
      let index = destinationID.flatMap(destination.firstIndex) ?? destination.endIndex
      destination.insert(contentsOf: orderedMoving, at: index)
      for id in orderedMoving {
        guard let snipIndex = snips.firstIndex(where: { $0.id == id }) else { continue }
        snips[snipIndex].listID = listID
      }
      reindex(listID: listID, orderedIDs: destination)
      for sourceList in sourceLists where sourceList != listID { reindex(listID: sourceList) }
      return .none

    case .replaceAll(let replacement):
      try validateImportedSnips(replacement)
      snips = replacement
      seenRequestIDs.formUnion(replacement.map(\.requestID))
      return .none

    case .pruneAttachments(let retainedIDs):
      pruneAttachments(retainedIDs, snips)
      return .none

    case .batch(let commands):
      guard !commands.contains(where: \.containsPruneSideEffect) else {
        throw SnipLibraryError.invalidCommand
      }
      var outcome: SnipLibraryOutcome = .none
      for command in commands {
        let nextOutcome = try perform(
          command,
          prepareAttachments: prepareAttachments,
          pruneAttachments: pruneAttachments
        )
        if nextOutcome != .none { outcome = nextOutcome }
      }
      return outcome

    case .guarded(let expectation, let command):
      try validate(expectation)
      return try perform(
        command,
        prepareAttachments: prepareAttachments,
        pruneAttachments: pruneAttachments
      )
    }
  }

  private func validate(_ expectation: SnipLibraryExpectation) throws {
    let snipsByID = Dictionary(uniqueKeysWithValues: snips.map { ($0.id, $0) })
    let listsByID = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0) })
    guard expectation.expectedSnips.allSatisfy({ snipsByID[$0.id] == $0 }),
      expectation.absentSnipIDs.allSatisfy({ snipsByID[$0] == nil }),
      expectation.expectedLists.allSatisfy({ listsByID[$0.id] == $0 }),
      expectation.absentListIDs.allSatisfy({ listsByID[$0] == nil }),
      expectation.requiredListIDs.allSatisfy({ listsByID[$0] != nil }),
      expectation.expectedListMemberships.allSatisfy({ listID, expectedIDs in
        listsByID[listID] != nil
          && Set(snips.lazy.filter { $0.listID == listID }.map(\.id)) == expectedIDs
      })
    else { throw SnipLibraryError.snipChanged }
  }

  private func validateList(id: UUID) throws {
    guard lists.contains(where: { $0.id == id }) else { throw SnipLibraryError.invalidList }
  }

  private func validateImportedSnips(_ imported: [Snip]) throws {
    guard Set(imported.map(\.id)).count == imported.count,
      imported.allSatisfy({ snip in
        Set(snip.attachments.map(\.id)).count == snip.attachments.count
      })
    else { throw SnipLibraryError.invalidStore }
  }

  private mutating func update(ids: Set<UUID>, change: (inout Snip) -> Void) {
    for index in snips.indices where ids.contains(snips[index].id) {
      change(&snips[index])
      snips[index].updatedAt = Date()
    }
  }

  private func nextTopPosition(in listID: UUID, excluding excluded: Set<UUID> = []) -> Int64 {
    let minimum =
      snips
      .filter { $0.listID == listID && !excluded.contains($0.id) }
      .map(\.manualPosition)
      .min() ?? 1
    return minimum - 1
  }

  private mutating func reindex(listID: UUID, orderedIDs: [UUID]? = nil) {
    let ids =
      orderedIDs
      ?? Snip.sorted(
        snips.filter { $0.listID == listID },
        by: .manual
      ).map(\.id)
    for (position, id) in ids.enumerated() {
      guard let index = snips.firstIndex(where: { $0.id == id }) else { continue }
      snips[index].manualPosition = Int64(position)
    }
  }
}

private extension SnipLibraryCommand {
  var containsPruneSideEffect: Bool {
    switch self {
    case .pruneAttachments:
      true
    case .batch(let commands):
      commands.contains(where: \.containsPruneSideEffect)
    case .guarded(_, let command):
      command.containsPruneSideEffect
    default:
      false
    }
  }
}
