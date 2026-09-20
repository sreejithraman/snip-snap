# 0010: Export every form of a mixed snip

## Context

A macOS drag destination chooses which pasteboard items and forms it reads. Snip Snap can offer text and attachments together, but it cannot make an unrelated app consume both or control their insertion order. Following a drop with a hidden paste also depends on target focus and timing, so it can duplicate text or send it to the wrong control.

## Decision

Keep generic snip copy and drag explicit by content shape. A text-only snip exports plain text. An attachment-only snip exports its files. A mixed snip offers one main item with plain text and RTFD, a generated `Snip Snap Snip.md` file, then its attachments. RTFD keeps the text and files together for rich text apps. The Markdown file keeps the text available to file-first inputs such as T3 Code and Codex. Do not issue a hidden paste after the drop.

Build RTFD when its source text and files fit the export's 64 MiB safety limit. The encoded RTFD may exceed the clipboard history's smaller per-form limit due to its wrapper data, so history may omit the rich form while keeping the other forms. When the user restores that entry, rebuild the rich form from its text and readable attachment URLs. Larger source snips still offer plain text, the original files, and the Markdown file.
Prepare the RTFD and stage the Markdown file before Copy writes the pasteboard. Retain the staged file after the write so a later paste can still read it. During drag, build RTFD only when the receiving app asks for that form and fulfill the Markdown through a file promise.

## Consequences

Plain text, rich text, and file-aware destinations can each choose a form they support. Copy and drag share the same main pasteboard shape, which keeps their behavior in sync. The receiving app still chooses which forms it reads, so some targets may show files rather than inline text.
