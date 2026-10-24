import Foundation

/// Additional app capabilities use the same scoped, replay-protected handoff as snip CRUD.
public enum SnipCLIExtendedAction: Codable, Equatable, Sendable {
  case library(SnipCLILibraryAction)
  case clipboard(SnipCLIClipboardAction)
  case data(SnipCLIDataAction)
  case application(SnipCLIApplicationAction)

  public var isReadOnly: Bool {
    switch self {
    case .library(let action): action.isReadOnly
    case .clipboard(let action): action.isReadOnly
    case .data(let action): action.isReadOnly
    case .application(let action): action.isReadOnly
    }
  }

  public var compacted: Self {
    switch self {
    case .library(let action): .library(action.compacted)
    case .clipboard(let action): .clipboard(action.compacted)
    case .data(let action): .data(action.compacted)
    case .application(let action): .application(action.compacted)
    }
  }
}

public enum SnipCLIExtendedResult: Codable, Equatable, Sendable {
  case library(SnipCLILibraryResult)
  case clipboard(SnipCLIClipboardResult)
  case data(SnipCLIDataResult)
  case application(SnipCLIApplicationResult)

  private enum CodingKeys: String, CodingKey { case library, clipboard, data, application }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.allKeys.count == 1, let key = container.allKeys.first else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
        debugDescription: "A CLI result must contain exactly one command group."))
    }
    switch key {
    case .library: self = .library(try container.decode(SnipCLILibraryResult.self, forKey: key))
    case .clipboard: self = .clipboard(try container.decode(SnipCLIClipboardResult.self, forKey: key))
    case .data: self = .data(try container.decode(SnipCLIDataResult.self, forKey: key))
    case .application: self = .application(try container.decode(SnipCLIApplicationResult.self, forKey: key))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .library(let result): try container.encode(result, forKey: .library)
    case .clipboard(let result): try container.encode(result, forKey: .clipboard)
    case .data(let result): try container.encode(result, forKey: .data)
    case .application(let result): try container.encode(result, forKey: .application)
    }
  }
}
