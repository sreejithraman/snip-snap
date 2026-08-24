# 0006: Keep Clipboard content separate from clips

## Context

The macOS pasteboard can hold several forms of one copied value, including rich text, images, file URLs, and plain text. Clips need a small, stable shape that coding tools and other apps can accept. Treating clipboard history as a section would make clips rich documents and make Save behave like a move from a system history that cannot move entries.

## Decision

Keep clipboard history in its own local store. Let entries retain useful pasteboard forms for later paste. Store clips as a plain-text body plus local copies of file attachments. Saving a Clipboard entry converts its useful content into that clip shape, adds the new clip to the active section, and leaves history unchanged.

## Consequences

Clipboard entries and clips use different models and lifetimes. A copied source file can disappear before the user saves it, while a saved attachment remains available because Snip Snap owns its copy. Snip Snap can preserve useful paste behavior without becoming a rich-text editor or putting inline images in clip bodies.
