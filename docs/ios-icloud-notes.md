# iOS and optional iCloud sync notes

These notes record the accepted product direction and the facts that support it. The ADRs hold the decisions that implementation must follow.

## Product direction

- Add a full saved-snips app for iOS that works without a Mac.
- Support both iPhone and iPad in the first release.
- Require iOS and iPadOS 26.
- Keep iCloud sync optional and off by default on each device.
- Let the Mac app remain fully useful with local storage only.
- Let the iOS app remain fully useful with local storage only.
- Never require a separate sign-in.
- Keep clipboard history, drafts, shortcuts, panel state, and other device settings local.
- Sync only saved snips, lists, and attachments that belong to saved snips.
- Sync through the user's private iCloud database. Do not add shared lists or collaboration in the first release.
- Do not try to copy the Mac's global capture or clipboard history behavior on iOS.
- Include a Share extension in the first release for text, links, images, and files.
- Do not ship public sync until saved attachments work on Mac, iPhone, and iPad.

## Storage direction

- Keep the existing domain types and repository rules where they still fit.
- Put shared records and saved-snips behavior in `SnipSnapCore`, local storage in `SnipSnapPersistence`, and optional CloudKit work in `SnipSnapCloud` inside one local Swift package.
- Keep the Mac app, iPhone and iPad app, and Share extension as separate Xcode targets with separate platform UI shells.
- Link the Share extension only to the core and persistence modules. Only the main apps may link and start the cloud module.
- Keep platform views above the snip-library interface so they do not know about SwiftData or CloudKit.
- Define one persistence schema made of separate snip, list, and attachment records.
- Use the same persistence schema for local-only and iCloud modes.
- Use a local store with CloudKit disabled when sync is off.
- Use a local cache backed by the user's private CloudKit database when sync is on.
- Expose one active collection on each device rather than separate local and iCloud collections.
- Keep store selection and mode changes behind the repository seam so views do not depend on CloudKit.
- Keep stable IDs across local storage, iCloud, import, export, and mode changes.
- Store each attachment as its own record so attachment changes do not rewrite a whole snip collection.
- Replace sequential manual positions with sync-safe sort keys.

## Existing data

- The Mac live store is SwiftData. JSON is backup import and export only.
- ADR 0012 supersedes ADR 0001.
- When the user imports a backup while sync is on, show a preview and merge it through the normal record rules. Send the accepted result through the normal sync path.
- Do not require the user to turn off sync before importing a backup.

## Mode changes

