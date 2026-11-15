import Foundation
import SnipSnapCore
import Testing

@testable import SnipSnapPersistence

@Suite struct CloudAttachmentMergeTests {
  private let payload = CloudTextStorageIdentity(zoneName: "payload", ownerName: "owner", recordName: "p")

  private func value(position: Int = 0, fileName: String = "base.txt", contentType: String? = "public.plain-text")
    -> CloudAttachmentMetadataValue
  {
    CloudAttachmentMetadataValue(
      attachmentID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
      snipID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9)),
      position: position, fileName: fileName, contentType: contentType,
      byteCount: 1, sha256: Data(repeating: 1, count: 32), payloadIdentity: payload
    )
  }

  @Test func aFieldLeftAtItsBaseTakesTheRemoteValue() {
    #expect(CloudAttachmentMerge.field(base: "a", local: "a", remote: "r") == "r")
  }

  @Test func aFieldOnlyThisDeviceChangedKeepsTheLocalValue() {
    #expect(CloudAttachmentMerge.field(base: "a", local: "l", remote: "a") == "l")
  }

  @Test func aFieldBothDevicesChangedKeepsTheLocalValue() {
    #expect(CloudAttachmentMerge.field(base: "a", local: "l", remote: "r") == "l")
  }

  @Test func aRowWithoutABaseKeepsItsWholeLocalRecord() {
    let local = value(position: 2, fileName: "local.txt")
    let merged = CloudAttachmentMerge.metadata(base: nil, local: local, remote: value(fileName: "remote.txt"))
    #expect(merged == local)
  }

  @Test func aRowMergesEachFieldAgainstItsBase() {
    let merged = CloudAttachmentMerge.metadata(
      base: value(position: 1),
      local: value(position: 0),
      remote: value(position: 1, fileName: "remote.txt", contentType: "public.json")
    )
    #expect(merged == value(position: 0, fileName: "remote.txt", contentType: "public.json"))
  }

  @Test func aRemovedContentTypeIsAFieldEdit() {
    let merged = CloudAttachmentMerge.metadata(
      base: value(), local: value(contentType: nil), remote: value(fileName: "remote.txt")
    )
    #expect(merged == value(fileName: "remote.txt", contentType: nil))
  }

  // MARK: Order

  private static func id(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
  }

  private let b = Self.id(1), c = Self.id(2), a = Self.id(3), n = Self.id(4), m = Self.id(5)

  private var initial: [UUID: Int] { [a: 0, b: 1, c: 2] }
  private var remoteReorder: [UUID: Int] { [c: 0, a: 1, b: 2] }

  private func merge(
    local: [UUID], arrived: [UUID] = [], base: [UUID: Int], remote: [UUID: Int]
  ) -> [UUID] {
    let order = CloudAttachmentMerge.order(local: local, arrived: arrived, base: base, remote: remote)
    #expect(order.count == Set(local + arrived).count && Set(order) == Set(local + arrived),
      "The merged order must hold every member once.")
    return order
  }

  @Test func theLocalOrderWinsWhenTheRemoteSideDidNotReorder() {
    #expect(merge(local: [b, a, c], base: initial, remote: initial) == [b, a, c])
  }

  @Test func theRemoteOrderWinsWhenOnlyTheRemoteSideReordered() {
    #expect(merge(local: [a, b, c], base: initial, remote: remoteReorder) == [c, a, b])
  }

  @Test func theLocalOrderWinsWhenBothSidesReordered() {
    #expect(merge(local: [b, a, c], base: initial, remote: remoteReorder) == [b, a, c])
  }

  @Test func equalPositionsSortByAttachmentID() {
    #expect(merge(local: [c, b], base: [c: 0, b: 1], remote: [b: 0, c: 0]) == [b, c])
  }

  @Test func shiftedSurvivorsOfARemovalAreNotAReorder() {
    #expect(merge(local: [b, c], base: [a: 0, b: 1, c: 2], remote: [a: 0, b: 1, c: 2]) == [b, c])
  }

  @Test(arguments: [0, 1, 3])
  func anUnpublishedAddKeepsItsIndexUnderARemoteReorder(index: Int) {
    var local = [a, b, c]
    local.insert(n, at: index)
    var expected = [c, a, b]
    expected.insert(n, at: index)
    #expect(merge(local: local, base: initial, remote: remoteReorder) == expected)
  }

  @Test func anArrivedMemberTakesItsRemoteIndexWhenTheLocalOrderWins() {
    var remote = initial
    remote[m] = 3
    #expect(merge(local: [b, a, c], arrived: [m], base: initial, remote: remote) == [b, a, c, m])
  }

  @Test func anArrivedMemberCanPrecedeTheLocalOrder() {
    #expect(merge(local: [a], arrived: [m], base: [a: 0], remote: [m: 0, a: 1]) == [m, a])
  }

  @Test func anArrivedMemberFollowsTheRemoteOrderWhenItWins() {
    let remote = [c: 0, m: 1, a: 2, b: 3]
    #expect(merge(local: [a, b, c], arrived: [m], base: initial, remote: remote) == [c, m, a, b])
  }
}
