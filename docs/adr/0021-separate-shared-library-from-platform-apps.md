# 0021: Separate the shared snip library from platform apps

Snip Snap keeps saved-snips and clipboard-history records and behavior in a local Swift package. The package exposes a small snip-library interface and contains three library modules:

- `SnipSnapCore` owns domain records, commands, results, errors, and the snip-library interface. It also holds the clipboard-history model, the sync settings model, diagnostics, and the command-line request types. It does not import AppKit, UIKit, SwiftUI, SwiftData, or CloudKit.
- `SnipSnapPersistence` owns the SwiftData adapter, migration, the JSON backup format ([ADR 0012](0012-use-one-record-store-for-local-and-icloud.md)), local attachment storage, the clipboard-history store, and store files. It depends on `SnipSnapCore`.
- `SnipSnapCloud` owns `CKSyncEngine`, CloudKit record mapping, merge and recovery work, clipboard-history sync, and the cloud transport interface and fake. It depends on the shared records and persistence work.

The package also builds the `snipsnap` command-line tool (`SnipSnapCLI`) and a test support target. The test support target holds the JSON adapter, which no app ships.

The Mac app, iPhone and iPad app, and Share extension remain separate Xcode targets. Their startup code chooses and assembles the adapters. The Mac and iOS main apps link `SnipSnapCloud`; the Share extension links only `SnipSnapCore` and `SnipSnapPersistence` and never starts cloud work or a store migration.

The Mac app keeps its panel, selection capture, global shortcuts, pasteboard capture, and AppKit code. The iOS app owns its navigation, editing, pasteboard, and Share-sheet code. Both apps call the same snip-library interface. They share a SwiftUI view only when the view and its behavior are truly the same on both platforms.

The Share extension shows a compact preview, a quick text edit, and a destination list. The first shared snip goes to Inbox. After that the extension remembers the last destination chosen on that device and falls back to Inbox when that list no longer exists. A Share extension cannot open its containing app on iOS, so it offers no open-app action.

## Consequences

App models hold platform state only; saved-snips rules stay behind the shared interface. Platform views do not import SwiftData or CloudKit.

The JSON and SwiftData adapters run the same behavior tests. Cloud tests use the transport fake. Mac, iOS, and Share extension tests cover only the platform work that sits above the shared interface.

This adds package targets and explicit dependency direction, but it prevents AppKit code from entering the iOS target, prevents CloudKit from entering the Share extension, and keeps saved-snips behavior in one place.
