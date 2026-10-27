---
name: snip-snap
description: Use when the user asks to save something for later, manage Snip Snap snips or lists, or work on a saved snip's task. Also use when an agent discovers a concrete improvement outside current and planned work.
---

# Snip Snap

Use `snipsnap --help` to discover commands. The CLI starts the app when needed.

## Save for later

Save text when the user asks. Write deferred actions as standalone todos.

When you discover a concrete, worthwhile improvement, check the current task
and any readily available plan or backlog. Save it only when it is outside
both, as a note naming the area, action, and reason. Continue the current work.

## Complete saved work

When you take on a task from a saved snip, keep its ID so you can update that
same snip when you finish. Keep it Not Done while the work is underway.

`snips copy` normally marks the copied snip Done. When copying text to begin
work, pass `--mark-done off` so copying leaves the task open.

Once you complete the work and verify the result, mark the source snip Done
and confirm the update succeeded. If the work is partial or blocked, keep it
Not Done and explain what remains at handoff.

## Use the CLI

Use `--json` for results. Before changing saved data, read
[CLI writes](references/writes.md) for destinations, revisions, and retries.
Confirm the result before reporting success. If saving fails, preserve the
intended text and report it as unsaved at handoff.
