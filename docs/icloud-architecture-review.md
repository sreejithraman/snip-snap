# iCloud architecture review

Date: September 2, 2026

## Verdict

The main design is sound and fits Apple’s current CloudKit model. Snip Snap uses a local SwiftData store, turns SwiftData-managed CloudKit off, and gives one `CKSyncEngine` ownership of the active private-database collection. It saves engine state, keeps pending local work, fetches before a first send, isolates old account data, uses server record shadows for three-way merges, and keeps file payloads out of normal metadata fetches.

The foreground share fix is also sound. It stops an empty share-inbox pass from starting a second sync and from turning an unrelated iCloud failure into a share alert. When the import store adds a snip, it still asks for a send and keeps the local save when that send fails. This also holds if the store adds the snip but fails to clean up its inbox file. I would keep this control flow if I designed the feature today.

The review found one high issue and two medium issues. This change fixes the high issue and the user-facing alert issue. One medium retry-timing issue remains. It does not call for a new sync design.

## Findings

### Fixed: a canceled CloudKit item became a final failure

`CloudKitRecordTransport.failure(_:)` treated `CKError.operationCancelled` as `.rejected`. The sent-batch path keeps only `.retryable` records in its transport queue. The attachment path also treats `.rejected` as final. A normal cancellation could therefore leave valid local work in a needs-attention state instead of retrying it.

