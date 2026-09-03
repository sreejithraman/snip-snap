# 0024: Discard the sync cache after an iCloud data reset

When CloudKit reports a purge or encrypted-data reset, Snip Snap will stop sends, replace the active library with an empty local-only store, and delete the old store and pending work for that sync generation. It will not offer to restore or upload that cache. This follows the `CKSyncEngine` contract and prevents an old device from bringing back data that the user removed from iCloud.

A user may turn sync on again and add or import data as a new act. A backup import stays separate from sync recovery. This decision replaces [ADR 0020](0020-require-a-user-choice-after-encrypted-data-reset.md) and the missing-control part of [ADR 0018](0018-use-a-generation-marker-for-cloud-resets.md).
