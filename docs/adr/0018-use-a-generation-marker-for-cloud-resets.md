# 0018: Use a generation marker for cloud resets

Snip Snap keeps a small control record in a dedicated CloudKit zone. It contains a random sync generation and the IDs of the active metadata and payload zones. Every device must fetch this record and match its generation before it may send changes.

Snip Snap does not offer an in-app reset. Builds before 0.6.0 beta 124, including stable 0.5.0 and 0.5.1, had a Delete Synced Content action in Settings. It published a new generation with fresh data zones, then deleted the old data zones. The control record stayed because it contains no user content. That action and the code that started a reset are removed. This replaces the original decision to offer Delete Synced Content.

## Consequences

A device that finds no control record, a control record that names different zones for its generation, or one that names a different generation missed an iCloud reset. It keeps its library under [ADR 0024](0024-keep-the-local-library-after-icloud-data-reset.md) and turns sync off. It joins the current generation only when the user turns sync on again. That enable fetches the current collection before it merges or sends. A missing record never proves that a device may create or upload data. This replaces adoption: a device no longer swaps in an empty store for a different generation and hides its prior library.

Earlier builds kept that prior library as a read-only recovery copy that nothing shows. Those copies stay on disk as they are. Snip Snap does not delete, open, or import them.

Builds before 0.6.0 beta 124 could also leave a Delete Synced Content removal unfinished. Current builds no longer track it. Each sync still deletes staged zones that the current generation does not use, and a failed deletion is an ordinary sync error.

The generation check adds state and tests. It stops offline devices and restored backups from sending before they fetch the current collection. Because the merge on enable matches records by ID without a shared base, items deleted on another device can come back and conflicting edits can appear as separate snips. This follows ADR 0014's preference for visible extra data over silent loss.
