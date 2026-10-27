# CLI writes

## Adding

Read current lists. Honor the requested list; ask if it is missing. Otherwise,
choose the best project or topic match, inspecting candidates when needed.
Ask about equally good matches; use Inbox when requested or no list fits.
Pass its UUID with `--list`, then check the returned destination and name it
in the confirmation.

Record add context with `--session-title` or the current Git `--branch`.
Choose the destination from the content, independently of that provenance.
Send exact add or update text on standard input.

## Changing and retrying

Read targets and use fresh revisions or timestamps required by `--help`.
Reread after writes or conflicts.

Before writing, retain a `--request-id` UUID and the full input. Check uncertain
outcomes with `snipsnap status REQUEST_UUID --json`. Reuse that ID and input,
including text, destination, and context, while pending or processing.
For an unknown outcome or lost ID, inspect current data before any needed fresh
write. After a library switch, reread the active library before a new request.
