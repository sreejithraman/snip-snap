# 0016: Use SwiftData with CKSyncEngine

Snip Snap will use SwiftData with managed CloudKit sync disabled for its local record stores. When a device opts into iCloud sync, a `CKSyncEngine` adapter will map the active store's snips, lists, attachments, and deletions to records in the project's private CloudKit database. For on-demand files, attachment metadata will use the normal sync zone while immutable `CKAsset` payload records use a separate zone that automatic fetches exclude. The app will fetch a payload directly by ID after a user action. This costs more code than SwiftData-managed CloudKit sync but gives the app the control required by optional sync, recovered snips, account isolation, and file caching.

## Consequences

The app owns record mapping, pending-change tracking, fetched-change application, engine-state persistence, retries, and conflict rules. It will retain the last accepted server record as a sync shadow, use record-change checks on writes, and perform three-way field merges. Conflict retries will start from the current server record so unknown fields survive edits from older app versions.

The metadata and payload split loses cross-zone atomic writes. Upload must save and confirm an immutable payload before publishing metadata. Download must fetch the payload directly by ID, copy it out of CloudKit staging, and verify its size and hash. Deletion must hide metadata first and retain a cleanup job until its payload is gone. Mac and Simulator tests must prove that excluded payload-zone records do not transfer during normal sync before the project fixes the schema, and the final physical-iPhone check must repeat that path.

The app may ask the engine to fetch or send now, while still accepting that scheduled work depends on system conditions. The app and Share extension may write to the same App Group SwiftData store only when they use the same schema version. The main app alone owns migrations and the sync engine. When the extension cannot confirm the current schema, it will write an atomic pending import for the main app to accept after migration.

Behavior tests use the shared snip-library interface. Cloud tests use a controllable fake at the Cloud transport interface inside `SnipSnapCloud`.
