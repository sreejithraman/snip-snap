import Foundation
import XCTest

@testable import SnipSnapCore
@testable import SnipSnapPersistence

final class SyncOrderingTests: XCTestCase {
  func testTransferConvergesEqualNormalizedDesiredNamesWithWholeSetAllocator() throws {
    let low = SnipList(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
      name: "Work",
      systemImage: "folder",
      position: 1
    )
    let high = SnipList(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
      name: " work ",
      systemImage: "star",
      position: 2
    )
    let source = SnipLibraryTransferSnapshot(
      revision: 1,
      snips: [],
      lists: [.inbox, high],
      attachmentData: [:]
    )
    let target = SnipLibraryTransferSnapshot(
      revision: 2,
      snips: [],
      lists: [.inbox, low],
      attachmentData: [:]
    )

    let plan = try SnipLibraryTransferPlanner.plan(
      source: source,
      target: target,
      transitionID: UUID()
    )

    let values = plan.lists.filter { $0.id != SnipList.inbox.id }
    XCTAssertEqual(Set(values.map(\.desiredName)), ["Work", "work"])
    XCTAssertEqual(Set(values.map(\.resolvedName)).count, 2)
    XCTAssertEqual(
      values.sorted { $0.id.uuidString < $1.id.uuidString }.map(\.resolvedName),
      ["Work", "Work (2)"]
    )
  }

  func testOrderKeysAlwaysCreateAValueBetweenWorkedExamples() throws {
    let middle = try XCTUnwrap(SnipOrderKey.between(nil, nil))
    let before = try XCTUnwrap(SnipOrderKey.between(nil, middle))
    let after = try XCTUnwrap(SnipOrderKey.between(middle, nil))
    let closeUpper = SnipOrderKey(rawDigits: [1])
    let closeLower = SnipOrderKey(rawDigits: [0, 255])
    let closeMiddle = try XCTUnwrap(SnipOrderKey.between(closeLower, closeUpper))
    let prefixLower = SnipOrderKey(rawDigits: [1])
    let prefixUpper = SnipOrderKey(rawDigits: [1, 0, 1])
    let prefixMiddle = try XCTUnwrap(SnipOrderKey.between(prefixLower, prefixUpper))

    XCTAssertLessThan(before, middle)
    XCTAssertLessThan(middle, after)
    XCTAssertLessThan(closeLower, closeMiddle)
    XCTAssertLessThan(closeMiddle, closeUpper)
    XCTAssertLessThan(prefixLower, prefixMiddle)
    XCTAssertLessThan(prefixMiddle, prefixUpper)
  }

  func testManualSortUsesOrderKeyThenStableSnipID() {
    let key = SnipOrderKey(rawDigits: [128])
    let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    let higher = Snip(id: higherID, content: "higher", origin: .quickEntry, manualSortKey: key)
    let lower = Snip(id: lowerID, content: "lower", origin: .quickEntry, manualSortKey: key)

    XCTAssertEqual(Snip.sorted([higher, lower], by: .manual).map(\.id), [lowerID, higherID])

    let legacyLower = Snip(content: "old lower", origin: .quickEntry, manualPosition: -7)
    let legacyHigher = Snip(content: "old higher", origin: .quickEntry, manualPosition: 42)
    XCTAssertLessThan(legacyLower.manualSortKey, legacyHigher.manualSortKey)
  }

  func testPlacingFromChronologicalViewSeedsManualOrderFromVisibleOrder() throws {
    let keys = try SnipOrderKey.rebalanced(count: 3)
    let old = Snip(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
      createdAt: Date(timeIntervalSince1970: 100),
      content: "old",
      origin: .quickEntry,
      manualSortKey: keys[0]
    )
    let middle = Snip(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
      createdAt: Date(timeIntervalSince1970: 200),
      content: "middle",
      origin: .quickEntry,
      manualSortKey: keys[2]
    )
    let new = Snip(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
      createdAt: Date(timeIntervalSince1970: 300),
      content: "new",
      origin: .quickEntry,
      manualSortKey: keys[1]
    )
    var state = SnipLibraryState(
      snips: [old, middle, new],
      lists: [.inbox],
      seenRequestIDs: []
    )

    _ = try state.perform(
      .place(
        ids: [middle.id],
        in: SnipList.inboxID,
        before: new.id,
        basedOn: .chronological
      ),
      prepareAttachments: { _, _ in [] },
      pruneAttachments: { _, _ in }
    )

    XCTAssertEqual(
      Snip.sorted(state.snips, by: .manual).map(\.id),
      [middle.id, new.id, old.id]
    )
  }

