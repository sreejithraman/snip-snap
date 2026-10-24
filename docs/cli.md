# Command-line access

The Homebrew cask installs `snipsnap` with the Mac app. Commands use the app's
active library and services. The CLI starts its installed app when needed.
It never opens the library database itself. Run `snipsnap --help` for all
commands and exact options.

Every app command accepts `--json` and `--request-id UUID`. JSON results go to
standard output. With `--json`, errors go to standard error as JSON containing
`status`, `code`, `message`, and a request ID when available. Invalid arguments
exit with status 2; other failures exit with status 1.

## Saved snips

Legacy `add`, `list`, `show`, `update`, `delete`, and `lists` commands still work.
`add` and `update` read text from standard input when text is omitted or `-`.
CLI additions have Agent origin.

```sh
snipsnap search "release" --completion not-done --limit 20 --json
snipsnap snips list --list Research --pinned on --sort manual --json
snipsnap show SNIP_UUID --json
snipsnap snips done SNIP_UUID --if-snip-revision REVISION
snipsnap snips pin SNIP_UUID --if-snip-revision REVISION
snipsnap snips copy SNIP_UUID --if-snip-revision REVISION --mark-done off
snipsnap lists show DESTINATION_LIST_UUID --json
snipsnap snips move SNIP_UUID --list DESTINATION_LIST_UUID \
  --if-snip-revision REVISION --if-list-revision LIST_REVISION
```

Take each snip revision from `snipRevisions` in a current JSON read. For multiple
snips, repeat `--if-snip-revision SNIP_UUID:REVISION` once per snip. Multi-snip
commands validate the whole selection before changing it. Reread after each
write or conflict. A pinned snip cannot be Done. Copy marks eligible snips Done
by default; `--mark-done off` only copies.

`snips merge` and `snips delete` require revisions and `--yes`. Deletion returns
`result.library.undoToken`; restore it with `snips undo TOKEN`. Undo uses the
app's current pending deletion. Another saved edit, a newer deletion, or an app
restart can expire it.

## Files and lists

```sh
snipsnap snips add --file ./report.pdf --text "Review this" --list Research
snipsnap attachments add SNIP_UUID ./notes.txt --if-snip-revision REVISION
snipsnap attachments export SNIP_UUID ATTACHMENT_UUID --output ./saved-notes.txt
snipsnap attachments preview SNIP_UUID ATTACHMENT_UUID
snipsnap lists edit LIST_UUID --icon book --color blue --if-list-revision REVISION
```

Attachment IDs appear in snip JSON. `attachments replace` and `attachments
remove` edit individual attachments; removal also requires `--yes`. Exports
refuse to overwrite an existing destination. Synced attachment use prepares
the file through the app, downloading it when needed. Preview opens Quick Look.
List colors use the preset names shown by the app.

`snips move --before UUID|end` places snips manually. `lists move` changes list
order; supply revisions for the moved list and its anchor. Snip-list deletion
continues to move its saved snips to Inbox and refuses to discard a draft.

## Clipboard history

```sh
snipsnap clipboard status --json
snipsnap clipboard list --search "example" --limit 10 --json
snipsnap clipboard show ENTRY_UUID --json
snipsnap clipboard save ENTRY_UUID --list Research --if-revision ENTRY_REVISION
snipsnap clipboard copy ENTRY_UUID --if-revision ENTRY_REVISION
snipsnap clipboard pause --if-revision HISTORY_REVISION
snipsnap clipboard clear --if-revision HISTORY_REVISION --yes
```

Entry reads include entry revisions. `clipboard status` includes the history
revision used for pause, resume, and clear. `pin`, `unpin`, and `delete` use an
entry revision; delete requires `--yes`. Clear removes only unpinned history.
Clipboard entries stay separate from saved snips until explicitly saved.

## Backups, drafts, and recovery

```sh
snipsnap backup export ./SnipSnapBackup
snipsnap backup preview ./SnipSnapBackup --json
snipsnap backup import --if-preview PREVIEW_UUID --yes
snipsnap backup cancel --if-preview PREVIEW_UUID
snipsnap drafts show Inbox --json
snipsnap drafts save Inbox --text "A draft" --if-draft-revision REVISION
snipsnap drafts save-as-snip Inbox --if-draft-revision REVISION
snipsnap recovery list --json
snipsnap recovery resolve RECOVERY_UUID --choice keep-both \
  --if-recovery-revision REVISION
```

Preview and inspect a backup before importing its returned preview ID. Cancel
releases a staged preview without opening an app dialog. Changes
to the reviewed library or backup invalidate the preview. Backups include
attachment bytes. An app restart or a newer preview can expire the preview ID.

