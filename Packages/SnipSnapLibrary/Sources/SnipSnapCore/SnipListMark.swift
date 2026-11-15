import Foundation

/// What a list shows beside its name: its chosen symbol, or letters from its name.
public enum SnipListMark: Equatable, Sendable {
  case icon(String)
  case letters(String)
}

extension SnipList {
  /// Symbols older builds saved on every new list. They mean no icon was chosen.
  /// Older builds still create lists with them, so they stay a read rule, not a migration.
  public static let legacyDefaultIcons: Set<String> = ["list.bullet", "circle.grid.2x2.fill"]

  /// Colors a list can get without a choice, in a fixed order so every device derives the same one.
  /// Slate is left out because it reads as neutral. Changing this list's order or length recolors existing lists.
  public static let automaticColors: [SnipListColorPreset] = [
    .red, .orange, .yellow, .green, .teal, .blue, .indigo, .violet, .pink, .clay,
  ]

  /// The chosen symbol, or nil when the list shows letters.
  /// Stored as an empty string: every synced build requires the field to be present.
  public var icon: String? { Self.icon(stored: systemImage) }

  public static func icon(stored systemImage: String) -> String? {
    systemImage.isEmpty || legacyDefaultIcons.contains(systemImage) ? nil : systemImage
  }

  /// The chosen color, or one derived from the list's ID. The Inbox stays neutral.
  public var tint: SnipListColorPreset? {
    color ?? (id == Self.inboxID ? nil : Self.automaticColor(for: id))
  }

  public static func automaticColor(for id: UUID) -> SnipListColorPreset {
    // FNV-1a over the UUID bytes: unlike `hashValue`, it is the same in every process.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    withUnsafeBytes(of: id.uuid) { bytes in
      for byte in bytes {
        hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
      }
    }
    return automaticColors[Int(hash % UInt64(automaticColors.count))]
  }

  /// The first letter or digit of each of the first two words, uppercased.
  /// A name without letters or digits uses its first character, such as an emoji.
  public static func letters(for name: String) -> String {
    let words = name.split(whereSeparator: \.isWhitespace)
    let initials = words
      .compactMap { word in word.first(where: { $0.isLetter || $0.isNumber }) }
      .prefix(2)
    if !initials.isEmpty { return String(initials).uppercased() }
    return words.first?.first.map(String.init) ?? ""
  }

  /// `isAvailable` reports whether this OS can draw a symbol; a list whose symbol it can't draw shows letters.
  public func mark(isAvailable: (String) -> Bool = { _ in true }) -> SnipListMark {
    if let icon, isAvailable(icon) { return .icon(icon) }
    return .letters(Self.letters(for: resolvedName))
  }
}
