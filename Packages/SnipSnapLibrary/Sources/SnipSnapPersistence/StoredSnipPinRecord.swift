import Foundation
import SwiftData

@Model
final class StoredSnipPinRecord {
  @Attribute(.unique) var id: UUID
  var pinnedAt: Date

  init(id: UUID, pinnedAt: Date) {
    self.id = id
    self.pinnedAt = pinnedAt
  }
}

extension ModelContext {
  func snipPinnedAt(_ id: UUID) throws -> Date? {
    try fetch(FetchDescriptor<StoredSnipPinRecord>(
      predicate: #Predicate { $0.id == id }
    )).first?.pinnedAt
  }

  func setSnipPinnedAt(_ pinnedAt: Date?, id: UUID) throws {
    let records = try fetch(FetchDescriptor<StoredSnipPinRecord>(
      predicate: #Predicate { $0.id == id }
    ))
    if let pinnedAt {
      if let record = records.first { record.pinnedAt = pinnedAt }
      else { insert(StoredSnipPinRecord(id: id, pinnedAt: pinnedAt)) }
    } else {
      records.forEach { delete($0) }
    }
  }
}
