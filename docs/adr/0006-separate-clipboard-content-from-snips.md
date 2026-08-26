# 0006: Keep Clipboard content separate from snips

## Context

The macOS pasteboard can hold several forms of one copied value, including rich text, images, file URLs, and plain text. Snips need a small, stable shape that coding tools and other apps can accept. Treating clipboard history as a list would make snips rich documents and make Save behave like a move from a system history that cannot move entries.

## Decision

Keep clipboard history in its own local store. Let entries retain useful pasteboard forms for later paste. Store snips as a plain-text body plus local copies of file attachments. Saving a Clipboard entry converts its useful content into that snip shape, adds the new snip to the active list, and leaves history unchanged.

## Consequences

Clipboard entries and snips use different models and lifetimes. A copied source file can disappear before the user saves it, while a saved attachment remains available because Snip Snap owns its copy. Snip Snap can preserve useful paste behavior without becoming a rich-text editor or putting inline images in snip bodies.
