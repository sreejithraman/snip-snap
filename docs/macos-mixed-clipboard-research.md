# Mixed text and file copy on macOS

Date: September 19, 2026

## Result

macOS has no pasteboard shape that can make every app paste both inline text
and separate file attachments. The receiving app chooses what it reads. Snip
Snap should make that choice clear instead of putting text and files on the
same pasteboard and treating the result as one reliable operation.

The clean default depends on the main target. For normal text fields, use one
pasteboard item with flat RTFD and plain text as two forms of the same content.
For file-first AI inputs such as T3 Code and Codex, also provide a real staged
`Snip Snap Snip.md` file before the attachment file URLs. Such a target can then
attach the Markdown and images instead of dropping the text item. Add explicit
**Copy Text** and **Copy Attachments** commands later if users need exact results.

## Why the current shape cannot be reliable

Apple defines a pasteboard item as one piece of data. One item can offer several
representations of that same data; Apple's example is one rich-text item with
RTFD, RTF, and plain-text forms. A pasteboard can also hold several items, which
represent several pieces of data. [Apple pasteboard overview](https://developer.apple.com/library/archive/documentation/General/Conceptual/Devpedia-CocoaApp/Pasteboard.html)

The receiver controls the result. `readObjects(forClasses:options:)` tries the
requested classes in the receiver's order for each item and returns only items
that match one of those classes. A caller that asks for file URLs can therefore
skip a text-only item while reading every later file item. The sender cannot set
a preference that overrides the receiver's class order. [Apple `readObjects` documentation](https://developer.apple.com/documentation/appkit/nspasteboard/readobjects%28forclasses%3Aoptions%3A%29)

Type order cannot fix this. `availableType(from:)` applies the receiver's list
of preferred types to one item, while `NSPasteboard.types` is only the union of
all item types. [Apple `availableType` documentation](https://developer.apple.com/documentation/appkit/nspasteboarditem/availabletype%28from%3A%29),
[Apple `types` documentation](https://developer.apple.com/documentation/appkit/nspasteboard/types)

This means a pasteboard with item 1 as plain text plus RTFD and items 2 onward
as file URLs does not say “paste all of this together.” It says “here is one
rich-text object and here are several file objects.” A destination may accept
all, some, or only the file objects.

## What other apps do

TextEdit uses the rich-document model. It lets a person put files in a rich
text document, shows each file as an icon, and lets the person drag an attached
file back out. This is the native case where one RTFD representation can keep
text and attachments together. [TextEdit User Guide](https://support.apple.com/guide/textedit/txte5d6611d0/mac)

Maccy shows the cost of trying to round-trip arbitrary pasteboards. It restores
non-file forms through first-item setters, then writes each file URL as its own
item. Its source says that using `writeObjects` for non-file forms can make
formatted text paste more than once. It also merges the two items produced by
some apps into one history record. These workarounds preserve data for later
use, but they do not create one cross-app mixed paste contract. [Maccy clipboard source](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift#L75-L100),
[Maccy capture source](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift#L184-L214)

Apple Notes uses separate commands when the intended result matters. It offers
Copy as Markdown, export as PDF or Markdown, and Share a Copy rather than making
one generic copy operation serve every destination. [Notes import and export guide](https://support.apple.com/guide/notes/import-export-and-print-notes-not201900c07/mac),
[Notes sharing guide](https://support.apple.com/guide/notes/share-notes-and-collaborate-apd4e6e2c9a6/mac)

## Recommended Snip Snap contract

Use content shape and the main target to define Copy. The other commands below
are options for later work, not part of this change:

- **Copy**: text-only snips write one plain-text item. Attachment-only snips
  write one file URL item per attachment. Mixed snips write one item with flat
  RTFD and plain text, then a staged `Snip Snap Snip.md` file and each
  attachment file. Rich targets can keep attachments inline. File-first AI
  inputs can receive the Markdown and attachments as files.
- **Future Copy Text**: write one plain-text item. This gives a sure result in text
  fields and terminals.
- **Future Copy Attachments**: write one file URL item per attachment. This gives a
  sure result in Finder, upload fields, and file-aware apps.
- **Future Share or Export**: use the system share flow or create one durable document
  or bundle when both the text and all files must arrive together.

Use a real staged Markdown file for Copy rather than the drag-only file promise,
then retain it until the pasteboard changes. If Finder support also matters,
future **Copy as Document** command can stage one RTFD document and expose one file URL. Notes
accepts RTFD imports, which makes this a native and testable interchange form.
[Notes import formats](https://support.apple.com/guide/notes/import-export-and-print-notes-not201900c07/mac)

Do not pick a path based on the frontmost app's bundle ID. That would need an
ever-growing set of app rules and still would not identify which control will
receive the paste.

## Checks for the change

Add contract tests for item count and types, not only a paste into `NSTextView`:

- Mixed default Copy has one item with flat RTFD and plain text, then one staged
  Markdown file and each attachment file.
- A future Copy Text command has exactly one plain-text item.
- A future Copy Attachments command has one file URL item per readable attachment.
- A future Copy as Document command has one file URL item that opens as an RTFD
  document containing the text and all attachments.

Then check TextEdit, a plain-text field, Finder, Notes, T3 Code, and Codex.
Record each result by command. One target cannot prove the behavior of the
others because Apple leaves the read choice to the receiving app.
