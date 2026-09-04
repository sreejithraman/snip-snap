# 0012: Use one record schema for local and optional iCloud storage

Snip Snap will use one record-based persistence schema for snips, lists, and attachments. Each device starts in local-only mode and may opt into a separate local cache backed by the user's private CloudKit database. The app will expose one active collection on each device and will copy or merge records when the user changes modes. This avoids permanent JSON and CloudKit implementations with different behavior while keeping iCloud optional.

## Consequences

JSON is a backup, import, and export format, not the live store. Launch opens the SwiftData store and does not copy leftover `snips.json`. A backup imported while sync is on will show a preview, merge through the normal record rules, and send accepted changes through the normal sync path. Mode changes must be safe to retry, preserve stable IDs, keep the prior store active after failure, and never treat turning off sync as a request to delete iCloud data. Enabling sync while offline may enter Setting Up, but local-only mode remains active until Snip Snap can fetch the remote collection and finish the first merge. Undo will create normal inverse edits for recent actions taken on the current device. It will never replace the whole store, and the app will remove an undo entry if a remote change makes that inverse unsafe. This decision supersedes ADR 0001.
