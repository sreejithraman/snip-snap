# 0028: Let CKSyncEngine schedule normal sync

Launch, foreground, and local edits request work from the existing
`CKSyncEngine`. They do not start a second explicit fetch-and-send sequence.
Try Again uses that same engine for one checked fetch, then sends each ready
follow-up batch until work settles, a batch reports an issue, or the run reaches
a fixed limit. It waits for that result. The sync session orders app requests and coalesces repeated
requests; the record module owns the first-fetch check and durable stage, apply,
and confirm work.

This narrows the choice in [ADR 0016](0016-use-swiftdata-with-cksyncengine.md):
explicit transfers remain available when a storage change or user retry needs a
completed fetch or send. Normal sync accepts the engine's schedule and retry
timing. Try Again does not bypass CloudKit retry delays. Direct control-record,
zone, and clipboard-history calls remain app-owned. Each request owner keeps its
retry deadline across calls within a session, using the same retry module.

CloudKit delegate events enter one ordered queue. The record module commits
fetched and sent batches before saving a later engine checkpoint. Delegate
callbacks return without waiting on that work, so an explicit transfer cannot
hold a coordinator lock while blocking the delegate it needs. Batch outcomes
and recovery updates stay in the same ordered operation. The earlier text-only
adapter also consumes checkpoints in that order before confirming a returned
record batch; checkpoint saves do not count as completed fetches.
An event arriving during a failed apply retains one follow-up notification.
A failed head alone does not trigger repeated attempts.

The lifecycle keeps the record driver alive when the app reads its adopted
library. Reading that library does not replace the sync owner. Each record owner
carries its source namespace and store ID through apply, send, checkpoint, and
result delivery. Replacing an owner resets its transport; queued old work cannot
act on the new library or report an error against it.

App assembly gives account notices, cache choices, attachments, and the sync
session the same live persistence owner and app operation gate. These services
do not reopen the activation manifest; recovery runs when that owner starts.
Sign-out isolation and Keep/Remove use local storage without a control request.
Same-account return still checks the remote collection before re-enabling sync.
Attachment work checks its source after remote lookup and holds active-store
admission until the file operation ends. All control requests reuse the
lifecycle's transport and its retry deadline.

Live record stores use the existing active-mutation admission while staging,
applying, saving checkpoints, and reconciling outbound work. This keeps a pointer
change from passing an active write and rejects later writes to a retired store.
When a live edit, import, or attachment operation holds admission, record work
waits in the persistence owner. Release grants queued reservations in order after
checking the source again. Cancellation removes a waiter, and replacement rejects
old-source waiters. The suspended automatic callback then continues through the
same event queue without a timer, another cloud event, or an app request.
Reading the active library can clear an abandoned write reservation, but cannot
release admission still held by a live operation. A staged reset blocks content
edits and imports under the same store lock as their commit. The reset commit
moves that evidence into durable recovery rows, so writes stay blocked if purge
delivery fails or the app restarts before retiring the store. A later sync request
uses that evidence to finish the purge.
Unreadable or inconsistent managed reset evidence also blocks content writes;
decoding failure cannot grant permission to edit a cache that may need discarding.
Outbound admission also stops when the transport observes a destructive reset;
it does not wait for local purge delivery to succeed. Durable reset evidence
keeps a restarted owner from sending the discarded cache.
Purge checks the exact source store and namespace inside its pointer change and
holds admission across suspension points. A purge from a replaced source has no
active-state or user-visible effect. The sync session, direct retry module, and
record coordinator share one cancellation-aware FIFO operation gate.

Stored state records whether the first fetch has committed. Older state without
that field starts a fresh engine without its old token, then fetches before
sending. This keeps local pending edits and accepted record shadows. A committed
batch or ordered checkpoint must explicitly record first-fetch completion before
new-store sends begin. Each send uses one fixed set of record IDs and bodies.
The app records the exact operations returned by CloudKit's batch helper, so a
provider that defers work creates no false send failures. Later edits and
unsupplied operations stay in the local queue until the prior send result has
committed; only then does the app add them to the engine's pending work.
Each scheduling request supplies the full current pending snapshot, including an
empty one. It replaces deferred work and removes obsolete engine requests, so an
undo or deletion withdraws work that has not been sent. Frozen, supplied operations
remain separate until their exact acknowledgement commits.
A successful save acknowledgement updates the accepted remote body and shadow
without rewriting local content. Edits and deletes made during that send remain
pending against the new shadow. Fetched records and actual server conflicts still
use the merge rules; acknowledging our own save does not create a conflict.

A failed record fetch retains its ID in durable recovery rows. Outbound planning
withholds matching saves and deletes, including queued work that used an older
shadow. Withholding survives later scheduling calls, so an older outbound
snapshot cannot add a failed ID back. Unrelated records can still sync. A
successful fetch clears only the IDs it actually read or found deleted, in the
same local commit as their new shadows. Confirming that commit releases only its
observed blocks; later queued failures still block their IDs.
Try Again keeps this evidence, drains pending events under the source checks,
then starts a fresh engine without its token when those IDs need a refetch. This
also retries records that have not changed on the server. Direct adapters may
return a batch without queuing it; draining earlier checkpoints must still commit
that returned batch exactly once.

An explicit transfer carries its current fetch issue through the control check
and send. It sends unrelated work when allowed, then reports that issue without
using old recovery notes as the result of the current transfer. An explicit
caller can cancel its wait for an active cycle without cancelling engine work
or releasing other callers from that cycle.

Scheduling work does not mean it reached iCloud. Settings clears a prior sync failure only after the record module reports settled work. If a retry adopts a new collection and finds a current issue, the app reloads that collection before it shows the issue. Account isolation, sync generation checks, and the discard rule in [ADR 0024](0024-discard-cache-after-icloud-data-reset.md) still govern every apply and send.

We chose two clear actions: schedule background work, or await a user retry. This
keeps ordering and recovery behind the sync module's existing interface without
making callers learn CloudKit's state or adding a general command framework.
