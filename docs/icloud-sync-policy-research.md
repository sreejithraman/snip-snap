# Optional iCloud sync policy research

Date: 2026-08-28

This report checks the open sync choices against Apple documentation, Apple sample code, and the current CloudKit framework interface. It separates Apple guarantees from design inferences and product choices.

## Short answer

The SwiftData plus `CKSyncEngine` plan still fits Snip Snap. SwiftData gives both the app and Share extension one local store, while `CKSyncEngine` gives the main app control over account changes, first-time merges, conflicts, and sync timing. Apple points apps with their own local persistence toward `CKSyncEngine`; SwiftData History can feed local inserts, updates, and deletes to that adapter.

The research found two issues that the current notes and ADRs now address:

1. A `CKAsset` field on a record fetched by `CKSyncEngine` is not a documented metadata-first download. `CKSyncEngine.FetchChangesOptions` can scope and rank zones, but it has no `desiredKeys` setting. A normal record fetch returns its asset data. True on-demand files need a separate payload record and a fetch path that can ask for selected keys.
2. Permanent app-owned tombstone records are not required by CloudKit. Snip Snap can prevent deleted records from returning by treating the remote collection as authoritative during bootstrap, keeping the last server record metadata, and handling `unknownItem` without recreating the deleted record. A recovered edit should get a new record ID.

The proposed 25 MiB per attachment and 100 MiB per snip limits are test candidates, not Apple limits or public Snip Snap limits. Current tests use small fixtures and do not support a byte-count promise. Public sync must stay blocked until one numeric per-attachment limit passes the Mac and Simulator matrix plus the final physical-iPhone check.

## 1. Attachment fetches and cache behavior

### What Apple guarantees

