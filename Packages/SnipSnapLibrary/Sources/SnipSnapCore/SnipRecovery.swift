import Foundation

public struct SnipRecoveryScope: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum RecoveredSnipField: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case text
  case source
  case done
  case placement
}

public enum RecoveredListField: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case name
  case icon
  case color
}

public enum RecoveredSnipState: String, Codable, Equatable, Sendable {
  case pending
  case promoted
}

public struct RecoveredSnip: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let currentSnipID: UUID
  public let recovered: Snip
  public let conflictingFields: Set<RecoveredSnipField>
  public let state: RecoveredSnipState

  public init(
    id: UUID,
    currentSnipID: UUID,
    recovered: Snip,
    conflictingFields: Set<RecoveredSnipField>,
    state: RecoveredSnipState = .pending
  ) {
    self.id = id
    self.currentSnipID = currentSnipID
    self.recovered = recovered
    self.conflictingFields = conflictingFields
    self.state = state
  }

  public func promoted(recovered promotedSnip: Snip? = nil) -> Self {
    Self(
      id: id,
      currentSnipID: currentSnipID,
      recovered: promotedSnip ?? recovered,
      conflictingFields: conflictingFields,
      state: .promoted
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id, currentSnipID, recovered, conflictingFields, state
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    currentSnipID = try container.decode(UUID.self, forKey: .currentSnipID)
    recovered = try container.decode(Snip.self, forKey: .recovered)
    conflictingFields = Set(
      try container.decode([RecoveredSnipField].self, forKey: .conflictingFields)
    )
    state = try container.decode(RecoveredSnipState.self, forKey: .state)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(currentSnipID, forKey: .currentSnipID)
    try container.encode(recovered, forKey: .recovered)
    try container.encode(
      conflictingFields.sorted { $0.rawValue < $1.rawValue },
      forKey: .conflictingFields
    )
    try container.encode(state, forKey: .state)
  }
}

public struct RecoveredListEdit: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let currentListID: UUID
  public let recovered: SnipList
  public let conflictingFields: Set<RecoveredListField>

  public init(
    id: UUID,
    currentListID: UUID,
    recovered: SnipList,
    conflictingFields: Set<RecoveredListField>
  ) {
    self.id = id
    self.currentListID = currentListID
    self.recovered = recovered
    self.conflictingFields = conflictingFields
  }

  private enum CodingKeys: String, CodingKey {
    case id, currentListID, recovered, conflictingFields
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    currentListID = try container.decode(UUID.self, forKey: .currentListID)
    recovered = try container.decode(SnipList.self, forKey: .recovered)
    conflictingFields = Set(
      try container.decode([RecoveredListField].self, forKey: .conflictingFields)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(currentListID, forKey: .currentListID)
    try container.encode(recovered, forKey: .recovered)
    try container.encode(
      conflictingFields.sorted { $0.rawValue < $1.rawValue },
      forKey: .conflictingFields
    )
  }
}

public enum SnipRecoveryRecord: Codable, Equatable, Sendable {
  case snip(RecoveredSnip)
  case list(RecoveredListEdit)

  public var id: UUID {
    switch self {
    case .snip(let item): item.id
    case .list(let item): item.id
    }
  }
}

public struct SnipRecoverySnapshot: Equatable, Sendable {
  public let pendingSnips: [RecoveredSnip]
  public let promotedSnips: [RecoveredSnip]
  public let pendingLists: [RecoveredListEdit]

  public init(
    pendingSnips: [RecoveredSnip] = [],
    promotedSnips: [RecoveredSnip] = [],
    pendingLists: [RecoveredListEdit] = []
  ) {
    self.pendingSnips = pendingSnips
    self.promotedSnips = promotedSnips
    self.pendingLists = pendingLists
  }

  public var needsAttentionCount: Int {
    pendingSnips.count + pendingLists.count
  }

  public static let empty = Self()
}

public enum SnipRecoveryChoice: Equatable, Sendable {
  case keepCurrent
  case useRecovered
  case keepBoth
  case editSnip(Snip)
  case editList(SnipList)
}
