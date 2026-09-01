# 0023: Use a short Undo action for snip deletion

Snip Snap will not keep a general undo and redo history. Deleting one or more snips will show a short toast with one Undo action on Mac, iPhone, and iPad. The app will keep only the latest deletion available for restore while that toast remains on screen. Another saved-snips change or the end of the toast will commit the deletion.

## Consequences

Undo does not survive an app restart and does not cover edits, moves, imports, list changes, or sync work. Deletion remains safe during the short restore window because the app keeps the deleted snips and their attachments until the user acts or the toast ends. The next deletion replaces the prior restore choice.

This replaces the general recent-action undo requirement in ADR 0012. ADR 0012 still governs storage, imports, sync-mode changes, stable IDs, and safe retries.
