import Foundation
import SnipSnapCore

package struct CloudTextStorageIdentity: Codable, Equatable, Hashable, Sendable {
  package let zoneName: String
  package let ownerName: String
  package let recordName: String

  package init(zoneName: String, ownerName: String, recordName: String) {
    self.zoneName = zoneName
    self.ownerName = ownerName
    self.recordName = recordName
  }

  package var key: String {
    var data = Data()
    for value in [ownerName, zoneName, recordName] {
      let bytes = Data(value.utf8)
      var count = UInt64(bytes.count).bigEndian
      withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
      data.append(bytes)
    }
    return data.base64EncodedString()
  }
}

package enum CloudNamespaceBootstrapPhase: String, Codable, Equatable, Sendable {
  case notEnrolled
  case remoteChecked
  case remoteCheckedMissingZone
  case seeding
  case active
  case blocked
}

package struct CloudStagedBatchStorage: Equatable, Sendable {
  package let id: UUID
  package let payload: Data

  package init(id: UUID, payload: Data) {
    self.id = id
    self.payload = payload
  }
}