Apple’s CKSyncEngine sample lists `operationCancelled` with network, zone-busy, service, and authentication failures that the engine retries. Apple also says automatic sync reschedules recoverable failures. `CloudKitRecordTransport` now treats canceled CKSyncEngine record work as retryable, with a direct mapping test. The direct control-call policy still treats cancellation as final. [Apple CKSyncEngine sample](https://github.com/apple/sample-cloudkit-sync-engine/blob/main/SyncEngine/SyncedDatabase.swift#L256-L264), [`automaticallySync`](https://developer.apple.com/documentation/cloudkit/cksyncengineconfiguration/automaticallysync)

### Medium: manual retry paths do not honor CloudKit’s delay

`CloudKitRetryPolicy` marks rate limits and service failures as transient, but it drops `CKError.retryAfterSeconds`. `ICloudSyncModeCoordinator.syncActive()` can clear one retry marker and send again in the same run. Launch, foreground, account notifications, and user actions can also start a new direct control-record request with no shared next-attempt time.

Apple says to wait for `retryAfterSeconds` on `serviceUnavailable` and `requestRateLimited`. It also tells clients to use the supplied delay for `zoneBusy`, then increase the delay after repeat failures. CKSyncEngine can schedule its own retries, but Snip Snap’s direct control-record calls and explicit retry loop remain app-owned. Carry a retry deadline through those paths, or stop the current explicit run after a retryable result and let the engine or a later event resume it. [`retryAfterSeconds`](https://developer.apple.com/documentation/cloudkit/ckerror/retryafterseconds), [`zoneBusy`](https://developer.apple.com/documentation/cloudkit/ckerror/zonebusy), [`networkUnavailable`](https://developer.apple.com/documentation/cloudkit/ckerror/networkunavailable)

### Fixed: a saved offline share raised an informational alert

The first fix stopped the reported alert when no share was waiting. It still put “saved on this device” into `model.errorMessage` after the import store saved a new share locally but the immediate iCloud send failed. `IOSAppRootView` shows every such message as a modal alert.

That state needs no choice and no urgent action. Apple says not to show an alert just to give information or for a startup network problem. The coordinator no longer posts this modal message. The sync settings keep the failure state, while an import failure can still show an alert. [Apple alert guidance](https://developer.apple.com/design/human-interface-guidelines/alerts)

## Topic audit

### Account state and private-database identity: pass

- `CloudKitICloudAccountStateSource` covers all current `CKAccountStatus` cases. It treats an account-status error as unknown, not as a sign-out.
- It gets the current user record ID only after the status is available and stores its record name as the account lineage for this container.
- Sync checks that lineage before and after guarded control work. A sign-out or switch isolates the old cache. A restricted, temporary, or unknown state pauses work without deleting it.
- Both `CKAccountChanged` and `CKSyncEngine.Event.accountChange` lead back to an account check. Apple says the notification arrives on an arbitrary queue and clients must call `accountStatus()` after it. Apple also says an account change resets the engine’s pending state, so the app-owned ledger must retain the work. [`CKAccountChanged`](https://developer.apple.com/documentation/cloudkit/ckaccountchangednotification), [`CKSyncEngine.Event.AccountChange`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/accountchange), [`CKAccountStatus.temporarilyUnavailable`](https://developer.apple.com/documentation/cloudkit/ckaccountstatus/temporarilyunavailable)
- The private database choice is right for personal snips. It requires an iCloud account, keeps data private to that user by default, and charges storage to that user. [`privateCloudDatabase`](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)

### Life cycle, subscriptions, and change fetches: pass

- Launch and foreground both run a fetch. This is the right fallback because iOS may delay, merge, limit, or drop silent pushes.
- The record transport leaves CKSyncEngine automatic sync on after it installs its delegate handlers. It uses the engine’s state for pending changes and saves each state update either with the staged batch or through the state handler.
- CKSyncEngine finds or creates its database subscription and uses it to schedule fetches, so the app needs no separate CloudKit subscription code. The iOS target has the remote-notification background mode, and signed cloud builds require the push entitlement.
- The payload zone is not in `automaticallyFetchedZones`. Direct payload fetches use `desiredKeys`, then copy the `CKAsset` out of CloudKit’s short-lived staging area.

Apple says to create CKSyncEngine near launch, persist every state update, and add local pending changes to its state. It also says the engine owns its database subscription. [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5), [engine state](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/state-swift.class), [background update limits](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app), [`CKAsset`](https://developer.apple.com/documentation/cloudkit/ckasset)

### Local-first cache and offline writes: pass

- `SwiftDataSnipLibrary` uses `cloudKitDatabase: .none`, so the app, not SwiftData, owns remote sync.
- A local write commits before cloud work. The durable record and delete ledgers derive pending work after relaunch.
- A first send with no engine state performs a remote fetch first. This blocks stale local data from replacing newer remote state.
- The app does not clear cached data for network loss or a temporary account state.

Apple presents a local cache plus change-token sync as the normal offline model. CKSyncEngine keeps those tokens in its saved state. [Remote records](https://developer.apple.com/documentation/cloudkit/remote-records), [CKSyncEngine state](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/state-swift.class)

### Share extension handoff: pass

- The extension copies each item-provider file before the callback returns. Apple deletes that temporary source after the callback.
- The App Group is the right shared location. The extension writes a request into its own staging directory, flushes it, and publishes it with a same-volume rename to a `.ready` directory. The main app reads only ready directories.
- Each request has a UUID. The main store keeps seen request IDs. If the app stops after the SwiftData save but before inbox cleanup, the next import sees a duplicate and removes the ready directory without adding a second snip.
- The import summary separates new local imports, add failures, and cleanup failures. The app therefore sends a new record on the same resume even if cleanup fails. On the next pass, the durable request ID turns the replay into cleanup-only work, so the app does not send the record again.
- The actor covers work inside one process. Cross-process safety comes from separate request paths and atomic publication, not from the actor. This use matches Apple’s accepted flat-file atomic-save option for App Group data.

Apple requires synchronized App Group access and notes that an extension may end soon after it completes its request. Apple also states that `loadFileRepresentation` deletes its temporary file when the callback returns. [App Group access](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html), [Apple TN2408](https://developer.apple.com/library/archive/technotes/tn2408/), [`loadFileRepresentation`](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation%28fortypeidentifier%3Acompletionhandler%3A%29)

### Idempotency and conflicts: pass

- Share requests use a durable request ID. Cloud retries use stable record IDs.
- The app keeps the last accepted server record as a shadow. A conflict uses the current server record and a three-way field merge. Unknown fields survive because a retry starts from that server record.
- Deletes stay in a local ledger until CloudKit accepts them. An edit against a remote delete becomes a recovered snip with a new stable ID.
- The control record uses `ifServerRecordUnchanged`; concurrent collection resets adopt the accepted server generation.

Apple says `serverRecordChanged` provides ancestor, client, and server records and that the merged retry must start from the server record because it has the latest change tag. [`CKError`](https://developer.apple.com/documentation/cloudkit/ckerror)

### Limits, assets, privacy, and schema: pass

- `RecordZoneChangeBatch(pendingChanges:recordProvider:)` lets CKSyncEngine keep each send within its current record limit.
- Snip Snap’s 25 MiB per file and 100 MiB per snip caps are app limits, not claimed CloudKit limits. Quota failure has its own state.
- Attachment bytes use `CKAsset`. File names, types, sizes, hashes, and links sit in encrypted metadata fields. Payloads use an excluded zone and an on-demand direct fetch.
- The text schema marks user data as encrypted from its first form and leaves encrypted fields unindexed. It keeps only opaque routing and version data in ordinary fields.
- Production schema changes must remain additive and must ship before code that needs them.

Apple says CKAsset stores only bytes, uses a short-lived staging area after fetch, and encrypts the data by default. It also says encrypted fields cannot have indexes or change from plain fields after production use. [`CKAsset`](https://developer.apple.com/documentation/cloudkit/ckasset), [encrypting user data](https://developer.apple.com/documentation/cloudkit/encrypting-user-data), [text schema workflow](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow)

## Suggested order

1. Preserve and obey CloudKit retry deadlines in app-owned retry paths.
2. Keep the current foreground no-op guard and conditional post-import sync.

The review led to the cancellation retry fix and the simpler share-alert policy in this change.
