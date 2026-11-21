# 0024: Keep the local library after an iCloud data reset

When CloudKit reports a zone purge or encrypted-data reset, Snip Snap stops iCloud sync and keeps the existing library writable on this device. The same rule applies when the current account has lost its control record or the control record no longer describes the same collection for its generation. Snip Snap promotes available downloaded attachments to durable local storage and clears the retired generation’s engine state and pending CloudKit work.

Background sync cannot upload the kept library. Turning on iCloud sync again requires an explicit user action. Setup merges the kept library into an available fresh generation or creates one with new zones. [ADR 0018](0018-use-a-generation-marker-for-cloud-resets.md) continues to govern Delete Synced Content and adoption of its new generation.

SIMP-ADR24-D1 approved the keep-local behavior for SIMP-08. This decision replaces this ADR’s original cache-discard rule and the reset recovery described in [ADR 0028](0028-let-cksyncengine-schedule-normal-sync.md).
