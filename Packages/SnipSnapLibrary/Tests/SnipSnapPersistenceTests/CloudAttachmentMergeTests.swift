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
}
