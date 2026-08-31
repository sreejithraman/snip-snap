# 0018: Use a generation marker for cloud resets

Snip Snap will keep a small control record in a dedicated CloudKit zone. It will contain a random sync generation and the IDs of the active metadata and payload zones. Every device must fetch this record and match its generation before it may send changes. The app will name the user-facing reset action Delete Synced Content because the control record contains no user content but remains after a normal reset.

## Consequences

A reset will first publish a new generation with fresh data zones, then delete the old data zones. A device that finds a generation mismatch will remove old pending cloud work, isolate or clear the old cache, start new sync-engine state, and fetch the new collection before sending. If a device that has synced before finds no control record, it will stop sends, keep a read-only recovery copy, and require one of the choices in [ADR 0020](0020-require-a-user-choice-after-encrypted-data-reset.md). It will not treat the missing record as proof that it may create or upload data. Concurrent resets will use CloudKit record-change tags; the losing device will adopt the accepted generation and clean up unused zones. This control path adds state and tests, but it prevents offline devices and restored backups from bringing deleted content back.
