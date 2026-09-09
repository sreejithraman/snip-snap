import CloudKit
import Foundation
import XCTest
@testable import SnipSnapCore
@testable import SnipSnapCloud

final class SnipPinCloudTests: XCTestCase {
  func testEncryptedPinRoundTripAndUnpin() throws {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    var snip = Snip(content: "Reusable", origin: .quickEntry, pinnedAt: Date(timeIntervalSince1970: 123))
    let record = try CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    XCTAssertNil(record["pinnedAt"])
    let typed = try CloudFullRecordCodec.snip(from: CloudKitRecordMapper.snapshot(record))
    XCTAssertEqual(typed.pinnedAt, snip.pinnedAt)
    snip.pinnedAt = nil
    let cleared = try CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, accepted: typed))
    XCTAssertNil(try CloudFullRecordCodec.snip(from: CloudKitRecordMapper.snapshot(cleared)).pinnedAt)
  }

  func testConcurrentPinAndDoneMergesToPinnedNotDone() throws {
    let snip = Snip(content: "Reusable", origin: .quickEntry)
    let base = CloudSnipMergeFields(id: snip.id, requestID: snip.requestID, createdAt: snip.createdAt, originRaw: snip.origin.rawValue, text: snip.content, source: nil, isDone: false, placement: CloudSnipPlacement(listID: snip.listID, orderKey: snip.manualSortKey), updatedAt: snip.updatedAt)
    var local = base
    local.pinnedAt = Date(timeIntervalSince1970: 123)
    var server = base
    server.isDone = true
    let merged = try CloudThreeWayMerge.snip(base: base, local: local, server: server).merged
    XCTAssertEqual(merged.pinnedAt, local.pinnedAt)
    XCTAssertFalse(merged.isDone)
    let reversed = try CloudThreeWayMerge.snip(base: base, local: server, server: local).merged
    XCTAssertEqual(reversed.pinnedAt, local.pinnedAt)
    XCTAssertFalse(reversed.isDone)
  }
}
