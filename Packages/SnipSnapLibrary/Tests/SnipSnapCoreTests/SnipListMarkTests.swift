import Foundation
import SnipSnapCore
import XCTest

final class SnipListMarkTests: XCTestCase {
  func testListWithoutIconShowsLettersFromItsName() {
    XCTAssertEqual(list("Groceries").mark(), .letters("G"))
    XCTAssertEqual(list("reading list").mark(), .letters("RL"))
    XCTAssertEqual(list("Work  plans for May").mark(), .letters("WP"))
    XCTAssertEqual(list("#launch 2026").mark(), .letters("L2"))
    XCTAssertEqual(list("été à Paris").mark(), .letters("ÉÀ"))
  }

  func testNameWithoutLettersUsesItsFirstCharacter() {
    XCTAssertEqual(list("🚀 ✨").mark(), .letters("🚀"))
    XCTAssertEqual(list("!!").mark(), .letters("!"))
  }

  func testOldDefaultIconsAndEmptyIconMeanNoIcon() {
    for stored in ["", "list.bullet", "circle.grid.2x2.fill"] {
      let value = list("Travel", systemImage: stored)
      XCTAssertNil(value.icon, stored)
      XCTAssertEqual(value.mark(), .letters("T"), stored)
    }
  }

  func testChosenIconWinsUnlessThisOSCannotDrawIt() {
    let travel = list("Travel", systemImage: "airplane")
    XCTAssertEqual(travel.mark(), .icon("airplane"))
    XCTAssertEqual(travel.mark(isAvailable: { _ in false }), .letters("T"))
    XCTAssertEqual(SnipList.inbox.mark(), .icon("tray.fill"))
  }

  func testClearingIconStoresEmptyStringSoOlderBuildsStillDecodeIt() {
    var value = list("Travel", systemImage: "airplane")
    value.icon = nil
    XCTAssertEqual(value.systemImage, "")
    value.icon = "star.fill"
    XCTAssertEqual(value.systemImage, "star.fill")
  }

  func testAutomaticColorIsStableForAnID() throws {
    // Pinned from an independent FNV-1a computation. Every device must derive the same color: changing this mapping recolors lists.
    let pinned: [(String, SnipListColorPreset)] = [
      ("00000000-0000-0000-0000-000000000002", .clay),
      ("7C9E6679-7425-40DE-944B-E07FC1F90AE7", .teal),
      ("F47AC10B-58CC-4372-A567-0E02B2C3D479", .pink),
      ("3B241101-E2BB-4255-8CAF-4136C566A962", .pink),
    ]
    for (raw, expected) in pinned {
      let id = try XCTUnwrap(UUID(uuidString: raw))
      XCTAssertEqual(SnipList.automaticColor(for: id), expected, raw)
      XCTAssertEqual(list("Any", id: id).tint, expected, raw)
    }
  }

  func testAutomaticColorsSpreadAcrossThePalette() {
    let colors = Set((0..<200).map { _ in SnipList.automaticColor(for: UUID()) })
    XCTAssertGreaterThanOrEqual(colors.count, 8)
    XCTAssertFalse(colors.contains(.slate))
  }

  func testChosenColorWinsAndInboxStaysNeutral() {
    var value = list("Travel")
    value.color = .slate
    XCTAssertEqual(value.tint, .slate)
    XCTAssertNil(SnipList.inbox.tint)
  }

  func testCreatingListWithoutIconKeepsItEmpty() throws {
    var state = SnipLibraryState(snips: [], lists: [.inbox], seenRequestIDs: [])
    let outcome = try state.perform(
      .createList(name: "Ideas", systemImage: ""),
      prepareAttachments: { _, _ in [] }, pruneAttachments: { _, _ in }
    )
    guard case .listCreated(let created) = outcome else {
      return XCTFail("Expected a created list.")
    }
    XCTAssertEqual(created.systemImage, "")
    XCTAssertEqual(created.mark(), .letters("I"))
  }

  private func list(_ name: String, systemImage: String = "", id: UUID = UUID()) -> SnipList {
    SnipList(id: id, name: name, systemImage: systemImage, position: 1)
  }
}
