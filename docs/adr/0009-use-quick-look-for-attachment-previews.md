# 0009: Use Quick Look for attachment previews

## Context

Images, Markdown, PDFs, and other files need useful previews in composer drafts and saved snips. Hand-built previews would duplicate file-type logic and would not match native Mac behavior. AppKit's shared `QLPreviewPanel` adds responder-chain ownership that click-to-preview does not need.

## Decision

Use one shared square attachment tile in drafts, snip cards, and editors. Generate image thumbnails with Image I/O and other file thumbnails with `QLThumbnailGenerator`, keyed by file identity and change date, requested size, and display scale. Use the SwiftUI Quick Look modifier when a tile is activated. Keep removal as a separate button. Use the system file icon or a small text preview when neither path can make a thumbnail.

## Consequences

Common file types get native previews and multi-file navigation without a custom preview controller. The preview needs a live readable URL, which saved snips provide through Snip Snap-owned attachment copies. Thumbnail work must remain cancellable, cached, and off the main actor. Finder-style Space-bar preview would need a later attachment selection model and may justify `QLPreviewPanel` then.
