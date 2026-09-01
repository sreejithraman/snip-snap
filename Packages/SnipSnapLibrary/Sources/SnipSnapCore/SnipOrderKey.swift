import Foundation

/// A dense, sync-safe position. Values sort as base-256 fractions between zero and one.
public struct SnipOrderKey: Codable, Equatable, Hashable, Sendable, Comparable {
  package static let maximumByteCount = 64
  private let digits: [UInt8]
  package let requiresLegacyBackfill: Bool

  package init(rawDigits: [UInt8]) {
    precondition(Self.isCanonical(rawDigits))
    digits = rawDigits
    requiresLegacyBackfill = false
  }

  package init(data: Data) throws {
    let digits = Array(data)
    guard Self.isCanonical(digits) else { throw SnipOrderKeyError.invalidData }
    self.digits = digits
    requiresLegacyBackfill = false
  }

  package var data: Data { Data(digits) }

  package static func legacy(_ position: Int64) -> SnipOrderKey {
    var encoded = (UInt64(bitPattern: position) ^ (1 << 63)).bigEndian
    let bytes = withUnsafeBytes(of: &encoded) { Array($0) }
    return SnipOrderKey(digits: [128] + bytes + [128], requiresLegacyBackfill: true)
  }

  private init(digits: [UInt8], requiresLegacyBackfill: Bool) {
    precondition(Self.isCanonical(digits))
    self.digits = digits
    self.requiresLegacyBackfill = requiresLegacyBackfill
  }

  private enum CodingKeys: String, CodingKey { case digits }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let digits = try container.decode([UInt8].self, forKey: .digits)
    guard Self.isCanonical(digits) else { throw SnipOrderKeyError.invalidData }
    self.digits = digits
    requiresLegacyBackfill = false
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(digits, forKey: .digits)
  }

  public static func == (lhs: SnipOrderKey, rhs: SnipOrderKey) -> Bool {
    lhs.digits == rhs.digits
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(digits)
  }

  package static func rebalanced(count: Int) throws -> [SnipOrderKey] {
    guard count >= 0, UInt64(exactly: count) != nil else {
      throw SnipOrderKeyError.tooManyValues
    }
    return (0..<count).map { index in
      var rank = UInt64(index + 1).bigEndian
      let bytes = withUnsafeBytes(of: &rank) { Array($0) }
      return SnipOrderKey(rawDigits: [128] + bytes + [128])
    }
  }

  package var legacyProjection: Int64 {
    guard digits.count == 10, digits.first == 128, digits.last == 128 else { return 0 }
    var encoded: UInt64 = 0
    for byte in digits[1...8] { encoded = (encoded << 8) | UInt64(byte) }
    return Int64(bitPattern: encoded ^ (1 << 63))
  }

  public static func < (lhs: SnipOrderKey, rhs: SnipOrderKey) -> Bool {
    let count = max(lhs.digits.count, rhs.digits.count)
    for index in 0..<count {
      let left = index < lhs.digits.count ? lhs.digits[index] : 0
      let right = index < rhs.digits.count ? rhs.digits[index] : 0
      if left != right { return left < right }
    }
    return false
  }

  package static func between(
    _ lower: SnipOrderKey?,
    _ upper: SnipOrderKey?
  ) -> SnipOrderKey? {
    if let lower, let upper { precondition(lower < upper) }
    let width = max(lower?.digits.count ?? 0, upper?.digits.count ?? 0, 1)
    let left = padded(lower?.digits ?? [], to: width)
    let right = upper.map { padded($0.digits, to: width) }
    let candidate: [UInt8]
    if hasRoomBetween(left, right) {
      candidate = average(left, right)
    } else {
      guard width < maximumByteCount else { return nil }
      candidate = left + [128]
    }
    let canonical = trimmingTrailingZeros(candidate)
    guard isCanonical(canonical) else { return nil }
    return SnipOrderKey(rawDigits: canonical)
  }

  private static func isCanonical(_ value: [UInt8]) -> Bool {
    !value.isEmpty && value.count <= maximumByteCount && value.last != 0
  }

  private static func padded(_ value: [UInt8], to width: Int) -> [UInt8] {
    value + repeatElement(0, count: width - value.count)
  }

  private static func hasRoomBetween(_ left: [UInt8], _ right: [UInt8]?) -> Bool {
    var incremented = left
    var index = incremented.count
    while index > 0 {
      index -= 1
      if incremented[index] < 255 {
        incremented[index] += 1
        return right.map { incremented.lexicographicallyPrecedes($0) } ?? true
      }
      incremented[index] = 0
    }
    return right != nil
  }

  private static func average(_ left: [UInt8], _ right: [UInt8]?) -> [UInt8] {
    let width = left.count
    let leftWide = [UInt8(0)] + left
    let rightWide = right.map { [UInt8(0)] + $0 } ?? ([UInt8(1)] + Array(repeating: 0, count: width))
    var sum = Array(repeating: UInt8(0), count: width + 1)
    var carry = 0
    for index in stride(from: width, through: 0, by: -1) {
      let value = Int(leftWide[index]) + Int(rightWide[index]) + carry
      sum[index] = UInt8(value & 0xff)
      carry = value >> 8
    }
    var quotient = Array(repeating: UInt8(0), count: width + 1)
    var remainder = 0
    for index in quotient.indices {
      let value = remainder * 256 + Int(sum[index])
      quotient[index] = UInt8(value / 2)
      remainder = value % 2
    }
    return Array(quotient.suffix(width))
  }

  private static func trimmingTrailingZeros(_ value: [UInt8]) -> [UInt8] {
    var result = value
    while result.last == 0 { result.removeLast() }
    return result
  }
}

package enum SnipOrderKeyError: Error {
  case invalidData
  case tooManyValues
}
