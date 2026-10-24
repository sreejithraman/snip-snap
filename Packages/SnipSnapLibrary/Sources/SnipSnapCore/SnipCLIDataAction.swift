import CryptoKit
import Foundation

public enum SnipCLIRecoveryChoice: String, Codable, Equatable, Sendable {
  case keepCurrent = "keep-current"
  case useRecovered = "use-recovered"
  case keepBoth = "keep-both"
  case editSnip = "edit-snip"
  case editList = "edit-list"
}

public enum SnipCLIDataAction: Codable, Equatable, Sendable {
  case exportBackup(path: String)
  case previewBackup(path: String)
  case importBackup(previewID: UUID)
  case cancelBackup(previewID: UUID)
  case listRecovery
  case resolveRecovery(id: UUID, choice: SnipCLIRecoveryChoice, editedSnip: Snip?,
                       editedList: SnipList?, expectedRevision: String)
  case listDrafts
  case showDraft(list: String)
  case saveDraft(list: String, text: String, attachmentPaths: [String], expectedRevision: String)
  case clearDraft(list: String, expectedRevision: String)
  case moveDraft(list: String, destination: String, expectedRevision: String,
                 expectedDestinationRevision: String)
  case saveDraftAsSnip(list: String, destination: String?, expectedRevision: String)
  case listRecoveredDrafts
  case moveRecoveredDraft(id: UUID, expectedRevision: String, expectedDestinationRevision: String)

  public var isReadOnly: Bool {
    switch self {
    case .previewBackup, .listRecovery, .listDrafts, .showDraft, .listRecoveredDrafts: true
    default: false
    }
  }

  /// Keep the enum case decodable without retaining content, paths, or selectors.
  public var compacted: Self {
    switch self {
    case .exportBackup: .exportBackup(path: "")
    case .previewBackup: .previewBackup(path: "")
    case .importBackup, .cancelBackup: self
    case .listRecovery, .listDrafts, .listRecoveredDrafts: self
    case .showDraft: .showDraft(list: "")
    case .resolveRecovery(let id, let choice, _, _, _):
      .resolveRecovery(id: id, choice: choice, editedSnip: nil, editedList: nil, expectedRevision: "")
    case .saveDraft: .saveDraft(list: "", text: "", attachmentPaths: [], expectedRevision: "")
    case .clearDraft: .clearDraft(list: "", expectedRevision: "")
    case .moveDraft:
      .moveDraft(list: "", destination: "", expectedRevision: "", expectedDestinationRevision: "")
    case .saveDraftAsSnip: .saveDraftAsSnip(list: "", destination: nil, expectedRevision: "")
    case .moveRecoveredDraft(let id, _, _):
      .moveRecoveredDraft(id: id, expectedRevision: "", expectedDestinationRevision: "")
    }
  }
}

public struct SnipCLIImportPreview: Codable, Equatable, Sendable {
  public let id: UUID
  public let totalSnipCount: Int
  public let addedSnipCount: Int
  public let recoveredSnipCount: Int
  public let addedListCount: Int
  public let addedAttachmentCount: Int

  public init(_ preview: SavedSnipsImportPreview) {
    id = preview.id
    totalSnipCount = preview.value.totalSnipCount
    addedSnipCount = preview.value.addedSnipCount
    recoveredSnipCount = preview.value.recoveredSnipCount
    addedListCount = preview.value.addedListCount
    addedAttachmentCount = preview.value.addedAttachmentCount
  }
}

public struct SnipCLIDraft: Codable, Equatable, Sendable {
  public let listID: UUID
  public let text: String
  public let attachmentPaths: [String]
  public let revision: String
  public let isRecovered: Bool

  public init(listID: UUID, text: String, attachmentPaths: [String], scope: String,
              isRecovered: Bool = false) {
    self.listID = listID
    self.text = text
    self.attachmentPaths = attachmentPaths
    self.isRecovered = isRecovered
    struct State: Encodable {
      let listID: UUID
      let text: String
      let attachmentPaths: [String]
      let scope: String
      let isRecovered: Bool
    }
    revision = SnipCLIDataRevision.token(State(listID: listID, text: text,
      attachmentPaths: attachmentPaths, scope: scope, isRecovered: isRecovered))
  }
}

public struct SnipCLIRecoveredRecord: Codable, Equatable, Sendable {
  public let record: SnipRecoveryRecord
  public let revision: String

  public init(record: SnipRecoveryRecord, currentSnip: Snip?, currentList: SnipList?) {
    self.record = record
    struct State: Encodable {
      let record: SnipRecoveryRecord
      let currentSnip: Snip?
      let currentList: SnipList?
    }
    revision = SnipCLIDataRevision.token(State(record: record, currentSnip: currentSnip,
                                               currentList: currentList))
  }
}

public struct SnipCLIDataResult: Codable, Equatable, Sendable {
  public var exportPath: String?
  public var importPreview: SnipCLIImportPreview?
  public var recoveredRecords: [SnipCLIRecoveredRecord]?
  public var drafts: [SnipCLIDraft]?
  public var addedSnipCount: Int?
  public var recoveredSnipCount: Int?

  public init(exportPath: String? = nil, importPreview: SnipCLIImportPreview? = nil,
              recoveredRecords: [SnipCLIRecoveredRecord]? = nil, drafts: [SnipCLIDraft]? = nil,
              addedSnipCount: Int? = nil, recoveredSnipCount: Int? = nil) {
    self.exportPath = exportPath
    self.importPreview = importPreview
    self.recoveredRecords = recoveredRecords
    self.drafts = drafts
    self.addedSnipCount = addedSnipCount
    self.recoveredSnipCount = recoveredSnipCount
  }
}

private enum SnipCLIDataRevision {
  static func token(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try! encoder.encode(value))
      .map { String(format: "%02x", $0) }.joined()
  }
}
