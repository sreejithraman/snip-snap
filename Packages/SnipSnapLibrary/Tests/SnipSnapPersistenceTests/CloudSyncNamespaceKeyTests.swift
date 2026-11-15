import Foundation
import Testing
import SnipSnapPersistence

@Suite struct CloudSyncNamespaceKeyTests {
  private let binding: ICloudSyncNamespaceBinding = {
    let generation = UUID()
    let value = generation.uuidString.lowercased()
    return ICloudSyncNamespaceBinding(
      scope: "private",
      accountLineage: "account-A",
      generation: generation,
      zones: [
        ICloudSyncZoneBinding(name: "snips-\(value)", ownerName: "_defaultOwner"),
        ICloudSyncZoneBinding(name: "payloads-\(value)", ownerName: "_defaultOwner"),
      ]
    )
  }()

  @Test func decodingAKeyReturnsItsBinding() {
    #expect(ICloudSyncNamespaceBinding(namespaceKey: binding.namespaceKey) == binding)
  }

  @Test func decodingAKeyWithoutZonesReturnsItsBinding() {
    let bare = ICloudSyncNamespaceBinding(
      scope: "", accountLineage: "account-A", generation: UUID(), zones: []
    )
    #expect(ICloudSyncNamespaceBinding(namespaceKey: bare.namespaceKey) == bare)
  }

  @Test(arguments: ["account-generation-A", "", "not base64!"])
  func stringsThatAreNotKeysDecodeToNil(_ rawValue: String) {
    #expect(ICloudSyncNamespaceBinding(namespaceKey: CloudSyncNamespaceKey(rawValue: rawValue)) == nil)
  }

  @Test func truncatedKeyDecodesToNil() throws {
    var bytes = try #require(Data(base64Encoded: binding.namespaceKey.rawValue))
    bytes.removeLast()
    #expect(decoded(bytes) == nil)
  }

  @Test func keyWithTrailingBytesDecodesToNil() throws {
    var bytes = try #require(Data(base64Encoded: binding.namespaceKey.rawValue))
    bytes.append(0)
    #expect(decoded(bytes) == nil)
  }

  @Test func keyWithAnotherTagDecodesToNil() throws {
    let tag = Data("snipsnap-cloud-namespace-v1".utf8)
    var bytes = try #require(Data(base64Encoded: binding.namespaceKey.rawValue))
    let tagRange = try #require(bytes.range(of: tag))
    bytes.replaceSubrange(tagRange, with: Data("snipsnap-cloud-namespace-v2".utf8))
    #expect(decoded(bytes) == nil)
  }

  private func decoded(_ bytes: Data) -> ICloudSyncNamespaceBinding? {
    ICloudSyncNamespaceBinding(namespaceKey: CloudSyncNamespaceKey(rawValue: bytes.base64EncodedString()))
  }
}