Draft move guards both source and destination. Draft clear requires `--yes`.
Use `recovery drafts` and `recovery move-draft` for recovered legacy drafts.
Recovery choices are `keep-current`, `use-recovered`, `keep-both`, `edit-snip`,
and `edit-list`. Edited choices accept `--edited-json FILE` containing the
complete corresponding snip or list from the recovery read. Recovery revisions
cover the reviewed record and its current linked snip or list.

## Settings and app controls

```sh
snipsnap settings show --json
snipsnap settings set appearance dark --if-revision REVISION
snipsnap sync status --json
snipsnap sync clipboard status --json
snipsnap diagnostics status --json
snipsnap diagnostics logs --range 7d --errors-only --limit 100
snipsnap diagnostics logs --range 24h --json
snipsnap diagnostics export ./diagnostics.txt --range 7d
snipsnap diagnostics recording off --if-revision REVISION
snipsnap app status --json
snipsnap app show
snipsnap app select-list Research
snipsnap app search "release"
snipsnap app close-search
snipsnap app clipboard
snipsnap app settings
```

`app select-list` closes global search and shows only the requested list.
`app clipboard` closes search and shows clipboard history. Repeating it keeps
clipboard history open. `app close-search` clears the query and closes search
while keeping the current list and snip or clipboard view. These navigation
commands refuse active editing, dialogs, and reserved library transitions.

Settings include appearance, sort, completion filter, clipboard view options,
keyboard shortcuts, and beta updates. Setters use the revision from the
corresponding settings or status read. Shortcut commands accept physical key
codes and Carbon modifier bits, or the supported double-Shift gestures.

Sync commands expose enable, disable, cancel setup, retry, clipboard sync, and
account-notice resolution. They use the app's existing iCloud transitions and
retry behavior. `sync disable --use-current-cache` explicitly chooses this
device's current copy. Account removal requires `--yes`. Read status after a
transition before issuing library commands.

`diagnostics logs` reads local history directly, even when the app is closed or
unresponsive. It does not launch the app or wait for iCloud. By default it prints
the newest 200 events from the last 24 hours, in chronological order. Pass
`--range 7d`, `--errors-only`, or `--limit N` (1–2000) to narrow the result. Error
filtering happens before the event limit. Plain output is report text; `--json`
returns it in `result.application.values.log`, with `returned-events` and
`truncated` values alongside it. Reports retain privacy-safe metadata and explain
the available history and omissions. This command creates no export file.
Repeated identical errors can appear as one record with a count and first/last
timestamps. `--errors-only` selects failed operations; it excludes routine events
and cancellation notices.
If another process holds the diagnostic store lock, fetching returns a bounded
busy error (`diagnostics_busy` in JSON) instead of waiting indefinitely. Retry the
read shortly; it does not change history or restart the app.

The CLI reads the selected app's logs. `SNIP_SNAP_APP_PATH` selects a Dev app or
another installation. An arbitrary `SNIP_SNAP_STORE_PATH` without a selected app
requires an explicit `SNIP_SNAP_DIAGNOSTICS_DIRECTORY`; it never falls back to
production logs. A bundled CLI also accepts a matching embedded Dev store path.
These overrides are local environment settings, not required contributor
configuration.

Diagnostics exports default to the last 24 hours. Pass `--range 24h` or `--range 7d`
to choose the requested window. Reports identify the actual available history and
any omissions. `diagnostics recording on|off` uses the revision from `diagnostics
status`; stopping recording keeps existing history. This setting affects app-owned
local history, not Apple's system logs. Diagnostic files contain structured
operational events, not snip content, and are never uploaded automatically.

Diagnostics and downloaded-attachment cache clearing each require their own
status revision and `--yes`. `updates check` opens the app's updater when it is
available. `app hide`, `app capture-selection`, and `app capture-screen` expose
the corresponding app actions. Screen capture remains interactive; macOS
controls Accessibility and Screen Recording consent. Capture reports success
after the saved snip exists. CLI commands do not grant system permissions.

## Retries and development

Keep the exact arguments and `--request-id` for any write you may need to
recover. Use `snipsnap status REQUEST_UUID --json` after a timeout. A processing
or uncertain result is not a failed write; inspect its status and current data
before starting another request. Retrying a completed request does not repeat
its mutation. Payloads are compacted after display; created snip/list IDs remain
available. Read again to obtain current revisions.

Finish active editing or dialogs when a command asks you to. A command never
silently discards an app edit or draft.

For a source checkout, build the CLI with SwiftPM and run the app through
`scripts/run.sh`. Set `SNIP_SNAP_STORE_PATH` to that Dev slot's `items.json`
path when using the standalone CLI. An installed bundled CLI also reads its
app's embedded Dev store path, including through a symlink.
`SNIP_SNAP_APP_PATH` selects an existing app bundle by absolute path.
`SNIP_SNAP_CLI_NO_LAUNCH=1` disables automatic launch. An arbitrary store
override does not auto-launch the production app.
