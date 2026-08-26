# 0010: Export mixed snips as a file package

## Context

A macOS drag destination chooses which pasteboard items and forms it reads. Snip Snap can offer text and attachments together, but it cannot make an unrelated app consume both or control their insertion order. Following a drop with a hidden paste also depends on target focus and timing, so it can duplicate text or send it to the wrong control.

## Decision

Keep generic snip drag explicit by content shape. A text-only snip exports plain text. An attachment-only snip exports its files. A mixed snip exports a generated `Snip Snap Snip.md` file first, then its attachments, so the destination receives one file-only package. Do not issue a hidden paste after the drop.

## Consequences

File-aware destinations can receive every part of a mixed snip in one drag, while plain text destinations keep the normal text-only path. Some targets may show the generated Markdown file rather than inline text. Any later one-action integration for a named app such as Codex or Claude must be a separate Send Snip command with target-specific behavior.
