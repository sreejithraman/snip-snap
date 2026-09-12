# iCloud control-record retry research

Date: September 12, 2026

## Question

Why can the iCloud settings screen report a paused sync, have **Try Again**
fail at once, then work after time passes? This note separates the work that
`CKSyncEngine` owns from direct `CKDatabase` requests that Snip Snap owns. It
does not claim a device reproduction or a root cause.

## Apple guidance

`CKSyncEngine` schedules ordinary record and zone work after callers add
pending changes. It retains a pending change after a recoverable failure and
retries network, account-temporary, rate-limit, service-unavailable, and
zone-busy errors when system conditions permit. In particular, it observes the
server retry-after delay for `requestRateLimited`. The engine needs its saved
state on the next launch. [CKSyncEngine overview](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5), [engine state](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/state-swift.class), [adding pending database changes](https://developer.apple.com/documentation/cloudkit/cksyncenginestate/addpendingdatabasechanges%3A?language=objc).

Apple describes `fetchChanges` and `sendChanges` as manual controls for cases
that need an immediate fetch or send, such as pull to refresh or “backup now.”
They are not needed for normal pending-record sync. [CKSyncEngine overview](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5).

For a direct CloudKit request, `CKError.retryAfterSeconds` is the server's
number of seconds to wait before retrying. Apple says this value is available
for `serviceUnavailable` and `requestRateLimited`; the same value is in
`CKErrorRetryAfterKey`. `requestRateLimited` specifically directs clients to
wait for that value. [retryAfterSeconds](https://developer.apple.com/documentation/cloudkit/ckerror/retryafterseconds), [CKErrorRetryAfterKey](https://developer.apple.com/documentation/cloudkit/ckerrorretryafterkey), [requestRateLimited](https://developer.apple.com/documentation/cloudkit/ckerror/code/requestratelimited).

`zoneBusy` remains a transient error for `CKSyncEngine`, but the current Apple
reference does not say that `retryAfterSeconds` is available for it. A fallback
delay for zone-busy calls is therefore an app choice, not a server deadline.
The Apple sample leaves `networkFailure`, `networkUnavailable`, `zoneBusy`,
`serviceUnavailable`, `notAuthenticated`, and `operationCancelled` for the
engine to retry. [Apple CKSyncEngine sample](https://github.com/apple/sample-cloudkit-sync-engine/blob/main/SyncEngine/SyncedDatabase.swift#L250-L252).

## Relevant local paths and the change

`CloudKitRecordTransport` puts normal record and zone changes into
`CKSyncEngine.State`, leaves automatic sync enabled after its handlers are
installed, and also offers explicit `fetchChanges` and `sendChanges` calls.
The latter remain available for storage transitions that need a completed transfer. The engine should own the transient
retry of that state-managed work; a new app retry loop must not replace its
scheduler.

The collection control record and the custom-zone lifecycle use direct
`CKDatabase` calls in `CloudKitCollectionControlTransport`:

- `fetchControl()` reads the record directly.
- `createZones()` and `deleteZones()` call `modifyRecordZones` directly.
- `saveControl()` calls `modifyRecords` directly with
  `ifServerRecordUnchanged` and reports a server-record conflict separately.

Before this change, all four passed through `retrying(_:)`. The helper retried
at most twice after the first attempt. It used `CloudKitRetryPolicy.delay`,
which reads `CKErrorRetryAfterKey` or uses an exponential one-second fallback.
On the last failed attempt it threw the error and lost the final
server-provided delay. The next call started its own attempt counter.

`CloudCollectionCoordinator.retrySynchronization()` re-enters this control
path after a user selects **Try Again**. Control reads also occur outside the
engine's retry ownership before automatic apply and before record work checks.
These facts made the control transport, rather than the normal record engine,
the narrow place to test the reported timing.

The change puts a shared `CloudKitOperationRetry` instance inside the control
transport. Its `run` operation retains the next permitted time across direct
control calls, including the retry-after value returned by a final failed
attempt. It makes up to three attempts in one call. For transient errors with
no server delay, it carries an exponential fallback across calls, capped at 64
seconds, and resets that fallback after success.

## Checks and remaining question

The new regression test uses a test clock to show the old sequence
`[0, 10, 20, 20]`: after three failures, the next call invoked its CloudKit
operation at once. The new sequence is `[0, 10, 20, 30]`, so that next call
waits through the final failure's 10-second delay.

The shared instance covers each direct control operation. A cooldown on only
`fetchControl()` would still let a zone or save request defeat the server's
throttle, so this shared scope is required. Automatic apply and record-work
checks use the same control transport, so they also pass through the gate.

The gate keeps its deadline for the app session only. It deliberately does not
write a new durable retry record, so an app relaunch does not preserve a known
server deadline. This keeps the change small; persisting that deadline remains
a separate choice if relaunch throttling becomes a measured problem.

The reported device behavior still needs a device reproduction. Retry diagnostics identify the control or clipboard operation, CloudKit error
code, selected delay, remaining wait, and next permitted wall-clock time. The
selected delay includes the longest nested server wait, or the fallback when
no server wait exists. These logs contain no user content or record IDs.

## Deep module

`CloudKitOperationRetry` sits inside the direct-control transport. Its
interface is one operation:

```swift
func run<Value: Sendable>(
    operationName: String = "direct CloudKit request",
    _ operation: @Sendable () async throws -> Value
) async throws -> Value
```

The module owns the session-wide next permitted time for direct control
requests, server-delay extraction, fallback timing for transient errors without
a server delay, three attempts per call, cancellation, and diagnostics. Its
internal seam accepts a clock and sleeper so tests can prove request order
without real waiting. The control transport and clipboard service each own an instance;
coordinators keep their present interface and do not learn delay, attempt
count, or error-code rules.

This module has depth because one small interface enforces Apple’s retry rule
across every direct control operation and every user retry. It improves
locality: all timing policy sits beside the direct CloudKit adapter instead of
spreading through settings, life-cycle callbacks, automatic-apply guards, and
sync loops. Do not add a general retry interface to `CKSyncEngine` record
work: that would duplicate an engine responsibility.

`run` orders concurrent callers and waits through its stored deadline. A
cancelled caller leaves the queue without discarding the deadline. This applies equally to automatic work
and **Try Again**: neither starts a direct request before the known deadline.

## Recommended test cases

- A final rate-limit response sets the shared deadline; a second `run` does
  not invoke its closure before the test clock reaches it.
- The larger of two known deadlines wins.
- `serviceUnavailable` uses its server delay; `zoneBusy` uses the explicit
  fallback policy when no retry-after value exists.
- Success clears the failure count but must not let an earlier active deadline
  be bypassed before it expires.
- Cancellation does not turn a record into a final data failure or clear a
  valid cooldown.
- A record-engine transient failure remains pending in `CKSyncEngine.State`;
  the new gate is not called for it.

The earlier `testCloudKitRetryPolicyHonorsServerRetryDelay` proved only the
per-error duration. It does not test a deadline shared by separate control
operations or separate **Try Again** actions.

## Related clipboard traffic

Clipboard history uses direct CloudKit requests too. Mac polls roughly every
15 seconds and also requests sync after local edits and app events. A fixed
poll interval cannot honor a longer server retry-after. Clipboard requests now
use the same retry module, with a deadline that survives each retry in the
session; stopping clipboard sync cancels a wait before later work can run.
Mac routes automatic saved-snips completion through its existing clipboard
request coalescer.

Zone operations collect every per-zone failure before they return an error,
so dictionary order cannot discard a longer retry delay. Deleting a zone that
is already missing still succeeds.

A partial error can carry a retry-after in one of its item errors. The retry
module retains the longest such wait even when it throws the partial failure
to its caller instead of repeating the whole request. When every item failure
is transient, the whole request can retry; mixed permanent and transient
failures return to the caller. Apple says to inspect
each item error. [partialFailure](https://developer.apple.com/documentation/cloudkit/ckerror/code/partialfailure), [partialErrorsByItemID](https://developer.apple.com/documentation/cloudkit/ckerror/partialerrorsbyitemid).

## Callback ordering and send accounting

Apple delivers delegate events serially and warns against awaiting engine
fetch or send calls from a delegate event. The record adapter must return
without waiting for a coordinator that may itself await an engine operation.
[CKSyncEngineDelegate](https://developer.apple.com/documentation/cloudkit/cksyncenginedelegate-1q7g8).

A state update supplies state to persist alongside app data. Apple does not
promise a separate checkpoint for each fetched batch. A queued state save must
therefore wait behind every earlier fetched batch until its records are durable.
[handleEvent](https://developer.apple.com/documentation/cloudkit/cksyncenginedelegate-1q7g8/handleevent%28_%3Asyncengine%3A%29).

The engine asks for more send batches until the delegate returns nil. Its batch
initializer says a nil record skips that change; it does not promise that a
custom filter will defer the record to another send. Send accounting must cover
the exact operations supplied to the engine, including edits queued during a
send. [nextRecordZoneChangeBatch](https://developer.apple.com/documentation/cloudkit/cksyncenginedelegate-1q7g8/nextrecordzonechangebatch%28_%3Asyncengine%3A%29),
[batch initializer](https://developer.apple.com/documentation/cloudkit/cksyncenginerecordzonechangebatch/initwithpendingchanges%3Arecordprovider%3A?language=objc).

Apple documents that adding pending record changes schedules a send when no
sync operation is scheduled. It separately documents deduplication of pending
changes; it does not exempt duplicate adds from that scheduling rule. After
committing the records that blocked a send, the app can add its remaining work
through this API. Removing and re-adding an unchanged pending ID has no
documented stronger scheduling guarantee.
[add(pendingRecordZoneChanges:)](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/state-swift.class/add%28pendingrecordzonechanges%3A%29).
