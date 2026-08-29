import Foundation

package struct SnipLibraryState {
  package var snips: [Snip]
  package var lists: [SnipList]
  package var seenRequestIDs: Set<UUID>

  package init(snips: [Snip], lists: [SnipList], seenRequestIDs: Set<UUID>) {
    let backfilled = SnipLegacyOrderBackfill.applying(snips: snips, lists: lists)
    self.snips = backfilled.snips
    self.lists = SnipListNameAllocator.resolving(backfilled.lists)
    self.seenRequestIDs = seenRequestIDs
  }

  package func allSnips(sortMode: SnipSortMode) -> [Snip] {
    let byList = Dictionary(grouping: snips, by: \.listID)
    return allLists().flatMap { Snip.sorted(byList[$0.id] ?? [], by: sortMode) }
  }

  package func allLists() -> [SnipList] {
    lists.sorted {
      if $0.sortKey != $1.sortKey { return $0.sortKey < $1.sortKey }
      return $0.id.uuidString < $1.id.uuidString
    }
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
        manualSortKey: nextTopSortKey(in: listID),
        attachments: attachments
      )
      snips.append(snip)
      seenRequestIDs.insert(requestID)
      return .add(.added(snip.id))

    case .createList(let name, let systemImage):
      let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleanName.isEmpty else { throw SnipLibraryError.invalidList }
      let normalized = SnipListNameAllocator.normalized(cleanName)
      guard !lists.contains(where: {
        SnipListNameAllocator.normalized($0.desiredName) == normalized
      })
      else { throw SnipLibraryError.duplicateList }
      let sortKey = nextListSortKey()
      let list = SnipList(
        id: UUID(),
        name: cleanName,
        systemImage: systemImage.isEmpty ? "circle.grid.2x2.fill" : systemImage,
        position: 0,
        sortKey: sortKey
      )
      lists.append(list)
      resolveListNames()
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
      let normalized = SnipListNameAllocator.normalized(cleanName)
      guard !lists.contains(where: {
        $0.id != id && SnipListNameAllocator.normalized($0.desiredName) == normalized
      })
      else { throw SnipLibraryError.duplicateList }
      lists[index].name = cleanName
      lists[index].systemImage = systemImage
      resolveListNames()
      return .none

    case .deleteList(let id):
      guard id != SnipList.inboxID, lists.contains(where: { $0.id == id }) else {
        throw SnipLibraryError.invalidList
      }
      let movingIDs = Snip.sorted(snips.filter { $0.listID == id }, by: .manual).map(\.id)
      lists.removeAll { $0.id == id }
      let keys = insertionKeys(
        count: movingIDs.count,
        lower: nil,
        upper: firstSortKey(in: SnipList.inboxID),
        targetIDs: movingIDs,
        fallbackOrder: movingIDs + orderedIDs(in: SnipList.inboxID)
      )
      for (offset, snipID) in movingIDs.enumerated() {
        guard let index = snips.firstIndex(where: { $0.id == snipID }) else { continue }
        snips[index].listID = SnipList.inboxID
        snips[index].manualSortKey = keys[offset]
      }
      resolveListNames()
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

    case .editAttachments(let snipID, let content, let edits, let expectedUpdatedAt, let now):
      let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let index = snips.firstIndex(where: { $0.id == snipID }) else {
        throw SnipLibraryError.snipNotFound
      }
      if let expectedUpdatedAt, snips[index].updatedAt != expectedUpdatedAt {
        throw SnipLibraryError.snipChanged
      }
      let originals = Dictionary(
        uniqueKeysWithValues: snips[index].attachments.map { ($0.id, $0) }
      )
      var usedOriginalIDs: Set<UUID> = []
      var attachments: [SnipAttachment] = []
      for edit in edits {
        switch edit {
        case .existing(let attachmentID):
          guard let attachment = originals[attachmentID],
            usedOriginalIDs.insert(attachmentID).inserted
          else { throw SnipLibraryError.attachmentCopyFailed }
          attachments.append(attachment)
        case .added(let sourceURL):
          let prepared = try prepareAttachments([sourceURL], snips)
          guard prepared.count == 1 else { throw SnipLibraryError.attachmentCopyFailed }
          attachments.append(prepared[0])
        case .replacement(let attachmentID, let sourceURL):
          guard originals[attachmentID] != nil,
            usedOriginalIDs.insert(attachmentID).inserted
          else { throw SnipLibraryError.attachmentCopyFailed }
          let prepared = try prepareAttachments([sourceURL], snips)
          guard prepared.count == 1 else { throw SnipLibraryError.attachmentCopyFailed }
          attachments.append(prepared[0])
        }
      }
      guard !cleanContent.isEmpty || !attachments.isEmpty else {
        throw SnipLibraryError.emptyContent
      }
      guard Set(attachments.map(\.id)).count == attachments.count else {
        throw SnipLibraryError.attachmentCopyFailed
      }
      snips[index].content = cleanContent
      snips[index].attachments = attachments
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
      let sortKey =
        listIDs.count == 1
        ? selected.map(\.manualSortKey).min() ?? nextTopSortKey(in: listID)
        : nextTopSortKey(in: listID)
      var seenAttachments: Set<UUID> = []
      let attachments = selected.flatMap(\.attachments)
        .filter { seenAttachments.insert($0.id).inserted }
      let merged = Snip(
        createdAt: now,
        content: SnipFormatter.format(snips: selected),
        origin: .quickEntry,
        listID: listID,
        manualSortKey: sortKey,
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
      let existing = orderedIDs(in: listID, excluding: Set(ordered))
      let keys = insertionKeys(
        count: ordered.count,
        lower: nil,
        upper: existing.first.flatMap(sortKey(for:)),
        targetIDs: ordered,
        fallbackOrder: ordered + existing
      )
      for (offset, id) in ordered.enumerated() {
        guard let index = snips.firstIndex(where: { $0.id == id }) else { continue }
        snips[index].listID = listID
        snips[index].manualSortKey = keys[offset]
      }
      return .none

    case .place(let ids, let listID, let destinationID, let sortMode):
      guard !ids.isEmpty else { return .none }
      try validateList(id: listID)
      let movingSet = Set(ids)
      let orderedMoving = ids.filter { id in snips.contains { $0.id == id } }
      guard !orderedMoving.isEmpty else { return .none }
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
      if sortMode != .manual {
        rebalanceSnipsForOrder(destination)
        return .none
      }
      let lower = index > 0 ? sortKey(for: destination[index - 1]) : nil
      let upperIndex = index + orderedMoving.count
      let upper = upperIndex < destination.count ? sortKey(for: destination[upperIndex]) : nil
      let keys = insertionKeys(
        count: orderedMoving.count,
        lower: lower,
        upper: upper,
        targetIDs: orderedMoving,
        fallbackOrder: destination
      )
      for (offset, id) in orderedMoving.enumerated() {
        guard let snipIndex = snips.firstIndex(where: { $0.id == id }) else { continue }
        snips[snipIndex].manualSortKey = keys[offset]
      }
      return .none

    case .replaceAll(let replacement):
      try validateImportedSnips(replacement)
      snips = replacement
      seenRequestIDs.formUnion(replacement.map(\.requestID))
      return .none

    case .applyDevicePatch(let patch, let now):
      try applyDevicePatch(patch, now: now)
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

  private mutating func applyDevicePatch(
    _ patch: SnipLibraryDevicePatch,
    now: Date
  ) throws {
    let currentSnips = Dictionary(uniqueKeysWithValues: snips.map { ($0.id, $0) })
    let currentLists = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0) })
    for change in patch.snips {
      try validate(change, current: currentSnips)
    }
    for change in patch.lists {
      try validate(change, current: currentLists)
    }

    for change in patch.lists where change.before == nil {
      if let after = change.after { lists.append(after) }
    }
    for change in patch.lists where change.before != nil && change.after != nil {
      guard let before = change.before, let after = change.after,
        let index = lists.firstIndex(where: { $0.id == before.id })
      else { throw SnipLibraryError.deviceActionChanged }
      if before.desiredName != after.desiredName { lists[index].desiredName = after.desiredName }
      if before.systemImage != after.systemImage { lists[index].systemImage = after.systemImage }
      if before.sortKey != after.sortKey { lists[index].sortKey = after.sortKey }
    }

    for change in patch.snips {
      switch (change.before, change.after) {
      case (nil, let after?):
        snips.append(after)
        seenRequestIDs.insert(after.requestID)
      case (let before?, nil):
        snips.removeAll { $0.id == before.id }
      case (let before?, let after?):
        guard let index = snips.firstIndex(where: { $0.id == before.id }) else {
          throw SnipLibraryError.deviceActionChanged
        }
        if before.content != after.content { snips[index].content = after.content }
        if before.origin != after.origin { snips[index].origin = after.origin }
        if before.source != after.source { snips[index].source = after.source }
        if before.listID != after.listID { snips[index].listID = after.listID }
        if before.isDone != after.isDone { snips[index].isDone = after.isDone }
        if before.manualSortKey != after.manualSortKey {
          snips[index].manualSortKey = after.manualSortKey
        }
        if before.attachments != after.attachments { snips[index].attachments = after.attachments }
        snips[index].updatedAt = now
      case (nil, nil):
        throw SnipLibraryError.deviceActionChanged
      }
    }

    for change in patch.lists where change.after == nil {
      guard let before = change.before else { throw SnipLibraryError.deviceActionChanged }
      lists.removeAll { $0.id == before.id }
    }
    lists = SnipListNameAllocator.resolving(lists)
    let listIDs = Set(lists.map(\.id))
    guard lists.contains(where: { $0.id == SnipList.inboxID }),
      Set(lists.map(\.id)).count == lists.count,
      Set(snips.map(\.id)).count == snips.count,
      Set(snips.map(\.listID)).isSubset(of: listIDs)
    else { throw SnipLibraryError.deviceActionChanged }
  }

  private func validate(
    _ change: SnipDeviceChange,
    current: [UUID: Snip]
  ) throws {
    let id = change.before?.id ?? change.after?.id
    guard let id else { throw SnipLibraryError.deviceActionChanged }
    switch (change.before, change.after, current[id]) {
    case (nil, .some, nil):
      return
    case (let before?, nil, let value?):
      guard value.deviceFieldsEqual(before) else { throw SnipLibraryError.deviceActionChanged }
    case (let before?, let after?, let value?):
      guard before.id == after.id,
        before.requestID == after.requestID,
        before.createdAt == after.createdAt,
        unchangedOrExpected(before.content, after.content, value.content),
        unchangedOrExpected(before.origin, after.origin, value.origin),
        unchangedOrExpected(before.source, after.source, value.source),
        unchangedOrExpected(before.listID, after.listID, value.listID),
        unchangedOrExpected(before.isDone, after.isDone, value.isDone),
        unchangedOrExpected(before.manualSortKey, after.manualSortKey, value.manualSortKey),
        unchangedOrExpected(before.attachments, after.attachments, value.attachments)
      else { throw SnipLibraryError.deviceActionChanged }
    default:
      throw SnipLibraryError.deviceActionChanged
    }
  }

  private func validate(
    _ change: SnipListDeviceChange,
    current: [UUID: SnipList]
  ) throws {
    let id = change.before?.id ?? change.after?.id
    guard let id else { throw SnipLibraryError.deviceActionChanged }
    switch (change.before, change.after, current[id]) {
    case (nil, .some, nil):
      return
    case (let before?, nil, let value?):
      guard value.deviceFieldsEqual(before) else { throw SnipLibraryError.deviceActionChanged }
    case (let before?, let after?, let value?):
      guard before.id == after.id,
        unchangedOrExpected(before.desiredName, after.desiredName, value.desiredName),
        unchangedOrExpected(before.systemImage, after.systemImage, value.systemImage),
        unchangedOrExpected(before.sortKey, after.sortKey, value.sortKey)
      else { throw SnipLibraryError.deviceActionChanged }
    default:
      throw SnipLibraryError.deviceActionChanged
    }
  }

  private func unchangedOrExpected<Value: Equatable>(
    _ before: Value,
    _ after: Value,
    _ current: Value
  ) -> Bool {
    before == after || current == before
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

  private mutating func nextTopSortKey(in listID: UUID) -> SnipOrderKey {
    if let key = SnipOrderKey.between(nil, firstSortKey(in: listID)) { return key }
    rebalanceSnipsForOrder(orderedIDs(in: listID))
    return SnipOrderKey.between(nil, firstSortKey(in: listID))!
  }

  private mutating func nextListSortKey() -> SnipOrderKey {
    let last = allLists().last?.sortKey
    if let key = SnipOrderKey.between(last, nil) { return key }
    let ordered = allLists().map(\.id)
    let keys = try! SnipOrderKey.rebalanced(count: ordered.count)
    for (index, id) in ordered.enumerated() {
      lists[lists.firstIndex { $0.id == id }!].sortKey = keys[index]
    }
    return SnipOrderKey.between(allLists().last?.sortKey, nil)!
  }

  private func firstSortKey(in listID: UUID) -> SnipOrderKey? {
    Snip.sorted(snips.filter { $0.listID == listID }, by: .manual).first?.manualSortKey
  }

  private func sortKey(for id: UUID) -> SnipOrderKey? {
    snips.first { $0.id == id }?.manualSortKey
  }

  private func orderedIDs(in listID: UUID, excluding: Set<UUID> = []) -> [UUID] {
    Snip.sorted(
      snips.filter { $0.listID == listID && !excluding.contains($0.id) },
      by: .manual
    ).map(\.id)
  }

  private mutating func insertionKeys(
    count: Int,
    lower: SnipOrderKey?,
    upper: SnipOrderKey?,
    targetIDs: [UUID],
    fallbackOrder: [UUID]
  ) -> [SnipOrderKey] {
    if let lower, let upper, lower >= upper {
      rebalanceSnipsForOrder(fallbackOrder)
      return targetIDs.compactMap(sortKey(for:))
    }
    var result: [SnipOrderKey] = []
    var prior = lower
    for _ in 0..<count {
      guard let key = SnipOrderKey.between(prior, upper) else {
        rebalanceSnipsForOrder(fallbackOrder)
        return targetIDs.compactMap(sortKey(for:))
      }
      result.append(key)
      prior = key
    }
    return result
  }

  private mutating func rebalanceSnipsForOrder(_ ids: [UUID]) {
    let keys = try! SnipOrderKey.rebalanced(count: ids.count)
    for (position, id) in ids.enumerated() {
      guard let index = snips.firstIndex(where: { $0.id == id }) else { continue }
      snips[index].manualSortKey = keys[position]
    }
  }

  private mutating func resolveListNames() {
    lists = SnipListNameAllocator.resolving(lists)
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
