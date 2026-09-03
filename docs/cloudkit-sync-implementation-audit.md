# CloudKit sync implementation audit

Date: 2026-09-03

## Conclusion

Snip Snap uses the right base API and has strong local data safety in normal sync. It uses `CKSyncEngine`, custom private zones, durable local batches, saved system fields, fetch-before-send, and app-owned three-way merge. Those choices match Apple's guidance.

This upgrade fixes the main correctness and safety gaps found below. A real iCloud purge or encrypted-data reset now deletes the old synced store and pending work, then turns sync off. It cannot offer to upload that cache again. An account change now swaps the library shown on screen as soon as isolation commits.

The engine now fetches before the first send, restores its record provider from the durable queue, and recovers from bad saved engine state with a fresh fetch. A bad attachment or conflict no longer stops unrelated records. Direct control calls honor CloudKit's retry delay, and the user sees a short message for the state rather than an error domain or code.

## Upgrade status

| Finding | Status after this upgrade |
| --- | --- |
| Purge or encrypted-data reset could upload old data again | Fixed. Both events delete the old store and pending work. Sync stays off until the user turns it on again. |
| Prior-account data could stay on screen | Fixed. The app loads the new active library at once. |
| Automatic and manual work could share event buffers | Guarded. Manual work will not start during an automatic fetch or send. A live engine timing test remains. |
| Restored engine had no record bodies for queued IDs | Fixed. Startup hydrates the provider from the durable outbound queue before automatic send. |
| Bad engine state caused a repeat failure | Fixed. The app clears only the engine state, starts fresh, and fetches before send. |
| One bad item stopped all outbound work | Mostly fixed. Bad attachments and conflicts now stay isolated. A bad saved record shadow triggers a safe full fetch; finer per-record repair can still improve this. |
| Direct control calls ignored server retry timing | Fixed for each call. They honor `retryAfterSeconds` and use a short bounded fallback. A retry that must survive app exit still waits for the next launch, foreground event, or local change. |
| Missing active zone policy was too broad | Open. The app still blocks the namespace rather than guessing whether it is safe to rebuild the zone. |
| Sync logs lacked useful error context | Improved. Private system logs now keep the operation, CloudKit code, and retry delay. A user-exported support bundle is still open. |
| Live engine and two-device tests were missing | Partly fixed with new fake-engine, restart, purge, account swap, retry, and iOS UI tests. A signed CloudKit development-container run still remains. |

## What is sound

