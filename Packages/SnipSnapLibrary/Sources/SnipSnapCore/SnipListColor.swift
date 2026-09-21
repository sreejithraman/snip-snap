import Foundation

/// The adaptive display values for a preset. Lists save the preset, not these values.
public struct SnipListColor: Equatable, Hashable, Sendable {
  public let light: String
  public let dark: String

  fileprivate init(presetLight: String, presetDark: String) {
    light = presetLight
    dark = presetDark
  }

}

/// Stable list-color identities. Neutral is represented by a nil preset.
public enum SnipListColorPreset: String, CaseIterable, Codable, Hashable, Sendable {
  case red, orange, yellow, green, teal, blue, indigo, violet, pink, clay, slate

  public var color: SnipListColor {
    switch self {
    case .red: SnipListColor(presetLight: "#E00000", presetDark: "#FF4040")
    case .orange: SnipListColor(presetLight: "#FF7800", presetDark: "#FF8A00")
    case .yellow: SnipListColor(presetLight: "#F5C400", presetDark: "#FFD000")
    case .green: SnipListColor(presetLight: "#00B84F", presetDark: "#00DB63")
    case .teal: SnipListColor(presetLight: "#1C807A", presetDark: "#82FAF3")
    case .blue: SnipListColor(presetLight: "#007AFF", presetDark: "#008CFF")
    case .indigo: SnipListColor(presetLight: "#4636E8", presetDark: "#604AFF")
    case .violet: SnipListColor(presetLight: "#9822EE", presetDark: "#AF32FF")
    case .pink: SnipListColor(presetLight: "#E0007F", presetDark: "#FF4FA3")
    case .clay: SnipListColor(presetLight: "#9A5A3C", presetDark: "#F0A17E")
    case .slate: SnipListColor(presetLight: "#526678", presetDark: "#BBD1E5")
    }
  }
}

public enum SnipListColorChange: Equatable, Sendable {
  case keep
  case set(SnipListColorPreset?)
}
