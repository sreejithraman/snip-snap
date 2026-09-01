# Apple platform conventions review

Date: September 1, 2026

This review covers the Mac app, iPhone and iPad app, Share extension, local store, CloudKit sync, privacy files, signing, and release paths. It uses Apple docs, sessions, and sample code as sources.

## Result

The design fits the app. Snip Snap keeps one shared domain model, uses SwiftData as its local store, makes iCloud sync optional, and maps that store to the person's private CloudKit database. The extra sync code is justified by account isolation, explicit sync on and off, merge rules, recovered snips, durable deletes, and on-demand attachments.

The branch now follows the current Apple path in the areas that had gaps:

- It keeps one `CKSyncEngine` for the active cloud collection and leaves automatic sync on.
- It tells the engine about a successful local edit at once.
- It saves standalone engine state changes to the local store without waiting
  for a CloudKit control-record fetch.
- It handles the engine account-change event and `CKAccountChanged`.
- It enables remote notifications and checks the push entitlement in signed builds.
- It no longer starts new network work when the app enters the background.
- It chooses the iPad layout from the current window size class.
- It leaves multi-window support off until the app has shared scene state.
- It uses native glass button styles for true buttons and keeps custom glass only for compound controls.
- It honors Reduce Motion for app-owned motion and uses a 44-point hit area for the small attachment remove control.
- It uses CloudKit's async record fetch API instead of a hand-built operation and continuation.
- It fails closed if a final SwiftData store exists but its migration marker is not valid. It never opens an older JSON file as the live store in that state.

## Current Apple rules used here

### SwiftUI and AppKit

- Use Observation for new SwiftUI model state. Existing Combine models do not need a broad rewrite when they work and still serve AppKit code. [Managing model data](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)
- Use `NavigationStack` and `NavigationSplitView` for content navigation. Pick a compact layout from the current window, not the device model. [Navigation](https://developer.apple.com/documentation/swiftui/navigation), [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- Keep tabs for a small fixed set of top-level places. User-made lists are content, so the scrollable list selector stays custom. [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
- Use `.buttonStyle(.glass)` and `.glassProminent` for buttons on the current OS. A custom glass surface still makes sense for the composer and list strip because each groups several actions. [Glass button style](https://developer.apple.com/documentation/swiftui/glassbuttonstyle), [Custom Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- Keep thin AppKit bridges for panels, global shortcuts, pasteboards, file promises, drag sources, window geometry, Accessibility, and screen capture. SwiftUI has no full replacement for those contracts. [AppKit integration](https://developer.apple.com/documentation/swiftui/appkit-integration)

### SwiftData and CloudKit

- Use `cloudKitDatabase: .none` when the app owns the CloudKit layer. Managed SwiftData CloudKit sync would hide the merge, account, delete, and attachment rules this app needs. [SwiftData CloudKit sync](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices), [`CloudKitDatabase.none`](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct/none)
- Use `CKSyncEngine` for an app-owned local store. Create it near launch, keep it alive, save every state update, and leave `automaticallySync` on unless the product needs a manual engine. [Sync to iCloud with CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/), [Apple sample](https://github.com/apple/sample-cloudkit-sync-engine)
- Add local pending changes when a local save succeeds. Keep explicit fetch and send calls for first merge, **Sync Now**, tests, and recovery.
- Coalesce rapid local saves into automatic-engine scheduling. Do not start a
  full explicit fetch and send for each edit.
- Handle `accountChange`, observe `CKAccountChanged`, and check the account before private database work. Old account data must never appear under a new account. [`CKSyncEngine.Event.AccountChange`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/accountchange), [`CKAccountChanged`](https://developer.apple.com/documentation/cloudkit/ckaccountchangednotification)
- Let the automatic engine handle temporary retry timing. Direct control-record work has no tight retry loop; it returns the error and tries again only on a later lifecycle or user action. [`retryAfterSeconds`](https://developer.apple.com/documentation/cloudkit/ckerror/retryafterseconds)
- Use the private database, encrypted values for user fields, and `CKAsset` for files. Deploy the schema before TestFlight. [Private database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase), [Encrypting user data](https://developer.apple.com/documentation/cloudkit/encrypting-user-data), [Deploying a schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
- Keep accepted server shadows and a durable pending-delete row. SwiftData History can help detect changes, but it cannot replace the ancestor used for a three-way merge or the delete record that must survive state loss.

### App life cycle, extensions, files, and sharing

- Remote notifications let CloudKit wake the engine. Launch and foreground fetches remain required because background pushes are not guaranteed. [Background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- A background task only finishes work that already began. Do not wait for the background transition and then start a fresh sync. [Extending background execution](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
- The Share extension must copy temporary provider files into its App Group inbox. The main app owns migration and imports the request into SwiftData. [Share extensions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html), [App Group scenarios](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)
- iOS store, inbox, and attachment paths use complete-until-first-authentication protection. This keeps them encrypted before the first unlock after a restart while allowing CloudKit to finish queued work after that unlock. [Encrypting app files](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)
- The current `UIActivityViewController` bridge stays. It is Apple's native mixed-item share surface and handles text plus several prepared files. `ShareLink` would still need a custom heterogeneous transfer model and has no proved behavior gain here. [`ShareLink`](https://developer.apple.com/documentation/swiftui/sharelink)
- Keep the pasteboard file lease. Item providers may ask for a file after the copy action returns, so the app must keep staged files alive until the pasteboard changes. [`UIPasteboard.itemProviders`](https://developer.apple.com/documentation/uikit/uipasteboard/itemproviders)

### Access, privacy, tests, and open source

- Use semantic text, system labels, enough contrast, 44-point hit areas, and Reduce Motion for custom effects. [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- Keep a privacy manifest in each executable that uses a required-reason API. Recheck the archive privacy report and App Store answers before upload. [Privacy manifests](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files), [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- Keep XCTest where it works. Swift Testing is a good option for new pure model tests, but a rewrite has no product gain. [Testing](https://developer.apple.com/documentation/xcode/testing)
- Keep public IDs neutral and contributor builds local-only. Put the publishing team's IDs, profiles, keys, and upload credentials in ignored local input or protected CI. [Build settings](https://developer.apple.com/documentation/xcode/configuring-the-build-settings-of-a-target/), [Enable capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities)
- A Developer ID Mac app that uses CloudKit and push needs its matching
  Developer ID provisioning profile embedded and checked before notarization.
  [Developer ID](https://developer.apple.com/support/developer-id/)
- TestFlight uses the production CloudKit environment and needs the production schema, production push entitlement, privacy details, and export answers. [TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)

## Checks that still need Apple services or a phone

Code and Simulator tests can prove the local store, merge rules, offline queue, UI, Share extension inbox, and injected CloudKit errors. They cannot prove a production schema, a signed entitlement granted by Apple, or a remote CloudKit push. Before release, inspect the signed archives and run one phone check for install, sync on and off, offline edit then reconnect, attachment transfer, account sign-out or switch, and a background receiver. Apple's sample notes the Simulator push limit. [Apple CKSyncEngine sample](https://github.com/apple/sample-cloudkit-sync-engine)
