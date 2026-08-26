# 0005: Store lists as first-class objects

## Context

Lists are user-managed destinations. Deriving them from the list name on each snip makes an empty list disappear and gives renaming, reordering, drafts, and active-list state no stable owner.

## Decision

Store lists directly with stable IDs, unique names, icons, and order. Keep them when empty. Store a stable list ID on each snip. Keep Inbox as a built-in list that cannot be renamed or removed. Let list IDs own drafts and active-list state.

## Consequences

List changes and snip changes must stay consistent in one store write. Deleting a user list must choose a destination for its snips and fall back to Inbox when it was active. The model can rename and reorder lists without rewriting their identity, and empty lists survive restart.
