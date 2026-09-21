import Foundation
import SnipSnapCore

package struct CloudLocalListMutation: Codable, Equatable, Sendable {
  package let listID: UUID
  package let desiredName: String
  package let systemImage: String
  package let color: SnipListColorPreset?
  package let orderKey: SnipOrderKey

  package init(_ list: SnipList) {
    listID = list.id
    desiredName = list.desiredName
    systemImage = list.systemImage
    color = list.color
    orderKey = list.sortKey
  }

  private enum CodingKeys: String, CodingKey {
    case listID, desiredName, systemImage, color, colorPreset, orderKey
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    listID = try container.decode(UUID.self, forKey: .listID)
    desiredName = try container.decode(String.self, forKey: .desiredName)
    systemImage = try container.decode(String.self, forKey: .systemImage)
    if container.contains(.colorPreset) {
      color = try StoredListColorPresetCodec.decodeIfPresent(
        from: container,
        forKey: .colorPreset
      )
    } else {
      color = try StoredListColorPresetCodec.decodeIfPresent(from: container, forKey: .color)
    }
    orderKey = try container.decode(SnipOrderKey.self, forKey: .orderKey)
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(listID, forKey: .listID)
    try container.encode(desiredName, forKey: .desiredName)
    try container.encode(systemImage, forKey: .systemImage)
    try container.encodeIfPresent(color?.rawValue, forKey: .colorPreset)
    try container.encode(orderKey, forKey: .orderKey)
  }
}

package enum StoredListColorPresetCodec {
  package static func decodeIfPresent<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key
  ) throws -> SnipListColorPreset? {
    guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
    let decoder = try container.superDecoder(forKey: key)
    let single = try decoder.singleValueContainer()
    if let rawValue = try? single.decode(String.self) {
      return SnipListColorPreset(rawValue: rawValue)
    }
    _ = try LegacyPair(from: decoder)
    return nil
  }

  private struct LegacyPair: Decodable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case light, dark }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      guard Set(container.allKeys) == Set(CodingKeys.allCases),
        Self.isHex(try container.decode(String.self, forKey: .light)),
        Self.isHex(try container.decode(String.self, forKey: .dark))
      else {
        throw DecodingError.dataCorrupted(.init(
          codingPath: decoder.codingPath,
          debugDescription: "Legacy list colors must contain only light and dark #RRGGBB values."
        ))
      }
    }

    private static func isHex(_ value: String) -> Bool {
      let bytes = Array(value.utf8)
      return bytes.count == 7 && bytes.first == 35 && bytes.dropFirst().allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }
    }
  }
}
