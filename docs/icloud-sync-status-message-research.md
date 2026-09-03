# iCloud sync status message research

Date: 2026-09-03

## Finding from the screenshot

The screenshot does not show a CloudKit error. It shows `SnipSnapCloud.CloudRecordError error 2`, which is an app error. In this build, Swift bridges `CloudRecordError.invalidShadow` to code 2. The app throws that case when saved CloudKit record data cannot be read as a sound record shadow, or when its saved system fields no longer match.

The later `error 7` is also an app error. It maps to `CloudRecordError.invalidAssetDestination`. The app throws it when an attachment download does not have a safe local staging folder or file URL. See [`CloudRecordModel.swift`](../Packages/SnipSnapLibrary/Sources/SnipSnapCloud/CloudRecordModel.swift), [`CloudAssetFileCopy.swift`](../Packages/SnipSnapLibrary/Sources/SnipSnapCloud/CloudAssetFileCopy.swift), and [`CloudFullSyncPersistence.swift`](../Packages/SnipSnapLibrary/Sources/SnipSnapCloud/CloudFullSyncPersistence.swift).

An offline request should instead reach CloudKit as `networkUnavailable`, or sometimes `networkFailure`. Apple defines the first as no network and the second as a working network that cannot reach CloudKit. Apple says to wait for the network and retry with backoff. [`networkUnavailable`](https://developer.apple.com/documentation/cloudkit/ckerror/code/networkunavailable), [`networkFailure`](https://developer.apple.com/documentation/cloudkit/ckerror/code/networkfailure)

So a weak connection may have exposed the order or timing that led to these app-state faults, but neither raw code means “offline.” A solid connection would not repair the saved shadow on its own. The upgraded sync path now resets bad engine state, fetches before it sends, keeps automatic and manual work apart, and restores queued record bodies before automatic sync starts. The raw app codes stay in logs, not in the main Settings message.

## Account states

Apple exposes five account states. The app should check them before it asks a person to act. [`CKAccountStatus`](https://developer.apple.com/documentation/cloudkit/ckaccountstatus)

| State | Meaning and handling | Suggested title | Suggested detail |
| --- | --- | --- | --- |
| `available` | The account can use CloudKit. | `iCloud Sync On` | Keep the normal sync text. |
| `couldNotDetermine` | CloudKit could not get the account state. This may be short-lived, so retry before asking the user to change settings. | `Checking iCloud…` | `Snip Snap can’t check your iCloud account right now. Your changes are safe on this device, and sync will try again.` |
| `noAccount` | The device has no iCloud account. | `Sign In to iCloud` | `Sign in to iCloud in Settings to sync your snips. Your changes will stay on this device until then.` |
| `restricted` | Parental Controls or device management blocks access. This is not the same as being signed out. [`restricted`](https://developer.apple.com/documentation/cloudkit/ckaccountstatus/restricted) | `iCloud Access Is Restricted` | `A device setting or management rule is blocking iCloud. Your changes will stay on this device.` |
| `temporarilyUnavailable` | The account exists but is not ready for CloudKit. Apple says not to delete cached data or add more CloudKit work; wait for `CKAccountChanged`, then retry after the state becomes available. [`temporarilyUnavailable`](https://developer.apple.com/documentation/cloudkit/ckaccountstatus/temporarilyunavailable) | `iCloud Sync Paused` | `Your iCloud account is not ready for sync right now. Your changes are safe on this device, and sync will resume when iCloud is available.` |

## CloudKit errors

The first column groups errors by what the person needs to know. Do not show enum names, domains, codes, or Apple's raw `localizedDescription` in the main message.

| User state | CloudKit codes | App handling | Suggested message |
| --- | --- | --- | --- |
| No connection | `networkUnavailable` | Keep local work. Watch for a working network. Retry with backoff. | **Waiting for a Connection** — `You appear to be offline. Your changes are safe on this device and will sync when you’re back online.` |
| Cannot reach iCloud | `networkFailure`, `serviceUnavailable`, `serverResponseLost` | Retry. Use backoff and honor `retryAfterSeconds` for `serviceUnavailable`. If the response was lost, check server state before retrying a write whose result may not be safe to repeat. [`CKError`](https://developer.apple.com/documentation/cloudkit/ckerror), [`retryAfterSeconds`](https://developer.apple.com/documentation/cloudkit/ckerror/retryafterseconds) | **iCloud Is Unavailable** — `Snip Snap can’t reach iCloud right now. Your changes are safe on this device, and sync will try again.` |
| Server asks the app to wait | `requestRateLimited`, `zoneBusy` | Retry after the server delay when it exists. For repeat `zoneBusy` errors, increase the delay. [`retryAfterSeconds`](https://developer.apple.com/documentation/cloudkit/ckerror/retryafterseconds), [`zoneBusy`](https://developer.apple.com/documentation/cloudkit/ckerror/code/zonebusy) | **iCloud Sync Paused** — `iCloud asked Snip Snap to wait. Your changes are safe, and sync will try again soon.` Add `in about N minutes` only when the delay is both known and short enough to help. |
| Account is not ready | `accountTemporarilyUnavailable` | Do not delete the cache or enqueue more CloudKit work. Wait for an account change and for the state to become available. [`accountTemporarilyUnavailable`](https://developer.apple.com/documentation/cloudkit/ckerror/accounttemporarilyunavailable) | Use the account-state message above. |
| Sign-in needed | `notAuthenticated` | Refresh `CKAccountStatus`. If it reports no account, ask the user to sign in. Do not assume each authentication error means a lasting sign-out. [`notAuthenticated`](https://developer.apple.com/documentation/cloudkit/ckerror/notauthenticated) | **Sign In to iCloud** — use the `noAccount` detail above only after the account check. While that check runs, use `Checking iCloud…`. |
| Storage is full | `quotaExceeded` in this app's private database | Stop blind retries. Ask the user to manage iCloud storage, then retry. Apple says private-database quota comes from the user's iCloud storage. [`quotaExceeded`](https://developer.apple.com/documentation/cloudkit/ckerror/code/quotaexceeded) | **iCloud Storage Is Full** — `Free up some iCloud storage, then try sync again. Your changes are still on this device.` |
| App is too old | `incompatibleVersion` | Stop retries until the user updates. Apple defines this as the current app being older than the oldest allowed version. [`incompatibleVersion`](https://developer.apple.com/documentation/cloudkit/ckerror/code/incompatibleversion) | **Update Snip Snap to Sync** — `This version can no longer sync with iCloud. Update Snip Snap to keep syncing. Your changes are still on this device.` |
| Access denied | `permissionFailure`, `managedAccountRestricted` | Do not retry `permissionFailure`; Apple calls it nonrecoverable. For an account restriction, refresh account state and explain the restriction. [`permissionFailure`](https://developer.apple.com/documentation/cloudkit/ckerror/code/permissionfailure) | **iCloud Access Was Denied** — `Snip Snap can’t access this iCloud data. Check your iCloud and device restrictions, or contact support.` Use the clearer restricted-account text when that state is known. |
| Some records failed | `partialFailure`, with per-item errors that may include `batchRequestFailed` | Read `partialErrorsByItemID`. Handle each root error. A `batchRequestFailed` item did not cause the failure; fix the other item errors, then retry the batch. [`partialFailure`](https://developer.apple.com/documentation/cloudkit/ckerror/code/partialfailure), [`batchRequestFailed`](https://developer.apple.com/documentation/cloudkit/ckerror/code/batchrequestfailed) | Usually show the message for the root error. If roots differ: **Some Changes Haven’t Synced** — `Your other changes are safe. Snip Snap will retry the changes that did not sync.` |
| Attachment input changed or is missing | `assetFileModified`, `assetFileNotFound` | Rebuild the upload from stable local data. A blind retry can fail again. [`assetFileModified`](https://developer.apple.com/documentation/cloudkit/ckerror/assetfilemodified), [`assetFileNotFound`](https://developer.apple.com/documentation/cloudkit/ckerror/assetfilenotfound) | **An Attachment Couldn’t Sync** — `Snip Snap can’t find or read one attachment on this device. Your other changes are safe.` |
| Remote asset cannot be read | `assetNotAvailable` | Retry a fetch when useful. If it keeps failing, mark that attachment and keep the rest of sync moving. Apple's docs only say that the system cannot access the asset, so the app should not claim that the file was deleted. [`assetNotAvailable`](https://developer.apple.com/documentation/cloudkit/ckerror/code/assetnotavailable) | **An Attachment Isn’t Available** — `One attachment can’t be downloaded from iCloud right now. Snip Snap will try again.` |
| App can repair its sync cursor | `changeTokenExpired` | Clear the old token and run a full fetch. This is app work, not a user fault. Apple defines the error as an expired change token. [`changeTokenExpired`](https://developer.apple.com/documentation/cloudkit/ckerror/changetokenexpired) | Keep this out of Settings while recovery runs. If recovery fails: **Sync Will Try Again** — `Snip Snap needs to check your iCloud data again. Your local changes are safe.` |
| App or data rule failed | `alreadyShared`, `referenceViolation`, `constraintViolation`, `serverRejectedRequest`, `internalError`, plus `badContainer`, `badDatabase`, `invalidArguments`, `missingEntitlement`, and `limitExceeded` | These need app-side repair, request changes, or developer action. Apple calls `serverRejectedRequest` and `internalError` nonrecoverable. `limitExceeded` calls for smaller requests. Sharing errors do not apply unless Snip Snap adds CloudKit sharing. [`serverRejectedRequest`](https://developer.apple.com/documentation/cloudkit/ckerror/code/serverrejectedrequest), [`internalError`](https://developer.apple.com/documentation/cloudkit/ckerror/code/internalerror), [`CKError.Code`](https://developer.apple.com/documentation/cloudkit/ckerror/code) | **Snip Snap Couldn’t Sync** — `Your changes are safe on this device. Try again. If this keeps happening, contact support.` Offer a separate `Copy Error Details` action for support. |
| Old, unreachable result | `resultsTruncated` | Do not design a current user state around it. Apple marks it as deprecated and says CloudKit will not return it. [`resultsTruncated`](https://developer.apple.com/documentation/cloudkit/ckerror/resultstruncated) | None. |

`alreadyShared`, `referenceViolation`, `batchRequestFailed`, and `constraintViolation` do not call for distinct user text. They describe request or data relationships that the app must fix. `batchRequestFailed` is the exception in that it becomes retryable after the true item error has been handled.

## Retry rules

- Retry without user action: network errors, service trouble, rate limits, `zoneBusy`, `serverResponseLost` when safe, and `accountTemporarilyUnavailable` after the account becomes available.
- Repair, then retry: partial and batch failures, expired change tokens, record conflicts, missing or changed local asset files, request size limits, and bad references or constraints.
- Wait for the user: no iCloud account, a device or account restriction, full private iCloud storage, or an app version that is too old.
- Stop and report to developers: bad container or database, missing entitlement, invalid arguments, server rejection, and internal errors.

Apple supplies `retryAfterSeconds` for `serviceUnavailable` and `requestRateLimited`; its `zoneBusy` page also says to use the retry key when present. Never put that raw number in a message unless the app will honor it. [`retryAfterSeconds`](https://developer.apple.com/documentation/cloudkit/ckerror/retryafterseconds), [`zoneBusy`](https://developer.apple.com/documentation/cloudkit/ckerror/code/zonebusy)

## Product notes

1. Replace `failed(String)` with a small typed status or map each `Error` to a typed display value before the model loses its type. The current model stores `error.localizedDescription`, so it cannot tell offline, account, quota, and app data errors apart.
2. Treat retrying states as calm status, not as `Sync Needs Attention`. Use that title only when the user can take a clear action or a repeat app error needs support.
3. Say what remains safe. For this app, the useful line is `Your changes are safe on this device.` Use it only on paths that have in fact saved the change locally.
4. Keep the main text short. Put a safe action such as `Open iCloud Settings`, `Try Again`, or `Copy Error Details` under it when that action applies.
5. Log the error domain, code, nested partial errors, account state, and retry time. Do not show those fields by default.

## Source scope

This note uses Apple Developer Documentation and the CloudKit headers in the installed Xcode 26.5 SDK as first-party sources. The screenshot diagnosis also uses this repository's source and a local Swift check of the enum-to-`NSError` bridge. It does not use third-party error lists.