  func testPlacingBetweenEqualKeyNeighborsRebalancesTheVisibleOrder() throws {
    let tiedKey = SnipOrderKey(rawDigits: [128])
    let first = Snip(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
      content: "first",
      origin: .quickEntry,
      manualSortKey: tiedKey
    )
    let second = Snip(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
      content: "second",
      origin: .quickEntry,
      manualSortKey: tiedKey
    )
    let moving = Snip(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
      content: "moving",
      origin: .quickEntry,
      manualSortKey: SnipOrderKey(rawDigits: [192])
    )
    var state = SnipLibraryState(
      snips: [first, second, moving],
      lists: [.inbox],
      seenRequestIDs: []
    )

    _ = try state.perform(
      .place(
        ids: [moving.id],
        in: SnipList.inboxID,
        before: second.id,
        basedOn: .manual
      ),
      prepareAttachments: { _, _ in [] },
      pruneAttachments: { _, _ in }
    )

    XCTAssertEqual(
      Snip.sorted(state.snips, by: .manual).map(\.id),
      [first.id, moving.id, second.id]
    )
  }

  func testPlacingBeforeDoneSnipRebalancesKeysThatOpposeVisibleOrder() throws {
    let active = Snip(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
      content: "active",
      origin: .quickEntry,
      manualSortKey: SnipOrderKey(rawDigits: [192])
    )
    let done = Snip(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
      content: "done",
      origin: .quickEntry,
      isDone: true,
      manualSortKey: SnipOrderKey(rawDigits: [64])
    )
    let moving = Snip(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
      content: "moving",
      origin: .quickEntry,
      manualSortKey: SnipOrderKey(rawDigits: [128])
    )
    var state = SnipLibraryState(
      snips: [active, done, moving],
      lists: [.inbox],
      seenRequestIDs: []
    )

    _ = try state.perform(
      .place(
        ids: [moving.id],
        in: SnipList.inboxID,
        before: done.id,
        basedOn: .manual
      ),
      prepareAttachments: { _, _ in [] },
      pruneAttachments: { _, _ in }
    )

    XCTAssertEqual(
      Snip.sorted(state.snips, by: .manual).map(\.id),
      [active.id, moving.id, done.id]
    )
    let keysByID = Dictionary(uniqueKeysWithValues: state.snips.map { ($0.id, $0.manualSortKey) })
    XCTAssertLessThan(try XCTUnwrap(keysByID[active.id]), try XCTUnwrap(keysByID[moving.id]))
    XCTAssertLessThan(try XCTUnwrap(keysByID[moving.id]), try XCTUnwrap(keysByID[done.id]))
  }

  func testListNamesResolveFromDesiredNamesAndStableIDs() {
    let ids = (1...4).map {
      UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
    }
    let lists = [
      SnipList(id: ids[3], name: "Wörk", systemImage: "4.circle", position: 4),
      SnipList(id: ids[1], name: "  work  ", systemImage: "2.circle", position: 2),
      SnipList(id: ids[2], name: "Work (2)", systemImage: "3.circle", position: 3),
      SnipList(id: ids[0], name: "Work", systemImage: "1.circle", position: 1),
    ]

    let forward = SnipListNameAllocator.resolving(lists)
    let reverse = SnipListNameAllocator.resolving(lists.reversed())
    let names = Dictionary(uniqueKeysWithValues: forward.map { ($0.id, $0.name) })

    XCTAssertEqual(names[ids[0]], "Work")
    XCTAssertEqual(names[ids[1]], "Work (3)")
    XCTAssertEqual(names[ids[2]], "Work (2)")
    XCTAssertEqual(names[ids[3]], "Work (4)")
    XCTAssertEqual(forward.sorted { $0.id.uuidString < $1.id.uuidString },
                   reverse.sorted { $0.id.uuidString < $1.id.uuidString })
    XCTAssertEqual(forward.first { $0.id == ids[1] }?.desiredName, "work")
  }

