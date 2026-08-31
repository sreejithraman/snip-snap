# 0021: Separate the shared snip library from platform apps

Snip Snap will keep saved-snips records and behavior in a local Swift package. The package will expose a small snip-library interface and contain three modules:

- `SnipSnapCore` owns domain records, commands, results, errors, and the snip-library interface. It does not import AppKit, UIKit, SwiftUI, SwiftData, or CloudKit.
- `SnipSnapPersistence` owns the JSON and SwiftData adapters, migration, local attachment storage, and store files. It depends on `SnipSnapCore`.
- `SnipSnapCloud` owns `CKSyncEngine`, CloudKit record mapping, merge and recovery work, and the cloud transport interface and fake. It depends on the shared records and persistence work.

The Mac app, iPhone and iPad app, and Share extension will remain separate Xcode targets. Their startup code will choose and assemble the adapters. The Mac and iOS main apps may link `SnipSnapCloud`; the Share extension will link only `SnipSnapCore` and `SnipSnapPersistence` and will never start cloud work or a store migration.

The Mac app will keep its panel, selection capture, global shortcuts, clipboard history, and AppKit code. The iOS app will own its navigation, editing, pasteboard, and Share-sheet code. Both apps will call the same snip-library interface. They will share a SwiftUI view only when the view and its behavior are truly the same on both platforms.

## Consequences

The current Mac `AppModel` must stop owning persistence details. Mac-only state may stay in a Mac app model, while saved-snips rules move behind the shared interface. Platform views must not know about SwiftData or CloudKit.

The JSON and SwiftData adapters will run the same behavior tests. Cloud tests will use the transport fake. Mac, iOS, and Share extension tests will cover only the platform work that sits above the shared interface.

This adds package targets and explicit dependency direction, but it prevents AppKit code from entering the iOS target, prevents CloudKit from entering the Share extension, and keeps saved-snips behavior in one place.
