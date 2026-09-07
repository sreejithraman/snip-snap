import Foundation

/// A list's saved colors. Both values change together, including during sync.
public struct SnipListColor: Codable, Equatable, Hashable, Sendable {
  public let light: String
  public let dark: String

  public init?(light: String, dark: String) {
    guard let light = Self.normalized(light), let dark = Self.normalized(dark) else { return nil }
    self.light = light
    self.dark = dark
  }

  private static func normalized(_ value: String) -> String? {
    let bytes = Array(value.utf8)
    guard bytes.count == 7, bytes.first == 35,
      bytes.dropFirst().allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }) else { return nil }
    return value.uppercased()
  }

  private enum CodingKeys: String, CodingKey { case light, dark }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let light = try values.decode(String.self, forKey: .light)
    let dark = try values.decode(String.self, forKey: .dark)
    guard let color = Self(light: light, dark: dark) else {
      throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath, debugDescription: "List colors must use #RRGGBB."))
    }
    self = color
  }
}

/// Presets provide names in the picker. Lists save their values, not these IDs.
public enum SnipListColorPreset: String, CaseIterable, Sendable {
  case neutral, red, orange, yellow, green, blue, indigo, violet

  public var color: SnipListColor? {
    switch self {
    case .neutral: nil
    case .red: SnipListColor(light: "#E81345", dark: "#FF2454")
    case .orange: SnipListColor(light: "#FF7800", dark: "#FF8A00")
    case .green: SnipListColor(light: "#00B84F", dark: "#00DB63")
    case .yellow: SnipListColor(light: "#F5C400", dark: "#FFD000")
    case .blue: SnipListColor(light: "#007AFF", dark: "#008CFF")
    case .violet: SnipListColor(light: "#9822EE", dark: "#AF32FF")
    case .indigo: SnipListColor(light: "#4636E8", dark: "#604AFF")
    }
  }

  public static func color(forLegacyID id: String) -> SnipListColor? {
    switch id {
    // Migration values must not follow later picker palette changes.
    case "purple", "violet": SnipListColor(light: "#9822EE", dark: "#AF32FF")
    case "red": SnipListColor(light: "#E81345", dark: "#FF2454")
    case "orange": SnipListColor(light: "#FF7800", dark: "#FF8A00")
    case "yellow": SnipListColor(light: "#F5C400", dark: "#FFD000")
    case "green": SnipListColor(light: "#00B84F", dark: "#00DB63")
    case "blue": SnipListColor(light: "#007AFF", dark: "#008CFF")
    case "indigo": SnipListColor(light: "#4636E8", dark: "#604AFF")
    case "teal": SnipListColor(light: "#1C807A", dark: "#82FAF3")
    case "pink": SnipListColor(light: "#801C4C", dark: "#FA82BC")
    default: nil
    }
  }

}

public enum SnipListColorChange: Equatable, Sendable {
  case keep
  case set(SnipListColor?)
}
