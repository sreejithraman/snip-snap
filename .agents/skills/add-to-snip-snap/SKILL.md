---
name: add-to-snip-snap
description: Add text or a future todo to the user's Snip Snap library when the user asks to save something or an agent identifies a worthwhile follow-up outside the current task. Not for immediate tasks, reading, exporting, or editing existing snips.
---

# Add to Snip Snap

Use the installed `snipsnap add` command. It records `.agent` as the snip origin.

Treat an explicitly deferred action as a saved todo when the user asks to remember it, revisit it, follow up, or look into it later. An agent may also save a concrete follow-up it discovers while working when that follow-up is useful but outside the current task. Preserve the action as useful standalone text and continue the current work. An action within the current task remains current work rather than a saved todo.

1. Generate one UUID for the request. Resolve the destination and agent context once. Keep the UUID, text, destination, session title, and branch unchanged across every retry.
2. Send the exact text on standard input so shell quoting cannot alter it. Add `--list NAME` only when the user names a destination; otherwise use Inbox. Add `--session-title TITLE` when the host exposes a human-readable session title. Never pass a session ID as the title. When the title is unavailable, read the current Git branch once and pass it with `--branch NAME`; if there is no branch, omit both context flags. Reuse those exact flags on retries even if the working directory or current branch changes.
3. Pass `--request-id UUID --json`. A zero exit status with `"status":"added"` or `"status":"unchanged"` completes the request. `"status":"pending"` means the request is safely queued; tell the user it will appear when Snip Snap next opens.

If a named destination is deleted before a queued request is imported, Snip Snap saves the text to Inbox.

Provide the snip text through the process's standard input. If the command reports that a list is missing, ask for another list or omit `--list` to use Inbox. Report other failures without claiming the snip was saved.