- Enabling sync should merge local records into the iCloud-backed store and change modes only after the import succeeds.
- Disabling sync should make a local copy before detaching the device from iCloud.
- Turning off sync must not delete the user's iCloud data.
- Deleting iCloud data must be a separate action with a clear warning.
- Name that action Delete Synced Content because a small control record remains in iCloud.
- Keep a random sync generation and the active data-zone IDs in that control record.
- Reset by publishing a new generation with fresh data zones before deleting the old data zones.
- Require every device to fetch and match the current generation before it may upload.
- On a generation mismatch, remove old pending cloud work, isolate or clear the old cache, start new engine state, and fetch the new collection before allowing sends.
- If a device that has synced before finds no control record, treat it as an iCloud Settings purge. Do not restore its old cache to iCloud automatically.
- Let a first-time device create a generation only after the user enables sync. After a purge, require the user to enable sync again before creating an empty generation.
- Treat an iCloud encrypted-data reset as deleted cloud data. Stop sends, clear the old sync cache, and do not resend it.
- Delete the old local store. Do not offer to restore it or keep it as a recovery copy.
- Keep backup import separate from sync reset recovery. A later import must start with a backup that the user owns and picks.
- Follow the current `CKSyncEngine` contract for both purge and encrypted-data reset: clear cached data and do not resend it.
- A failed mode change must leave the prior store active and usable.
- The sync choice is local to each device and must not itself sync.
- When local and iCloud records differ, merge unrelated records by stable ID.
- Keep a sync shadow for each record with its last accepted CloudKit system fields and last accepted mergeable values.
- Merge each field against that shared base. Accept independent changes from both devices.
- Never use device dates or CloudKit upload dates to decide which concurrent edit the user meant to keep.
- When both sides changed the same text or other user field differently, keep the current server value on the original identity and preserve the local value as a recovered snip.
- Merge attachments by stable ID and resolve ordering in a fixed way.
- Show a recovered snip beside the main snip with a Recovered badge and a short explanation.
- Put a recovered snip in Inbox when its prior list no longer exists.
- Store a link from each recovered snip to its current snip and record which fields conflicted.
- Let the Recovered badge and Needs Attention status open a comparison of Current and Recovered Edit.
- Offer Keep Current, Use Recovered, Keep Both, and Edit. Apply only the chosen conflicting fields so unrelated merged changes remain intact.
- Do not block sync or show an urgent popup for a recovered snip.
- Refresh the comparison before applying a choice if the current snip changed while the review was open.
- When a remote delete competes with an offline edit of the deleted snip, keep the original deleted and save the edited version as a recovered snip in Inbox.
- Let a user turn off sync while offline by copying the current local cache and warning that newer iCloud changes may not be present.
- Keep the iCloud copy intact when a device turns off sync.
- When a user enables sync while offline, record the request as Setting Up but keep local-only mode active.
- Complete setup only after the account is available, the app fetches the remote collection, and the first merge is durable.
- Show Off, Setting Up, On, Syncing, and Needs Attention. Do not claim that the store is fully up to date when the app cannot prove it.
- Undo only actions taken on the current device and record each inverse action as a normal edit that can sync.
- Never implement undo by replacing the whole store. Remove an undo entry when a remote change makes its inverse unsafe.

## Open-source scope

- Official signed builds use the Snip Snap project's CloudKit container.
- Forks use local-only mode or configure a CloudKit container that they own.
- A shared community backend and self-hosted sync are out of scope.
- Normal contributor builds and tests must not require an Apple team, signing key, paid service, or iCloud account.
- Keep normal numbered Dev-slot and contributor builds local-only and unable to reach CloudKit.
- Give signed Cloud Dev builds fixed app identities, an isolated App Group and local store, a clear badge, and the CloudKit development environment.
- Keep safe local-only defaults and a blank settings template in the repository. Put team, signing, device, and machine values in ignored local settings, environment variables, or CI.
- Let normal builds work when signed-only settings are absent. Make Cloud Dev, device, and release commands list the settings they need when those settings are missing.
- Keep public app, App Group, and CloudKit identifiers as project settings, but apply restricted entitlements only in explicit signed build lanes. Let forks replace those identifiers.
- Scan tracked build and release inputs for personal paths, team IDs, profile IDs, device IDs, and signing choices.

## Release order

1. Keep the Mac live store on local-only SwiftData.
2. Check recovery, import, and export in normal use before adding public sync.
3. Build and test the CloudKit schema in development with the Mac, iPhone Simulator, and iPad Simulator checks listed below.
4. Test optional sync with Mac, iPhone, and iPad builds against the same development schema.
5. Release Mac sync and the iOS app only after cross-device tests pass. Do not expose a public mode that depends on an unreleased peer implementation.

## Apple sync constraints

- SwiftData's managed iCloud sync uses `NSPersistentCloudKitContainer`, and the system decides when imports and exports run. The app cannot force a final sync before a mode change.
- CloudKit store events report setup, import, and export operations. They do not prove that every device has sent all changes.
- Observe iCloud account changes and check the current account status again before allowing more cloud work.
- A temporary account failure must not cause the app to delete its cached data.
- Data cached for one Apple Account must never merge into another Apple Account without a clear user choice.
- On iCloud sign-out or an Apple Account change, stop cloud writes and isolate the prior account's cache.
- Ask whether to keep the isolated cache as a local-only copy or remove it from the device.
- Do not show or upload the prior account's data under the new account.
- Use separate local-only and iCloud-backed store files. Do not repurpose one store file when the mode changes.

