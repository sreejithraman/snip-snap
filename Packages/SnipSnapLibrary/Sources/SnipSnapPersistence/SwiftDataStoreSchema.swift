import SwiftData

public enum SnipSnapStoreSchemaContract {
  public static let currentVersion = 4
}

package enum SnipSnapSchemaV1: VersionedSchema {
  package static let versionIdentifier = Schema.Version(1, 0, 0)
  package static var models: [any PersistentModel.Type] {
    [
      StoredSnipRecord.self,
      StoredListRecord.self,
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
      StoredListRecord.self,
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

package enum SnipSnapSchemaMigrationPlan: SchemaMigrationPlan {
  package static var schemas: [any VersionedSchema.Type] {
    [SnipSnapSchemaV1.self, SnipSnapSchemaV2.self, SnipSnapSchemaV3.self, SnipSnapSchemaV4.self]
  }
  package static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: SnipSnapSchemaV1.self, toVersion: SnipSnapSchemaV2.self),
      .lightweight(fromVersion: SnipSnapSchemaV2.self, toVersion: SnipSnapSchemaV3.self),
      .lightweight(fromVersion: SnipSnapSchemaV3.self, toVersion: SnipSnapSchemaV4.self),
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
