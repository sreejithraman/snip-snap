import Foundation
import SnipSnapCore
import SwiftData

public enum SnipSnapStoreSchemaContract {
  public static let currentVersion = 9
}

package enum SnipSnapSchemaV1: VersionedSchema {
  package static let versionIdentifier = Schema.Version(1, 0, 0)
  package static var models: [any PersistentModel.Type] {
    [
      StoredSnipRecord.self,
      SnipSnapSchemaV4.StoredListRecord.self,
      StoredAttachmentRecord.self,
      StoredSnipAttachmentReference.self,
      StoredRequestRecord.self,
    ]
  }
}

package enum SnipSnapSchemaV2: VersionedSchema {
  package static let versionIdentifier = Schema.Version(2, 0, 0)
  package static var models: [any PersistentModel.Type] {
    [
      StoredSnipRecord.self,
      SnipSnapSchemaV4.StoredListRecord.self,
      StoredAttachmentRecord.self,
      StoredSnipAttachmentReference.self,
      StoredRequestRecord.self,
      StoredCloudTextRecord.self,
      StoredCloudEngineState.self,
      StoredCloudStagedBatch.self,
      StoredCloudRecoveryEvent.self,
      StoredCloudNamespaceState.self,
    ]
  }
}

package enum SnipSnapSchemaV3: VersionedSchema {
  package static let versionIdentifier = Schema.Version(3, 0, 0)
  package static var models: [any PersistentModel.Type] {
    SnipSnapSchemaV2.models + [
      StoredLibraryMetadataRecord.self,
      StoredCloudEntityRecord.self,
      StoredCloudFullConflict.self,
      StoredCloudFullEnrollment.self,
      StoredCloudDormantBaseRecord.self,
      StoredCloudMappingQuarantine.self,
      StoredCloudFullBatchReceipt.self,
    ]
  }
}

package enum SnipSnapSchemaV4: VersionedSchema {
  // Keep the shipped list model unchanged so existing stores can migrate.
  @Model
  final class StoredListRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var systemImage: String
    var position: Int

    init(_ list: SnipList) {
      id = list.id
      name = list.name
      systemImage = list.systemImage
      position = list.position
    }
  }

  package static let versionIdentifier = Schema.Version(4, 0, 0)
  package static var models: [any PersistentModel.Type] {
    SnipSnapSchemaV3.models + [
      StoredCloudPendingDelete.self,
      StoredCloudAttachmentPublication.self,
      StoredCloudAttachmentCleanup.self,
      StoredCloudAttachmentCacheEntry.self,
    ]
  }
}

package enum SnipSnapSchemaV5: VersionedSchema {
  @Model
  final class StoredListRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var systemImage: String
    var colorID: String = "neutral"
    var position: Int

    init(_ list: SnipList, colorID: String) {
      id = list.id
      name = list.name
      systemImage = list.systemImage
      self.colorID = colorID
      position = list.position
    }
  }

  package static let versionIdentifier = Schema.Version(5, 0, 0)
  package static var models: [any PersistentModel.Type] {
    SnipSnapSchemaV4.models.filter { $0 != SnipSnapSchemaV4.StoredListRecord.self }
      + [StoredListRecord.self]
  }
}

package enum SnipSnapSchemaV6: VersionedSchema {
  // Freeze the shipped list shape. Current code uses the V9 model below.
  @Model
  final class StoredListRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var systemImage: String
    var colorID: String?
    var lightHex: String?
    var darkHex: String?
    var position: Int

    init(
      _ list: SnipList,
      colorID: String? = nil,
      lightHex: String? = nil,
      darkHex: String? = nil
    ) {
      id = list.id
      name = list.name
      systemImage = list.systemImage
      self.colorID = colorID
      self.lightHex = lightHex
      self.darkHex = darkHex
      position = list.position
    }
  }

  package static let versionIdentifier = Schema.Version(6, 0, 0)
  package static var models: [any PersistentModel.Type] {
    SnipSnapSchemaV5.models.filter { $0 != SnipSnapSchemaV5.StoredListRecord.self }
      + [SnipSnapSchemaV6.StoredListRecord.self]
  }
}

package enum SnipSnapSchemaV7: VersionedSchema {
  package static let versionIdentifier = Schema.Version(7, 0, 0)
  package static var models: [any PersistentModel.Type] {
    SnipSnapSchemaV6.models + [StoredSnipPinRecord.self]
  }
}

package enum SnipSnapSchemaV8: VersionedSchema {
  @Model
  final class StoredListRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var systemImage: String
    var lightHex: String?
    var darkHex: String?
    var position: Int

    init(_ list: SnipList, lightHex: String? = nil, darkHex: String? = nil) {
      id = list.id
      name = list.name
      systemImage = list.systemImage
      self.lightHex = lightHex
      self.darkHex = darkHex
      position = list.position
    }
  }

  package static let versionIdentifier = Schema.Version(8, 0, 0)
  package static var models: [any PersistentModel.Type] {
    SnipSnapSchemaV7.models.filter { $0 != SnipSnapSchemaV6.StoredListRecord.self }
      + [SnipSnapSchemaV8.StoredListRecord.self]
  }
}

package enum SnipSnapSchemaV9: VersionedSchema {
  package static let versionIdentifier = Schema.Version(9, 0, 0)
  package static var models: [any PersistentModel.Type] {
    SnipSnapSchemaV8.models.filter { $0 != SnipSnapSchemaV8.StoredListRecord.self }
      + [StoredListRecord.self]
  }
}

package enum SnipSnapSchemaMigrationPlan: SchemaMigrationPlan {
  package static var schemas: [any VersionedSchema.Type] {
    [SnipSnapSchemaV1.self, SnipSnapSchemaV2.self, SnipSnapSchemaV3.self, SnipSnapSchemaV4.self, SnipSnapSchemaV5.self, SnipSnapSchemaV6.self, SnipSnapSchemaV7.self, SnipSnapSchemaV8.self, SnipSnapSchemaV9.self]
  }
  package static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: SnipSnapSchemaV1.self, toVersion: SnipSnapSchemaV2.self),
      .lightweight(fromVersion: SnipSnapSchemaV2.self, toVersion: SnipSnapSchemaV3.self),
      .lightweight(fromVersion: SnipSnapSchemaV3.self, toVersion: SnipSnapSchemaV4.self),
      .lightweight(fromVersion: SnipSnapSchemaV4.self, toVersion: SnipSnapSchemaV5.self),
      .lightweight(fromVersion: SnipSnapSchemaV5.self, toVersion: SnipSnapSchemaV6.self),
      .lightweight(fromVersion: SnipSnapSchemaV6.self, toVersion: SnipSnapSchemaV7.self),
      .lightweight(fromVersion: SnipSnapSchemaV7.self, toVersion: SnipSnapSchemaV8.self),
      .lightweight(fromVersion: SnipSnapSchemaV8.self, toVersion: SnipSnapSchemaV9.self),
    ]
  }

  package static var supportedMarkerSchemaVersions: Set<Int> {
    Set(schemas.compactMap { schema in
      let version = schema.versionIdentifier
      guard version.minor == 0, version.patch == 0 else { return nil }
      return version.major
    })
  }
}
