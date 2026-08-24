# 0005: Store sections as first-class objects

## Context

Sections are user-managed destinations. Deriving them from the section name on each clip makes an empty section disappear and gives renaming, reordering, drafts, and active-section state no stable owner.

## Decision

Store sections directly with stable IDs, unique names, icons, and order. Keep them when empty. Store a stable section ID on each clip. Keep Inbox as a built-in section that cannot be renamed or removed. Let section IDs own drafts and active-section state.

## Consequences

Section changes and clip changes must stay consistent in one store write. Deleting a user section must choose a destination for its clips and fall back to Inbox when it was active. The model can rename and reorder sections without rewriting their identity, and empty sections survive restart.
