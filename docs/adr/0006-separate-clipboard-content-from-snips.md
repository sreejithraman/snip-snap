# 0006: Keep Clipboard content separate from snips

The local-only requirement for clipboard history is replaced by [ADR 0025](0025-opt-in-clipboard-history-sync.md). The separate models and lifetimes below still apply. With iCloud sync on, a saved attachment's bytes may be a download that the device can fetch again ([ADR 0029](0029-store-cloud-attachment-downloads-in-caches.md)).

## Context

The macOS pasteboard can hold several forms of one copied value, including rich text, images, file URLs, and plain text. Snips need a small, stable shape that coding tools and other apps can accept. Treating clipboard history as a list would make snips rich documents and make Save behave like a move from a system history that cannot move entries.

## Decision

Keep clipboard history in its own local store. Let entries retain useful pasteboard forms for later paste. Store snips as a plain-text body plus local copies of file attachments. Saving a Clipboard entry converts its useful content into that snip shape, adds the new snip to the active list, and leaves history unchanged.

## Consequences

Clipboard entries and snips use different models and lifetimes. A copied source file can disappear before the user saves it, while a saved attachment remains available because Snip Snap owns its copy. Snip Snap can preserve useful paste behavior without becoming a rich-text editor or putting inline images in snip bodies.