- CloudKit stores a `CKAsset` separately from the record that owns it, but fetching the record also fetches the asset. CloudKit places the downloaded file in a staging area and may clear it to reclaim space. An app that needs to retain the file must move or copy it into its own container. [`CKAsset`](https://developer.apple.com/documentation/cloudkit/ckasset)
- Direct record operations can omit fields through `desiredKeys`. Apple names this as the way to avoid fetching an asset field. A later `records(for:desiredKeys:)` call can fetch a known record and ask only for the asset field. [`CKAsset`](https://developer.apple.com/documentation/cloudkit/ckasset), [`records(for:desiredKeys:)`](https://developer.apple.com/documentation/cloudkit/ckdatabase/records%28for%3Adesiredkeys%3A%29)
- `CKSyncEngine.FetchChangesOptions` exposes zone scope, zone priority, and an operation group. It does not expose `desiredKeys`. [`CKSyncEngine.FetchChangesOptions`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/fetchchangesoptions)
- A Share extension and its app can use an App Group container, but they run as separate processes and must coordinate writes to shared data. SwiftData can place a store in a named group container. [Sharing data with an app extension](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html), [`ModelConfiguration.GroupContainer`](https://developer.apple.com/documentation/swiftdata/modelconfiguration/groupcontainer-swift.struct)

### Inference

Putting file details and a `CKAsset` on one record that `CKSyncEngine` fetches will download the file during sync. The current `CKSyncEngine` API has no field-level fetch filter, so the notes cannot promise metadata-first sync for that record shape.

True on-demand downloads can keep `CKSyncEngine` if the schema separates the data:

- Sync an `AttachmentMetadata` record through the normal metadata zone. It holds the attachment ID, snip ID, filename, content type, byte count, hash, and payload record name.
- Store the `CKAsset` on an immutable `AttachmentPayload` record in a separate payload zone.
- Use the one production `CKSyncEngine` to send payload records, but exclude the payload zone from automatic fetches. Apple warns against creating more than one production sync engine for the same database. [`CKSyncEngine.Configuration.database`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/database)
- When the user previews, opens, copies, or exports a file, fetch its payload record by ID with a direct CloudKit record request.
- Copy the staged file into an app-owned App Group cache and remove old files under a local cache policy.

This split loses cross-zone atomic writes and cross-zone `CKRecord.Reference` links. CloudKit references only work inside one zone. The adapter therefore needs an upload-first flow: save the immutable payload, then publish its metadata. It also needs cleanup for payload records that never gain metadata. [`CKRecordZone`](https://developer.apple.com/documentation/cloudkit/ckrecordzone), [`CKRecord`](https://developer.apple.com/documentation/cloudkit/ckrecord)

### Product choice

A bounded least-recently-used cache, `Clear Downloaded Files`, and no offline pinning in the first release are sound choices. Apple does not set the cache size or removal rule. Snip Snap should show whether a file is local, downloading, or needs attention.

### Recommendation for Q19

Accept metadata-first and on-demand downloads. Do not put the asset field on a record fetched by the normal `CKSyncEngine` metadata flow. Use a separate payload zone, prove on Mac and Simulator that excluded payload-zone records do not transfer during normal sync, and repeat that path during the final physical-iPhone check.

## 2. Asset, request, and quota limits

### What Apple currently documents

- A CloudKit record can hold up to 1 MB excluding asset fields. [`CKRecord`](https://developer.apple.com/documentation/cloudkit/ckrecord)
- Apple gives general request guidelines of 400 records or shares per operation and 2 MB per request excluding assets. It warns that the server may change those limits and tells apps to split a request after `limitExceeded`. [`CKError.Code.limitExceeded`](https://developer.apple.com/documentation/cloudkit/ckerror/limitexceeded)
- `CKSyncEngine` uses a lower, documented batch cap of 250 record saves and deletes combined. Its batch builder stops at that cap. [`CKSyncEngine`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
- Apple also documents 256 fields per record type and 1,000 zones per container. [TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)
- Private database data counts against the person's iCloud storage. A private save can fail with `quotaExceeded` when that storage is full. [`CKContainer`](https://developer.apple.com/documentation/cloudkit/ckcontainer), [`CKError.Code.quotaExceeded`](https://developer.apple.com/documentation/cloudkit/ckerror/quotaexceeded)
- Request throttles are dynamic. `CKSyncEngine` handles CloudKit throttles and retries after the server's delay. [TN3162](https://developer.apple.com/documentation/technotes/tn3162-understanding-cloudkit-throttles)
- Apple's current native `CKAsset` documentation does not state a numeric maximum file size. The archived CloudKit Web Services reference lists 50 MB for an Asset field, but that old table describes the web service and is not a current native-framework guarantee. [Archived CloudKit Web Services data limits](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html)

### Inference

There is no primary-source basis for calling 25 MiB per attachment or 100 MiB per snip a CloudKit requirement. Keeping a first-release attachment below the archived web-service figure gives some margin, but it does not prove that every native upload at that size will work. Network loss, low storage, quota exhaustion, and server throttling still need clear recovery.

The per-snip total does not protect a single CloudKit request if payloads travel as separate records. It is mainly a product rule for upload time, device cache use, and iCloud storage use.

### Product choice

The project has not set a public numeric limit. Local-only mode need not have a Snip Snap size cap. Once tests support a synced attachment limit, existing files above it should stay local and block the mode change with a list of the files that need action.

### Recommendation for Q20

Do not record the numbers as settled yet. Use 25 MiB and 100 MiB as test candidates. Before release, test uploads, fresh-device downloads, interrupted transfers, low disk space, and a full iCloud account on supported Mac, iPhone, and iPad systems. Then publish the limits as Snip Snap limits, not CloudKit limits.

## 3. First-time enablement, account status, and network access

### What Apple guarantees

- Apple says to call `accountStatus()` before using the private database. The possible states include available, no account, restricted, temporarily unavailable, and unable to determine. [`accountStatus()`](https://developer.apple.com/documentation/cloudkit/ckcontainer/accountstatus%28completionhandler%3A%29), [`CKAccountStatus`](https://developer.apple.com/documentation/cloudkit/ckaccountstatus)
- A temporarily unavailable account is not a reason to delete cached data or queue more CloudKit work. The app should wait for an account-change notice and check again. [`CKAccountStatus.temporarilyUnavailable`](https://developer.apple.com/documentation/cloudkit/ckaccountstatus/temporarilyunavailable)
- `CKSyncEngine` can exist without an account or network. It stays dormant until conditions allow sync. Manual `fetchChanges()` waits until the delegate processes the related fetch events and reports failures such as no network or no account. [`CKSyncEngine`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5), [`fetchChanges(_:)`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/fetchchanges%28_%3A%29)
- An app can disable `automaticallySync` when it needs controlled manual fetches and sends. [`CKSyncEngine.Configuration.automaticallySync`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/automaticallysync)
- On an account change, `CKSyncEngine` resets its state, including pending record and zone changes. The app must update or isolate its local data. [`CKSyncEngine.Event.AccountChange`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/accountchange)

### Inference

CloudKit does not require a network connection merely to let a user select an iCloud preference. Snip Snap does need a successful remote fetch before it can safely finish its first merge and send local records. Otherwise it may upload before seeing records already stored for that account.

The safe activation flow is:

1. Keep the local-only store active.
2. Confirm that the iCloud account is available.
3. Create a separate cloud cache and a new sync engine with no saved state and automatic sync off.
4. Run an explicit fetch and apply all remote records.
5. Merge the local-only records into that fetched cache.
6. Queue and send the merge results.
7. Switch the active store only after the local merge is durable. Normal automatic sync can then start.

The app should save its own unsynced-work ledger in SwiftData. It must not rely only on the engine's pending list because account changes clear that list.

### Product choice

The toggle may fail immediately while offline, or it may enter a `Setting Up` state and finish when the network returns. The second option is friendlier but adds another durable mode-change state.

### Recommendation for Q21

Require an available account and a successful fetch before iCloud mode becomes active. Do not require the user to stay on the settings screen or make the preference switch itself fail only because the network is down. If the team wants less state-machine work in v1, it is acceptable to require a live network and finish setup in one flow.

## 4. Deletes, stale devices, and tombstones

### What Apple guarantees

- Fetched record-zone changes contain both modifications and deletions. Apple tells the app to persist modifications and remove local data for deletions. [`CKSyncEngine.Event.FetchedRecordZoneChanges`](https://developer.apple.com/documentation/cloudkit/cksyncenginefetchedrecordzonechangesevent), [WWDC23: Sync to iCloud with CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/)
- Apple uses opaque change tokens for creations, edits, and deletions. In the lower-level API, an expired token requires clearing the local cache and starting a full fetch with a nil token. [`CKServerChangeToken`](https://developer.apple.com/documentation/cloudkit/ckserverchangetoken), [`fetchDatabaseChangesCompletionBlock`](https://developer.apple.com/documentation/cloudkit/ckfetchdatabasechangesoperation/fetchdatabasechangescompletionblock)
- `CKSyncEngine` owns its token state and gives the app an opaque serialization to save beside local data. Apple says to persist each state update with the fetched changes that came before it. [`CKSyncEngine.Event.StateUpdate`](https://developer.apple.com/documentation/cloudkit/cksyncenginestateupdateevent)
- Apple's `CKSyncEngine` sample removes a local object when it receives a server deletion. It does not create a permanent server tombstone. When a stale save gets `unknownItem`, the sample says deleting the local object or uploading it again is an app choice. [Apple CKSyncEngine sample](https://github.com/apple/sample-cloudkit-sync-engine/blob/main/SyncEngine/SyncedDatabase.swift)
- SwiftData History has local deletion tombstones for selected attributes through `preserveValueOnDeletion`. The app can retain a stable CloudKit ID long enough to send a delete, then remove old history after its consumer advances. [SwiftData History](https://developer.apple.com/documentation/SwiftData/Fetching-and-filtering-time-based-model-changes)

### Inference

Permanent CloudKit tombstone records are one way to stop resurrection, but they are not the only way. They retain records forever, grow with every deletion, and turn delete into a special kind of update. They also make `Delete all iCloud data` and privacy wording harder to explain.

Snip Snap can meet its chosen delete-versus-offline-edit rule without permanent server tombstones if it enforces all of these rules:

- Save the last known server system fields for every synced record. Do not rebuild a stale record as a fresh `CKRecord` with the same ID.
- Do not send local records during a new bootstrap or state reset until the app fetches and reconciles the remote snapshot.
- Keep a local deletion change only until CloudKit acknowledges it.
- On a remote deletion, delete the original identity locally. If that identity has an unsent local edit, copy the edit to a new recovered snip ID in Inbox.
- On `unknownItem` while sending a stale edit, do not recreate the old record ID. Create a recovered snip with a new ID, then sync that new record.
- When the app loses or must restart sync state, rebuild the cloud cache from the current remote set instead of treating an old local cache as the server snapshot.

This makes the outcome independent of whether fetch or send happens first. The original stays deleted, while edited text survives under a new identity.

### Product choice

Finite-lived server tombstones may still help future non-CloudKit clients or audit features, but Snip Snap has no such requirement now. If the project later adds them, it needs a stated retention time and a cleanup rule.

### Recommendation for Q22

Reject permanent app-owned CloudKit tombstones for v1. Use CloudKit deletions, a durable local outbound-delete ledger, SwiftData History tombstones for stable IDs, strict bootstrap reconciliation, and an `unknownItem` rule that creates a recovered record with a new ID.

## 5. Equal list names from separate devices

### What Apple guarantees

- CloudKit makes record IDs unique within a zone. It does not make an arbitrary string field unique. [`CKRecord.ID`](https://developer.apple.com/documentation/cloudkit/ckrecord/id)
- The CloudKit schema language offers queryable, sortable, and searchable field indexes, but no unique field option. [CloudKit Schema Language](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow)
- SwiftData can enforce a unique value inside one local store. Managed SwiftData-to-CloudKit sync cannot enforce that property across concurrent devices. [SwiftData iCloud sync](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
- A `serverRecordChanged` conflict concerns two saves to the same record identity. Two list records with different IDs and equal names are not a CloudKit record conflict. [`CKRecord.recordID`](https://developer.apple.com/documentation/cloudkit/ckrecord/recordid)

### Inference

Snip Snap must repair duplicate display names in its merge layer. Calling one record "later" is not safe because device clocks and delivery order can differ. The rule must give every device the same answer from the same record set.

A convergent rule can normalize names with the same logic used for local validation, group equal names, sort the group by stable record ID, keep the first name unchanged, and assign `Name (2)`, `Name (3)`, and so on to the rest. The adapter should sync those repairs. A notice should name the lists it changed.

### Product choice

The project could allow duplicate display names instead, but that would change current Mac behavior. It could also derive record IDs from names, but then rename becomes an identity change and unrelated lists can collide. Stable UUID identities plus a deterministic repair fit the current model better.

### Recommendation for Q23

Keep both lists and use deterministic numbered suffixes. Replace "rename the later one" with a stable-ID tie-break so every device converges without trusting clocks.

## 6. Technology choice review

### What Apple recommends

Apple describes three levels:

- Use `NSPersistentCloudKitContainer` when the app wants a managed local replica and does not need fine control over sync.
- Use `CKSyncEngine` when the app brings its own local persistence and wants the system to schedule CloudKit work while the app owns record mapping and conflict rules.
- Use raw `CKDatabase` and `CKOperation` when the app needs full control and accepts responsibility for tokens, subscriptions, scheduling, account changes, and retries.

[Choosing a CloudKit approach](https://developer.apple.com/documentation/cloudkit/deciding-whether-cloudkit-is-right-for-your-app)

SwiftData History records ordered local transactions, can retain stable IDs for deleted objects, and supports remote-server sync and changes from app extensions. [SwiftData History](https://developer.apple.com/documentation/SwiftData/Fetching-and-filtering-time-based-model-changes), [WWDC24: Track model changes with SwiftData history](https://developer.apple.com/videos/play/wwdc2024/10075/)

### Inference

Optional sync alone does not force a custom adapter. Snip Snap's full set of rules does:

- It has separate local-only and cloud cache files.
- It needs a controlled fetch-before-merge transition.
- It isolates data when the Apple Account changes.
- It creates recovered records for chosen conflict cases.
- It needs a local Share extension write to count as success without waiting for iCloud.
- It wants a file cache that the app can clear.

Managed SwiftData CloudKit sync hides too much of those transitions. Raw CloudKit for every operation would duplicate work that `CKSyncEngine` already handles. SwiftData for local state plus one main-app `CKSyncEngine` remains the best fit.

The Share extension should write the matching App Group SwiftData store and durable attachment staging. When it cannot confirm the current schema, it should write an atomic pending import instead. The main app should read SwiftData History, accept pending imports after migration, and own `CKSyncEngine`. This keeps network work out of the short extension life cycle and leaves one sync owner.

### Correction applied to ADR 0016

The main choice in ADR 0016 stands. A direct `CKAsset` field on a record handled by the normal `CKSyncEngine` fetch does not provide documented on-demand bytes. The design review considered two choices:

1. accept eager attachment downloads, or
2. specify metadata records in the normal sync zone plus immutable payload records in an excluded payload zone, fetched directly by ID on demand.

ADR 0016 records option 2. The project will prove zone exclusion on Mac and Simulator before it locks the schema, then repeat the path during the final physical-iPhone check.

## Decisions supported now

- Keep SwiftData local storage plus one main-app `CKSyncEngine`.
- Keep the Share extension local-only and feed its writes to sync through SwiftData History.
- Fetch remote data before the first local-to-cloud merge.
- Require an available iCloud account before activation completes.
- Do not keep permanent CloudKit tombstones in v1.
- Preserve an offline edit of a deleted snip as a new recovered record.
- Resolve equal list names with a stable, deterministic suffix rule.
- Treat 25 MiB per attachment and 100 MiB per snip as test candidates, not public Snip Snap limits or Apple limits.
- Split attachment metadata from payload to support the accepted on-demand transfer design.

## Project test scope before schema freeze

The project will do most checks on the Mac and iPhone and iPad Simulators, backed by a fake CloudKit adapter that can inject failures. It will use one physical iPhone for a short final sanity check and will not require a physical iPad for the first release.

1. Verify on Mac and Simulator that excluding the payload zone from `CKSyncEngine` fetches prevents asset transfer during normal sync, then repeat this path in the final physical-iPhone check.
2. Verify that a direct record fetch downloads one requested payload and that copying it out of CloudKit staging survives later staging cleanup.
3. Test candidate asset limits on Mac and Simulator, including interrupted transfers. Inject low local storage and exhausted iCloud quota at the storage and sync boundaries.
4. Simulate both orders of delete-versus-offline-edit. Confirm the original ID stays deleted and the recovered copy uses a new ID.
5. Delete the saved sync state in a test build and prove that bootstrap reconciliation does not upload stale local records before fetching the remote snapshot.
6. Create equal list names on two offline test stores and prove all devices choose the same suffixes after repeated sync.
7. Run the Share extension in iPhone and iPad Simulators while the main app is closed, then confirm the main app sees its SwiftData History transaction and queues it exactly once.

## Follow-up findings from the design review

Later checks against Apple's current documentation added three rules:

- Resolve record conflicts with a three-way field merge based on the ancestor, client, and current server records. Do not use device or CloudKit dates to choose which edit the user meant to keep. [`serverRecordChanged`](https://developer.apple.com/documentation/cloudkit/ckerror/serverrecordchanged)
- Use CloudKit encrypted values for user content and metadata from the first production schema, and keep search in the local store. CloudKit cannot turn an existing ordinary production field into an encrypted field later. [Encrypting user data](https://developer.apple.com/documentation/cloudkit/encrypting-user-data)
- Treat an encrypted-data reset as a new cloud collection and require the user to choose one recovery copy. Apple's current pages conflict on whether a sync-engine client should resend its cache, but this user-directed recovery is safe under either behavior and does not require a ruling from Apple. [`CKSyncEngine` deletion reason](https://developer.apple.com/documentation/cloudkit/cksyncenginezonedeletionreason/encrypteddatareset)
