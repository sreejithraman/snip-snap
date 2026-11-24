# 0031: Keep iOS file locks out of the App Group

iOS terminates a suspended app with `0xdead10cc` when it holds a file or SQLite
lock in a shared container. The iOS app keeps its SwiftData stores in its own
container and takes no file lock in the App Group.

## Store location

The local store (`Local/`) and sync-mode stores (`SyncMode/`) live under the
app's `Application Support/Snip Snap Library`. Only the main app opens them
(ADR 0016), so they gain nothing from the App Group. The Share extension keeps
writing pending imports to the App Group, and the app keeps its attachment
caches (ADR 0029) and iOS clipboard history there; none of them holds a lock.

On launch, before any store opens, the app moves each directory out of the App
Group with one atomic rename. The two directories do not refer to each other,
so each moves on its own. A directory that cannot move stays in use where it is
and is recorded as a `library.relocate` failure. If the destination already
exists, the app uses it, leaves the App Group copy untouched, and records
`library.relocationConflict`. The app does not read that copy again; only a
forward fix or a manual move can bring it back. An older build installed after
the move does not see the moved library.

## Diagnostic history

The app and Share extension each keep their own capped diagnostic log in their
own container, so diagnostics take no App Group file lock. They share only the
opt-out preference in the App Group. This replaces the shared history, its
`flock`, and the process-wide lock gate that this record first described.

## Rejected approach

Builds 149 through 185 wrapped each lock in `performExpiringActivity`. Build
185 still died with both lock holders inside admitted activities and no expiry
callback delivered. Builds 149 and 150 died while SQLite checkpointed
`snips.store` with no app lock held, so SQLite's own locks are enough. Apple DTS
describes background task requests made after a wake, from another thread, as
unable to guarantee that suspension has not already started
([forum thread 126438](https://developer.apple.com/forums/thread/126438)). A
per-operation execution request stays around the store lock, but it no longer
protects against this termination.

Apple does not document that locks outside shared containers are exempt. That
rule comes from developer reports, including apps whose terminations stopped
after moving SQLite out of the App Group.
