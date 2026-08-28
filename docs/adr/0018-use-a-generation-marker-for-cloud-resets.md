# 0018: Use a generation marker for cloud resets

Snip Snap will keep a small control record in a dedicated CloudKit zone. It will contain a random sync generation and the IDs of the active metadata and payload zones. Every device must fetch this record and match its generation before it may send changes. The user-facing reset action will be named Delete Synced Content because the control record contains no user content but remains after a normal reset.

## Consequences

A reset will first publish a new generation with fresh data zones, then delete the old data zones. A device that finds a generation mismatch will remove old pending cloud work, isolate or clear the old cache, start new sync-engine state, and fetch the new collection before sending. If a device that has synced before finds no control record, it will treat that absence as an iCloud Settings purge and will not recreate old cloud data. The user must enable sync again to create a new empty generation. Concurrent resets will use CloudKit record-change tags; the losing device will adopt the accepted generation and clean up unused zones. This control path adds state and tests, but it prevents offline devices and restored backups from bringing deleted content back.