- The app uses one retained `CKSyncEngine` for active record sync and lets it create its own database subscription. `CloudKitRecordTransport.start` leaves automatic sync on whenever an automatic batch handler is present (`CloudKitRecordTransport.swift:42-54`). Apple says automatic sync is the normal path and the engine creates a database subscription when needed. [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
- It uses custom private zones and queues zone saves before record changes (`CloudKitRecordTransport.swift:523-547`). This matches Apple's custom-zone pattern. [CKRecordZone](https://developer.apple.com/documentation/cloudkit/ckrecordzone)
- It saves the engine state with the fetched or sent app changes through a staged local commit (`CloudFullSyncCoordinator.commit`, `CloudFullSyncPersistence.stage`, and `CloudFullBatchPlanner.plan`; `CloudFullSyncPersistence.swift:155-163, 275-297`, `CloudFullBatchPlanner.swift:146-165`). Apple requires state to be stored beside the app data it describes. [CKSyncEngine.StateUpdate](https://developer.apple.com/documentation/cloudkit/cksyncenginestateupdateevent)
- It keeps full `CKRecord` shadows, including system fields and change tags, and reuses the server record for later saves (`CloudRecordModel.swift:43-108`, `CloudKitRecordMapper.swift:13-44`). This is the correct base for conflict-safe saves. [CKRecord](https://developer.apple.com/documentation/cloudkit/ckrecord)
- It handles `serverRecordChanged` as an app conflict and uses the returned server record as the new accepted base (`CloudKitRecordTransport.swift:451-460`, `CloudFullBatchPlanner.swift:195-224, 315-338`). Apple leaves this conflict to the app. [CKError.serverRecordChanged](https://developer.apple.com/documentation/cloudkit/ckerror/serverrecordchanged)
- It applies record deletions and stores pending local deletes (`CloudFullBatchPlanner.swift:86-116`, `CloudFullSyncPersistence+OutboundSend.swift:69-96`).
- It copies downloaded `CKAsset` files out of CloudKit's temporary location at once, then checks size and hash before install (`CloudKitRecordTransport.swift:230-252`, `CloudAssetFileCopy.swift:4-35`, `CloudAttachmentTransferCoordinator.swift:173-201`). That matches the lifetime rules for `CKAsset`. [CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset)
- It keeps old account data in an isolated, read-only store and swaps the active pointer to a new local store before later user action (`SwiftDataSyncModePersistence.swift:305-363`). This is safer than merging two accounts.
- Schema writes preserve unknown fields by editing a restored server record instead of making a fresh record for updates (`CloudKitRecordMapper.swift:13-44`). This helps old and new app versions coexist. [Designing and creating a CloudKit database](https://developer.apple.com/documentation/cloudkit/designing-and-creating-a-cloudkit-database)

## Gaps found in the original implementation

### P0 — Purged or reset iCloud data can be uploaded again

Evidence:

- The transport correctly distinguishes `.purged` and `.encryptedDataReset` (`CloudKitRecordTransport.swift:566-573`).
- The persistence layer then combines both into one destructive-reset path (`CloudFullBatchNormalization.swift:146-163, 190-252`).
- The collection layer calls both states `encryptedDataReset`, offers `restoreFromThisDevice`, and sends the recovery store when that option is chosen (`CloudCollectionCoordinator.swift:536-587, 667-701`; `SyncedContentSettingsModel.swift:127-131`).
- A missing control record is also treated as this recoverable state (`CloudCollectionCoordinator.swift:417-425`; test `CloudCollectionCoordinatorTests.swift:1725-1755`).

Why this is wrong:

The current SDK header says that for both a Settings purge and an encrypted-data reset, the app must delete locally cached data and not resend it. See `CKSyncEngineEvent.h:416-431` in the iOS 26.5 SDK and Apple's [zone deletion reason](https://developer.apple.com/documentation/cloudkit/cksyncenginezonedeletionreason) docs.

Fix:

Keep `.purged` and `.encryptedDataReset` distinct through the whole domain model. For a real CKSyncEngine purge or reset event, retire the synced cache, clear that namespace's pending outbound work, and start local-only or empty sync. Do not offer “restore from this device” for that data. If the product needs a separate backup restore feature, make it an explicit import from a user-owned backup, not a continuation of the deleted sync cache.

### P1 — Previous-account data can remain on screen after sign-out or account switch

Evidence:

- Account mismatch correctly isolates the old store and swaps the persisted active store (`SnipSnapCloudLifecycle.swift:470-493`, `SwiftDataSyncModePersistence.swift:305-363`).
- The sync call then throws. The UI records the error but does not replace its in-memory library (`IOSAppSession.swift:206-243`; `SnipSnapApp.swift:259-292`).
- The app replaces the library only after the user resolves the account notice (`IOSAppSession.swift:139-146`; `SnipSnapApp.swift:314-320`).

Why this matters:

Apple says sign-out and account switch require removal of the prior account's local data. The disk store becomes inactive, but the old account's content may remain visible in the already loaded model until another reload or user choice. See [CKSyncEngine account changes](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/accountchange) and `CKSyncEngineEvent.h:168-203`.

Fix:

Return a typed “active library changed due to account isolation” result as soon as the pointer swap commits. Reload the active library before showing the notice. Keep the isolated store available only to the later keep-or-remove action, never as the visible active model.

### P1 — Automatic and manual sync share unscoped event buffers

Evidence:

- All fetch events use the same `fetchedItems`, `fetchedDatabaseEvents`, and `fetchedZoneEvents` arrays. All send events use the same matching send arrays (`CloudKitRecordTransport.swift:11-19`).
- Explicit fetch resets those arrays and waits on `engine.fetchChanges` (`CloudKitRecordTransport.swift:86-121`). Explicit send does the same for the send arrays (`CloudKitRecordTransport.swift:123-158`).
- `isPerformingSyncOperation` guards only explicit calls. Automatic cycles set separate flags but do not block explicit fetch or send (`CloudKitRecordTransport.swift:22, 29-30, 376-390`).

Risk:

If automatic work has begun when launch, foreground, enable, or another explicit call starts, events can enter the same buffers. The code assumes the explicit completion cleanly owns all events accumulated since the reset, but it does not tie events to the event context or one operation token. This can make the wrong local batch own an engine state update or fetched changes.

Apple says delegate events arrive serially, but automatic and immediate operations can both exist. The app still needs to assign each event to the correct local transaction. See the delegate contract in [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5) and `CKSyncEngine.h:198-231`.

Fix:

Use one sync lane above the engine. Do not begin an immediate fetch or send while an automatic cycle is active. Model an operation context from `willFetch`/`didFetch` and `willSend`/`didSend`, and keep one batch builder per context. Add an overlap test that pauses an automatic event between `willFetch` and `didFetch`, then requests manual sync.

### P1 — The record provider depends on an in-memory copy of the durable queue

Evidence:

- `nextRecordZoneChangeBatch` reads pending IDs from the engine, but record bodies come only from the actor's `outbound` dictionary (`CloudKitRecordTransport.swift:399-427, 436-443`).
- `outbound` and `currentOutboundBatch` are not restored in `start`; only CKSyncEngine's serialized state is restored (`CloudKitRecordTransport.swift:42-54`).
- The durable store can rebuild changes later through `pendingChanges`, but only after higher-level setup calls `schedule` again (`CloudFullSyncPersistence+OutboundSend.swift:5-168`, `CloudFullSyncCoordinator.swift:56-73`).

Risk:

After process death, the restored engine can contain pending record IDs while the provider has no record bodies. Automatic sync starts as soon as the engine starts. The batch initializer skips saves whose provider returns `nil`; this can delay work until the app rebuilds and re-adds it, and it makes the CKSyncEngine queue and app queue disagree. See `CKSyncEngineRecordZoneChangeBatch.h:22-33` and [pending record zone changes](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/state-swift.class/pendingrecordzonechanges).

Fix:

Make the delegate's provider read records from a durable, namespace-bound pending-change store, or hydrate the provider before enabling automatic sync. A simpler design is to use `hasPendingUntrackedChanges` and keep the app's durable queue as the only source of truth. In either design, test termination after the engine queues a save but before a send event returns.

### P1 — Corrupt or incompatible engine state has no recovery path

Evidence:

- State decode failure throws `.invalidEngineState`; namespace mismatch throws `.stateNamespaceMismatch` (`CloudKitRecordTransport.swift:68-83`).
- Coordinators set `started` only after `start` succeeds and pass the same state again next time (`CloudFullSyncPersistence.swift:56-65, 102-137`).
- The UI now hides the raw code, but no code quarantines the bad state, starts a fresh engine state, and performs a full fetch.

Risk:

One bad serialized state can make every later sync attempt fail in the same place. This is a likely class of cause for persistent app-data errors even when the connection is good.

Fix:

Quarantine the bad serialization with its namespace and app version, clear only the engine state, start CKSyncEngine with `nil`, and fetch before any send. Keep accepted shadows and pending local edits. Add a test for corrupt bytes and a valid state from the wrong namespace.

### P1 — One bad record or attachment can stop unrelated records from syncing

This is confirmed in three paths:

- `pendingChanges` checks every local attachment before it builds any text, list, or attachment operations. One missing, changed, or oversized attachment throws and returns no batch at all (`CloudFullSyncPersistence+OutboundSend.swift:23-31`). Thus a bad attachment stops unrelated text and list changes.
- A terminal fetch recovery, conflict, or quarantine sets the collection-wide `needsAttention` flag (`CloudFullSyncPersistence+ModeAdapter.swift:124-138`). `syncActive` then refuses to enter `sendPending`, even though `pendingChanges` already skips only the conflicted entity (`CloudSyncModeCoordinator.swift:346-360`; `CloudFullSyncPersistence+OutboundSend.swift:37-46, 98-99`). Thus one remote conflict or legacy record can stop all unrelated outbound work.
- A corrupt accepted shadow is decoded while building the whole outbound batch. A decode failure throws before any valid operations can send (`CloudFullSyncPersistence+OutboundSend.swift:93-135`; `CloudRecordModel.swift:43-108`). The transport can label the error, but no per-record quarantine repairs the local accepted row.

Why this matters:

CloudKit reports success and failure per record. The local design should preserve that isolation. A single bad record may need review, but it should not leave every other snip waiting.

Fix:

Build independent record candidates. Quarantine only the bad shadow or attachment, keep its local value, and send the valid candidates. Split collection health into “some items need review” and “sending is unsafe.” Block the whole namespace only for account, generation, purge, reset, or state-transaction failures.

### P2 — Direct control-record work has no timed retry plan

Evidence:

- Control zone and control record work uses direct `CKDatabase` calls (`CloudKitCollectionControlTransport.swift:81-178`), so CKSyncEngine does not retry it.
- Transient setup failures return `.settingUp` and leave a durable marker (`SnipSnapCloudLifecycle.swift:204-217, 429-435`).
- Normal retries occur on launch, foreground, account notification, or later local activity. There is no timer or stored `retryAfterSeconds` deadline.

Risk:

A short rate limit, service fault, or weak connection can leave setup pending after the network is healthy. The user may need to background and reopen the app. Direct CloudKit operations should respect `CKErrorRetryAfterKey`; CKSyncEngine does this only for work it owns. [CKError](https://developer.apple.com/documentation/cloudkit/ckerror)

Fix:

For direct control calls, store a bounded retry deadline from `retryAfterSeconds`, add jittered backoff when the server provides no delay, and cancel or pause it on account or mode changes. Keep one retry task per durable setup or cleanup operation.

### P2 — Active-zone loss becomes a blocked product reset instead of standard zone repair

Evidence:

- A missing active metadata zone moves the namespace to `.blocked` (`CloudFullBatchNormalization.swift:199-225`).
- Apple’s normal custom-zone recovery pattern is to queue zone creation, then reschedule records after `zoneNotFound`.

This may be a deliberate anti-resurrection policy because Snip Snap also has a generation control record. Even so, it currently groups accidental zone loss, user deletion, purge, and encrypted reset too closely.

Fix:

Define separate policy for: a zone never created, a zone lost while the same valid control generation remains, a Settings purge, and encrypted-data reset. Repair only the safe cases. Keep purge and reset destructive. Apple's base pattern is covered by [CKRecordZone](https://developer.apple.com/documentation/cloudkit/ckrecordzone) and [WWDC23: Sync to iCloud with CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/).

### P2 — Sync diagnostics are too thin to explain device-only failures

Evidence:

- Transport failures collapse into five broad values and discard the record type, record ID, zone ID, CKError code, operation kind, account-change type, and retry deadline (`CloudKitRecordTransport.swift:550-558`). By the time the typed UI mapper runs, the original `CKError`, including `retryAfterSeconds`, may already be gone.
- Top-level fetch and send errors become anonymous database failures (`CloudKitRecordTransport.swift:102-108, 138-145`).
- The account event ignores its `changeType`, `previousUser`, and `currentUser` values (`CloudKitRecordTransport.swift:392-394`).

Risk:

The app can show safe copy, but support cannot tell whether a persistent failure came from an old shadow, wrong type, corrupt engine state, server schema, account switch, or zone policy. This is why errors 2 and 7 cannot yet be traced to one record or transition.

Fix:

Add privacy-safe structured logs for event kind, namespace generation, hashed record ID, record type, zone role, CKError code, retry delay, and transition phase. Never log snip text, file names, account record names, or raw encrypted values. Add a small exportable sync diagnosis bundle with bounded history.

### P3 — Test coverage proves the reducers, not the live engine timing

The unit suite has broad fake-server coverage for conflict, deletion, crash replay, attachment order, account isolation, and reset blocking. The main missing tests are:

1. Automatic/manual overlap with real delegate event order.
2. Process death with CKSyncEngine pending IDs but no in-memory `outbound` map.
3. A purge that proves no path can later upload the old cache.
4. An account switch that proves old records leave the screen before the notice appears.
5. Direct-operation rate limiting using `retryAfterSeconds`.
6. Corrupt or incompatible engine-state recovery.
7. Two-device tests against a CloudKit development container for concurrent edit, delete/edit, offline attachment, and old/new schema mixes.

No real-CloudKit or physical-device proof was produced for this audit. The conclusions above come from code, tests, Apple's current docs, and the installed iOS 26.5 SDK headers. Findings about direct control retries, purge/reset policy, collection-wide blocking, corrupt state, and the in-memory provider follow directly from the code. The exact timing of the automatic/manual overlap is a risk that still needs a live-engine test.

Apple recommends multi-device conflict tests and event, record, zone, and time logging in [WWDC23: Sync to iCloud with CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/).

## Recommended order

1. Split purge, encrypted reset, missing control, and missing zone into distinct states. Remove all resend paths for real purge and reset events.
2. Reload the active library at the account-isolation pointer swap.
3. Make the CKSyncEngine delegate use one durable queue and one event context at a time.
4. Add state-corruption recovery and privacy-safe logs.
5. Add durable retry scheduling for direct control work.
6. Run the missing timing and CloudKit development-container tests before release.

## Primary sources

- [Apple CKSyncEngine documentation](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
- [WWDC23: Sync to iCloud with CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/)
- [CKSyncEngine state update](https://developer.apple.com/documentation/cloudkit/cksyncenginestateupdateevent)
- [CKSyncEngine account change](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/accountchange)
- [CKSyncEngine zone deletion reason](https://developer.apple.com/documentation/cloudkit/cksyncenginezonedeletionreason)
- [CKRecord](https://developer.apple.com/documentation/cloudkit/ckrecord)
- [CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset)
- [CKError](https://developer.apple.com/documentation/cloudkit/ckerror)
- Xcode 26.5 iOS SDK headers: `CKSyncEngine.h`, `CKSyncEngineConfiguration.h`, `CKSyncEngineState.h`, `CKSyncEngineEvent.h`, and `CKSyncEngineRecordZoneChangeBatch.h`