  func testOneHundredThousandDeterministicMidpointsStayInsideTheirGaps() throws {
    var state: UInt64 = 0x4d595df4d0f33173
    for _ in 0..<100_000 {
      state = state &* 6364136223846793005 &+ 1442695040888963407
      var firstBytes = withUnsafeBytes(of: state.bigEndian) { Array($0) }
      firstBytes.append(128)
      state = state &* 6364136223846793005 &+ 1442695040888963407
      var secondBytes = withUnsafeBytes(of: state.bigEndian) { Array($0) }
      secondBytes.append(128)
      let first = SnipOrderKey(rawDigits: firstBytes)
      let second = SnipOrderKey(rawDigits: secondBytes)
      guard first != second else { continue }
      let lower = min(first, second)
      let upper = max(first, second)
      let key = try XCTUnwrap(SnipOrderKey.between(lower, upper))
      XCTAssertLessThan(lower, key)
      XCTAssertLessThan(key, upper)
    }
  }

  func testRepeatedSameGapExhaustsAtSixtyFourBytesThenRebalances() throws {
    let lower = SnipOrderKey(rawDigits: [1])
    var upper = SnipOrderKey(rawDigits: [2])
    while let key = SnipOrderKey.between(lower, upper) { upper = key }

    XCTAssertEqual(upper.data.count, SnipOrderKey.maximumByteCount)
    XCTAssertNil(SnipOrderKey.between(lower, upper))

    let rebalanced = try SnipOrderKey.rebalanced(count: 3)
    XCTAssertEqual(rebalanced.count, 3)
    XCTAssertLessThan(rebalanced[0], rebalanced[1])
    XCTAssertLessThan(rebalanced[1], rebalanced[2])
    XCTAssertEqual(Set(rebalanced.map { $0.data.count }), [10])
  }

  func testLegacyListJSONDecodesDesiredNameAndOrderKey() throws {
    let data = Data(#"{"id":"00000000-0000-0000-0000-000000000040","name":"  Legacy List  ","systemImage":"folder","position":7}"#.utf8)

    let list = try JSONDecoder().decode(SnipList.self, from: data)

    XCTAssertEqual(list.desiredName, "Legacy List")
    XCTAssertEqual(list.sortKey, SnipOrderKey.legacy(7))

    let state = SnipLibraryState(snips: [], lists: [list], seenRequestIDs: [])
    XCTAssertEqual(state.allLists().first?.resolvedName, "Legacy List")
  }

  func testInboundOrderKeyRejectsEmptyOverlongAndNoncanonicalData() {
    XCTAssertThrowsError(try SnipOrderKey(data: Data()))
    XCTAssertThrowsError(try SnipOrderKey(data: Data(repeating: 1, count: 65)))
    XCTAssertThrowsError(try SnipOrderKey(data: Data([1, 0])))
  }

  func testLegacyBackfillUsesWholeSetGoldenRanksAcrossJSONReopen() throws {
    let firstListID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let secondListID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let firstSnipID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    let secondSnipID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    let state = SnipLibraryState(
      snips: [
        Snip(id: secondSnipID, content: "second", origin: .quickEntry,
             listID: firstListID, manualPosition: 9),
        Snip(id: firstSnipID, content: "first", origin: .quickEntry,
             listID: firstListID, manualPosition: 9),
      ],
      lists: [
        SnipList(id: secondListID, name: "Second", systemImage: "2.circle", position: 4),
        SnipList(id: firstListID, name: "First", systemImage: "1.circle", position: -2),
      ],
      seenRequestIDs: []
    )
    let expected = try SnipOrderKey.rebalanced(count: 2)

    XCTAssertEqual(state.allLists().map(\.sortKey), expected)
    XCTAssertEqual(Snip.sorted(state.snips, by: .manual).map(\.manualSortKey), expected)
    XCTAssertEqual(Array(expected[0].data), [128, 0, 0, 0, 0, 0, 0, 0, 1, 128])
    XCTAssertEqual(Array(expected[1].data), [128, 0, 0, 0, 0, 0, 0, 0, 2, 128])

    let reopenedSnips = try JSONDecoder().decode(
      [Snip].self, from: JSONEncoder().encode(state.snips))
    let reopenedLists = try JSONDecoder().decode(
      [SnipList].self, from: JSONEncoder().encode(state.lists))
    let reopened = SnipLibraryState(
      snips: reopenedSnips, lists: reopenedLists, seenRequestIDs: [])
    XCTAssertEqual(reopened.snips, state.snips)
    XCTAssertEqual(reopened.lists, state.lists)
  }
}
