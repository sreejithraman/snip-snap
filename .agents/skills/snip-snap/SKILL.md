---
name: snip-snap
description: Save future ideas and text in Snip Snap, or read, update, and delete saved snips and lists when the user asks. Use for concrete agent-discovered improvements outside current and already-planned work. Not for tasks to do now.
---

# Snip Snap

Use the installed `snipsnap` CLI. Run `snipsnap --help` for its current commands and options. If it is unavailable, say what could not be done.

Save text when the user asks. Treat an action they ask to remember, revisit, follow up on, or look into later as a saved todo, written so it makes sense on its own. When you discover a concrete, worthwhile improvement, check the current task and any readily available plan or backlog. Save it only when it is outside both, as a note naming the area, action, and reason. Continue the current work.

Before each new add, read the current lists with `snipsnap lists list --json`. Honor an explicitly requested destination; if it is missing, ask where to save instead. Otherwise, choose the existing list that best fits the snip's project or topic using the request and current work context. If list names are unclear, inspect likely candidates with `snipsnap lists show UUID --json`. Ask when several destinations fit equally well. Use Inbox when the user requests it or no existing list fits. Pass the chosen list's UUID explicitly with `--list`, including for Inbox. Session title and branch are provenance, not list selectors. Check that the returned snip's list matches the chosen destination before reporting success, and name that list in the confirmation.

Snip and list commands require the running app. If Snip Snap is closed when an idea arises during other work, keep the exact idea in task context and continue. At handoff, include the idea, clearly say it was not saved, and offer to open the app and save it. If the user asks to use Snip Snap while it is closed, offer to open the app and retry. Send exact add or update text on standard input. Use `--json` for structured reads. For a snip update, pass its ID and latest `updatedAt` as `--if-updated-at`. For snip delete, pass its ID and token from `snipRevisions` as `--if-snip-revision`. For list rename or delete, pass its ID and latest `listRevision` from `lists show --json` as `--if-list-revision`. Reread after a conflict. A delete also requires `--yes`; check the target before using it.

Read the command's result before claiming success. For a mutation whose outcome may need recovery, supply and retain `--request-id` before sending it. For an uncertain command, check `snipsnap status REQUEST_UUID`; reuse that ID and command while it is pending or processing. If the outcome is unknown, inspect the target and use a new ID only for a needed fresh mutation. Reads can be retried. For `add`, resolve the session title or current Git branch once, pass it explicitly with `--session-title` or `--branch`, and keep that context, request ID, text, and destination unchanged on retries even if the directory or branch changes. If its ID is lost, inspect the current library before adding again. Other commands generate request UUIDs unless you supply one.
If Snip Snap reports that it switched libraries, reread the current library before issuing a new command with a new request ID.
