# 0023: Use a short Undo action for Done and deletion

Snip Snap will not keep a general undo and redo history. Marking one or more
snips Done or deleting them shows a short snackbar with one Undo action on
Mac, iPhone, and iPad. Only the latest such action is available. A later
saved-snips change or dismissal ends its Undo window. Copying without changing
saved snips preserves the current Undo.

Copy and Done produce one result after both outcomes are known. Undo reopens
only snips newly marked Done by that action. It never changes the clipboard,
reopens previously Done snips, or changes pinned snips. A successful external
drop uses the same short Done Undo.

## Consequences

Undo does not survive an app restart and does not cover edits, moves, imports,
list changes, or sync work. Done Undo uses guarded inverse edits. It skips snips
changed or deleted since the action and cannot modify a replacement store.
Deletion remains safe during its short restore window because the app retains
the deleted snips and attachments until the user acts or the snackbar ends.

The default Undo window is six seconds. Hover, keyboard focus, and assistive
access keep an actionable snackbar available while it is being used. Ordinary
confirmations last three seconds. A failed inverse write retains its token for
a safe retry while the user resolves the error.

A later failure keeps that inverse recovery separate from the newest error.
If the original Undo error is no longer being shown, a persistent **Retry Undo**
notice keeps its action and error details reachable. Opening those details owns
the recovery presentation until they close. A successful retry clears only the
Undo error; it does not resolve an unrelated failure.

This replaces the general recent-action undo requirement in ADR 0012. ADR 0012 still governs storage, imports, sync-mode changes, stable IDs, and safe retries.
