# 0020: Require a user choice after an encrypted-data reset

Status: superseded by ADR-0024

When CloudKit reports an encrypted-data reset, Snip Snap will stop cloud sends and treat the next synced collection as a new generation. It will preserve the device's durable data as a read-only local recovery copy and clear the old pending CloudKit work, sync shadow, downloaded-file cache, and engine state. The app will offer Restore from This Device, Start Empty, and Keep Sync Off. It will not upload or combine every device's old cache automatically.

## Consequences

Only the device the user chooses may seed the new generation. Other devices must fetch that generation before sending and keep their prior copies local until the user exports, imports, or deletes them. A later import uses the normal preview, field merge, and conflict review. This adds a recovery screen and local retained data, but it prevents a stale offline copy from replacing the recovery source the user chose. Apple's current encrypted-data-reset pages give conflicting resend advice, but this explicit user choice remains safe under either behavior and does not require a ruling from Apple.
