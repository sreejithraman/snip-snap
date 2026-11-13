# 0031: Keep iOS file locks out of the App Group while suspendable

iOS terminates a suspended app with `0xdead10cc` when it holds a file or SQLite
lock in a shared container. The iOS app keeps its SwiftData stores in its own
container, and it takes App Group file locks only while it cannot be suspended.

## Store location

The local store (`Local/`) and sync-mode stores (`SyncMode/`) live under the
app's `Application Support/Snip Snap Library`. Only the main app opens them
(ADR 0016), so they gain nothing from the App Group. The Share extension keeps
writing pending imports there, and the app keeps its attachment caches there
(ADR 0029); neither holds a lock.

On launch, before any store opens, the app moves each directory out of the App
Group with one atomic rename. The two directories do not refer to each other,
so each moves on its own. A directory that cannot move stays in use where it is
and is recorded as a `library.relocate` failure. If the destination already
exists, the app uses it and leaves the App Group copy untouched for recovery.
An older build installed after the move does not see the moved library.

## Diagnostic history

The app and Share extension share one diagnostic history in the App Group and
serialize it with `flock`. A process-wide gate admits that lock. The iOS app
closes the gate at launch and opens it when UIKit reports the app active. On
entering the background, it starts a UIKit background task inside that
callback, closes the gate, and ends the task once current holders unlock.
Events recorded while the gate is closed wait in the writer's bounded queue.

## Rejected approach

Builds 149 through 185 wrapped each lock in `performExpiringActivity`. Build
185 still died with both lock holders inside admitted activities and no expiry
callback delivered. Apple DTS describes background task requests made after a
wake, from another thread, as unable to guarantee that suspension has not
already started. Per-operation execution requests stay for the Share extension
and store work, but they no longer protect against this termination.
