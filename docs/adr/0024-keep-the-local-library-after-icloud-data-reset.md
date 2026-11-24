# 0024: Keep the local library after an iCloud data reset

When CloudKit reports a zone purge or encrypted-data reset, Snip Snap stops iCloud sync and keeps the existing library writable on this device. The same rule applies when the current account's control record is missing or no longer describes this device's collection: it names other zones or a different generation. A different generation means another device already turned sync on again after a reset this device missed. Snip Snap promotes available downloaded attachments to durable local storage and clears the retired generation’s engine state and pending CloudKit work.

Background sync cannot upload the kept library. Turning on iCloud sync again requires an explicit user action. Setup fetches the current generation, or creates one with new zones when the record is missing or still names the reset generation. It then merges the kept library by record ID and sends the result through the normal queue. It also stages the reset generation's zones for deletion. [ADR 0018](0018-use-a-generation-marker-for-cloud-resets.md) describes what that merge can bring back.

This decision replaces this ADR’s original cache-discard rule (#421). It also replaces [ADR 0020](0020-require-a-user-choice-after-encrypted-data-reset.md).
