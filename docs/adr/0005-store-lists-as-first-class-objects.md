# 0005: Store lists as first-class objects

## Context

Lists are user-managed destinations. Deriving them from the list name on each snip makes an empty list disappear and gives renaming, reordering, drafts, and active-list state no stable owner.

## Decision

Store lists directly with stable IDs, unique names, icons, and order. Keep them when empty. Store a stable list ID on each snip. Keep Inbox as a built-in list that cannot be edited or removed. Let list IDs own drafts and active-list state.

Each list stores the name the user chose and the resolved name the app shows. When several list IDs want the same name, which syncing devices can cause, the lowest ID keeps the name and the others get numbered suffixes in ID order. Device clocks and delivery order do not choose, so every device resolves the same names.

## Consequences

List changes and snip changes must stay consistent in one store write. Deleting a user list moves its snips to Inbox and makes Inbox active when the deleted list was active. The model can rename and reorder lists without rewriting their identity, and empty lists survive restart.