Sources: [SwiftData iCloud sync](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices), [CloudKit container events](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/eventchangednotification), [CloudKit account status](https://developer.apple.com/documentation/cloudkit/ckaccountstatus), and [CloudKit account changes](https://developer.apple.com/documentation/cloudkit/ckaccountchangednotification).

## Sync technology choice

- SwiftData-managed CloudKit sync provides a local replica with less application code, but it does not document app-controlled, metadata-first attachment downloads or an evictable per-file cache.
- `CKSyncEngine` keeps local persistence under the app's control and schedules CloudKit work while allowing explicit fetches and sends.
- A `CKSyncEngine` adapter must map local changes to CloudKit records, persist the engine's serialized state, supply pending changes, apply fetched changes, and handle conflicts and account changes.
- A record fetched through `CKSyncEngine` downloads its asset fields. The engine has no field filter like `desiredKeys`.
- True on-demand files require attachment metadata in the normal sync zone and immutable asset payload records in a separate zone that automatic fetches exclude.
- Fetch an excluded payload record directly by ID after a user action, then copy its staged file into the app-owned cache.
- Prove that excluded payload records do not transfer during normal sync on Mac and Simulator before freezing the CloudKit schema, then include this in the final physical-iPhone check.
- Do not combine SwiftData-managed sync with direct asset sync unless a later need justifies two sync paths.
- Use SwiftData with CloudKit disabled for the local record store.
- Use `CKSyncEngine` as the optional adapter between the active iCloud-mode store and the project's private CloudKit database.
- Use direct CloudKit records and `CKAsset` fields for snips, lists, and attachments rather than mixing managed SwiftData sync with direct asset sync.
- Save with record-change checks and retain the accepted CloudKit system fields after each write.
- On a record conflict, compare the client, server, and ancestor values field by field. Retry from the current server record rather than the attempted client record.
- Treat fields that an app version does not understand as untouched. Add fields to the production schema, but do not rename or remove them.
- Include a schema version from the first synced record and test new-app to old-app to new-app edits before each schema release.

Sources: [Choosing a CloudKit approach](https://developer.apple.com/documentation/cloudkit/deciding-whether-cloudkit-is-right-for-your-app), [`CKSyncEngine`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5), and [`CKAsset`](https://developer.apple.com/documentation/cloudkit/ckasset).

## iOS Copy and Share

- Copy writes formatted plain text first and adds one file item provider for each attachment.
- Add separate Copy Text and Copy Attachments actions.
- Fetch attachments that are not local before copying them.
- If any attachment remains unavailable, offer Copy Text Only or Cancel. Never omit a file without notice.
- Use Share as the reliable full-content path for a mixed text-and-attachment snip because another app decides which pasteboard forms it accepts.

## Share extension constraints

- The app and Share extension run in separate containers. An App Group gives both processes one shared container.
- The main app alone opens the SwiftData store and owns persistence migrations. The extension must never open that store because SwiftData may run an automatic migration even without a custom migration plan.
- The extension must copy each temporary item-provider file into durable App Group storage before the provider callback returns.
- Treat a durable write to an atomic App Group pending-import inbox as success. Do not keep the extension open while waiting for the main app or iCloud.
- Let the main app import pending items exactly once when it next runs or returns to the foreground.
- Show a compact preview, a quick text edit, and a destination list before saving.
- Default the first shared snip to Inbox, then remember the last chosen share destination on that device.
- Fall back to Inbox when the remembered list no longer exists.
- Keep quick text editing in the extension. A Share extension cannot open its containing app through `NSExtensionContext.open` on iOS, so do not offer an unsupported open-app action.

Sources: [Shared data](https://developer.apple.com/documentation/technologyoverviews/shared-data), [App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups), [extension life cycle](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html), [`NSItemProvider.loadFileRepresentation`](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(fortypeidentifier:completionhandler:)), [`NSExtensionContext.open`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)), and [`ModelContainer`](https://developer.apple.com/documentation/swiftdata/modelcontainer).

## Attachment constraints

- Store filename, content type, byte count, hash, payload record name, and other file details on an attachment metadata record because `CKAsset` stores only file bytes.
- CloudKit returns downloaded asset files in a staging area that the system may clear. Copy a downloaded file into an app-owned cache when it must remain available.
- Direct CloudKit fetches can omit the asset field and fetch it later on demand.
- Private attachment data counts against the user's iCloud quota.
- Snip Snap supports iCloud Sync attachments up to 25 MiB each and 100 MiB total per snip. These are Snip Snap limits, not Apple limits.
- Automated tests cover inclusive boundaries, one-byte overflow, every incompatible filename, a generated 25 MiB upload and fresh-client download, hash and cache checks, interrupted fetch and upload retries, quota failure without false acceptance, and the enable action on iPhone and iPad Simulators.
- Keep local-only attachments unrestricted by a Snip Snap size policy.
- Report every incompatible existing file before enabling sync and never send it after sync is on.
- Use one attachment metadata record in the normal sync zone and one immutable payload record in an excluded payload zone.
- Upload and confirm the payload before publishing its metadata.
- Fetch a payload directly by record ID only when the user previews, opens, copies, or exports the attachment.
- Copy downloaded bytes out of CloudKit staging, verify their size and hash, and keep them in a bounded local cache.
- Delete metadata first, then delete its payload. Keep a cleanup job until it removes an abandoned or deleted payload.
- Replace an attachment by publishing a new immutable payload before removing the old payload.
- A local attachment save succeeds without a network connection. When iCloud Sync is on, the
  main app keeps a durable upload copy and retries it on launch, foreground, and later sync runs.
  The app does not promise an upload while it is terminated. A Share extension reports success
  after the local save; it does not wait for CloudKit.
- Namespace changes make old upload and download rows dormant. New account or generation work
  cannot read or send them. Keep offline-only bytes under the old namespace until a recovery flow
  copies them or the user chooses to remove them. Cleanup means removing active references and
  proven, unreferenced copies; it does not mean deleting the last local copy.
- Provide Clear Downloaded Files and do not add offline pinning in the first release.

Sources: [`CKAsset`](https://developer.apple.com/documentation/cloudkit/ckasset), [fetching selected record fields](https://developer.apple.com/documentation/cloudkit/ckfetchrecordsoperation/desiredkeys-34l1l), [private CloudKit storage](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase), and [CloudKit limit errors](https://developer.apple.com/documentation/cloudkit/ckerror/limitexceeded).

Full findings: [Optional iCloud sync policy research](icloud-sync-policy-research.md).

## Privacy and local search

- Use CloudKit encrypted values for all user-derived record fields from the first production schema.
- Encrypt snip text, source app names, window titles, source URLs, list names, filenames, file details, hashes, and sort positions.
- Store attachment bytes in `CKAsset` fields, which CloudKit encrypts automatically.
- Keep only opaque routing and control values in ordinary fields: random IDs, record kinds, schema and protocol versions, required state flags, and the sync generation.
- Never put text, URLs, filenames, hashes, or other meaningful data in record names.
- Sync source app, window title, and URL as part of a saved snip. Explain this in the sync disclosure.
- Search, filter, and sort only in the local SwiftData store. Do not query CloudKit for user content.
- Synced records live in the user's private iCloud database. Snip Snap's maintainers cannot inspect private records in CloudKit Console.
- Say that Apple encrypts synced data in transit and at rest. Snip Snap stores user fields as CloudKit encrypted values and file bytes as `CKAsset` data.
- Say that synced data is end-to-end encrypted only when Advanced Data Protection is on for the user's iCloud account.
- Recheck the App Store privacy label against the final build and every included service before release.

Sources: [CloudKit encrypted values](https://developer.apple.com/documentation/cloudkit/encrypting-user-data), [private CloudKit database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase), and [iCloud data security](https://support.apple.com/en-us/102651).

Snip Snap follows the current `CKSyncEngine` rule for purge and encrypted-data reset: it clears cached data and does not resend it. A later backup import is a separate user action. Sources: [encrypted-data reset](https://developer.apple.com/documentation/cloudkit/ckdatabase/databasechange/deletion/reason-swift.enum/encrypteddatareset) and [`CKSyncEngine` zone deletion reason](https://developer.apple.com/documentation/cloudkit/cksyncenginezonedeletionreason/encrypteddatareset).

## Open decisions

- None from the current design review.

## Delete and merge rules

- Do not create permanent app-owned tombstone records in CloudKit.
- Keep a local outbound-delete ledger until CloudKit acknowledges each deletion.
- Save the last known server fields needed to update or delete each synced record.
- During a new bootstrap or lost-state recovery, fetch and reconcile the remote collection before sending local records.
- Treat `unknownItem` for an offline edit as a remote deletion. Keep the original deleted and save the edit as a recovered snip with a new ID.
- When different list IDs have the same normalized name, sort the IDs in a fixed way, keep the first name, and apply numbered suffixes to the rest.
- Do not use device clocks or delivery order to choose which equal list name changes.
- If a device moves a snip into a list that another device deleted, keep the list deleted and move the snip to Inbox.
- Record the Inbox move in sync status so the user can see why it happened.
- Use sync-safe sort keys for manual order. Resolve equal keys with the stable snip ID.
- Let the server-accepted record settle two concurrent moves of the same snip. Do not create recovered copies or warnings for order-only changes.

## Test scope before release

The main test surface is the Mac plus iPhone and iPad Simulators. A physical iPad is not required. Keep physical-device work to one final iPhone sanity check.

Automate these checks with temporary durable SwiftData stores, a fake Cloud transport, signed development-environment runs where available, and Simulator UI tests. Use in-memory stores only for small tests that do not concern reopen, migration, recovery, or lost state:

- Run two or more local client stores against one fake server and inject offline periods, retries, duplicate events, reordered events, conflicts, account changes, zone deletion, encrypted-data reset, quota errors, and lost sync-engine state.
- Verify on Mac and Simulator that normal `CKSyncEngine` fetches exclude the payload zone.
- Verify that a direct payload fetch downloads one requested file and that the app-owned cached copy survives CloudKit staging cleanup.
- Keep the 25 MiB per-attachment and 100 MiB per-snip boundary tests green. Test interrupted transfers and simulate low local storage and exhausted iCloud quota at the storage and sync boundaries.
- Test both orders of delete versus offline edit and require the recovered edit to use a new ID.
- Delete saved sync-engine state and prove bootstrap does not upload stale records before fetching the remote collection.
- Create equal list names on offline client stores and prove every client produces the same suffixes.
- Run the Share extension in iPhone and iPad Simulators while the main app is open, closed, and unable to migrate. Prove that each accepted share enters the main store exactly once.
- Exercise text, image, file, mixed, and multi-snip Copy and Share flows in both iPhone and iPad Simulators.
- Run the same SwiftData migration, repository, merge, sync, and recovery test suites for the Mac and iOS targets.

Before release, run the [physical-iPhone release checklist](release-checklist.md) with a release-like signed build. Automated Mac and Simulator evidence sets the Snip Snap attachment policy, but it does not complete that physical transfer gate.

Accept that Simulator and injected failures do not prove every production push, background, storage-pressure, account, or file-provider behavior. Record any physical-device-only bug found later as a release fix, but do not require a larger device lab for the first release.
