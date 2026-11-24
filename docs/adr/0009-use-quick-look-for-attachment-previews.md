# 0009: Use Quick Look for attachment previews

## Context

Images, Markdown, PDFs, and other files need useful previews in composer drafts and saved snips. Hand-built previews would duplicate file-type logic and would not match native Mac behavior. AppKit's shared `QLPreviewPanel` adds responder-chain ownership that click-to-preview does not need.

## Decision

Use one shared square attachment tile in drafts, snip cards, and editors. Generate image thumbnails with Image I/O and other file thumbnails with `QLThumbnailGenerator`, keyed by file identity and change date, requested size, and display scale. Use the SwiftUI Quick Look modifier when a tile is activated. Keep removal as a separate button. Use the system file icon or a small text preview when neither path can make a thumbnail.

## Consequences

Common file types get native previews and multi-file navigation without a custom preview controller. The preview needs a live readable URL, so the app prepares the attachment first. With iCloud sync on, that can download a file whose bytes are not on the device ([ADR 0029](0029-store-cloud-attachment-downloads-in-caches.md)). Thumbnail work must remain cancellable, cached, and off the main actor. Finder-style Space-bar preview would need a later attachment selection model and may justify `QLPreviewPanel` then.

The command-line preview (`snipsnap attachments preview`) is the one use of `QLPreviewPanel`. A command has no activated tile or SwiftUI binding, so the app shows the one prepared file in the shared panel through its own data source.

## iOS image viewer update (2026-09-23)

On iOS, open still images in a full-screen image viewer with pinch and double-tap zoom, panning, and a downward swipe to dismiss at the base zoom. Keep a visible close button. Continue to use Quick Look for animated images and other files so animation and document preview stay native. The Mac preview remains in Quick Look. Classify the selected file away from SwiftUI's render path, and decode full-screen images to the display size off the main actor.
