# iOS action feedback

UI controls request actions. The action owner publishes feedback only after the
result succeeds. Views never select a haptic pattern.

| Action | UI entry points | Shared execution seam | Feedback |
| --- | --- | --- | --- |
| Copy + Done | Row and selection menus; Copy, Copy Text, Copy Attachments, Copy Text Only | `IOSCopyShareCoordinator.writeAndMarkDone` after the pasteboard accepts the payload and the model marks it Done when needed | `copied`, plus `markedDone` when the state changes |
| Done + Copy / Mark Not Done | Row button, context menu, selection menu | `IOSCopyShareCoordinator.toggleDone` when marking Done; `IOSAppModel.setDoneUnlocked` when marking Not Done | `copied` and `markedDone`, or `reopened` |
| Delete snips | Row and selection menus, accessibility action | `IOSAppModel.deleteSnips` after the deletion snapshot applies | `deleted` |
| Delete list | List menu | `IOSAppModel.performUserAction` after the deletion snapshot applies | `deleted` |
| Undo delete | Undo toast | `IOSAppModel.restoreDeletion` after the restored snapshot applies | `restored` |
| Undo Done | Undo snackbar | `SavedSnipsSession.restoreDone` after the inverse snapshot applies | `reopened` |
| Move | Row and selection menus | `IOSAppModel.performUserAction`, checking source lists before the move | `moved` |
| Merge | Selection menu | `IOSAppModel.performUserAction` after merge succeeds | `merged` |
| Save | Composer, inline editor, sheet editor | `IOSAppModel.performUserAction` after the saved snapshot applies | `saved` |
| Select | Row selection binding and context menu | `IOSAppModel.selectSnips` | `selection` |

The completion wrappers resolve the requested IDs and state within the existing
mutation queue. Both use the same command and no-op check. Add new controls by
calling these model or coordinator methods; do not write to the library or
pasteboard from a view. Background sync and the Share extension do not publish
foreground iOS feedback.

`IOSHapticFeedback` owns the local preference, active-scene check, and interaction
token. A newer action or flow change invalidates unfinished work. Published
results remain distinct from pending work: successful sheet dismissal or ending
selection must not erase a result that just completed.

`IOSHapticPlaying` has one operation: play an outcome. The UIKit adapter calls
Apple's feedback generators directly on the main actor. It owns no engine,
custom patterns, intensity curves, timers, playback queue, or trace file.

| Outcome | System feedback |
| --- | --- |
| Add / Save / Undo delete / Move | Light impact |
| Copy | Rigid impact |
| Done / Merge | Success notification |
| Delete | Medium impact |
| Select / Not Done | Selection |
| Warning / Error | Matching notification |

All impacts use Apple's default strength. UIKit playback happens when the action
emits, without waiting for a SwiftUI update. The root modifier only tracks scene
lifetime. Preference, cancellation, and stale-interaction checks still apply.

A compound result retains both meanings, such as `[.copied, .markedDone]`, but
plays one system response: error or warning first, otherwise the last outcome.
`IOSCopyShareCoordinator` owns Copy + Done and publishes the result after both
operations finish. A failed copy leaves the snip unchecked.

Tests cover the action paths, repeated outcomes, failures, preferences, and stale
work. A UI test exercises row Done and context-menu Copy/Delete. These
checks prove requests, not tactile quality; feel must be checked on the phone.

Reordering keeps the native drag feedback. The app adds no extra reorder tick.
Expired Undo, moving to the same list, and merging fewer than two snips add no
completion feedback. Both chronological and manual moves use the same outcome.

## Snackbar and error presentation

The Mac and iOS apps share snackbar wording, icons, and error details. Capture
confirms **Snipped** with scissors. Copy confirms **Snapped** with an explicit
copied-content detail. Copy and Done publish one combined result after both
operations settle; Undo reopens only newly Done snips and leaves the clipboard.
The Done checkmark is reserved for Done feedback. Delete uses the trash icon.

Recoverable action failures use a warning snackbar with **Details**. The most
recent failure remains available from **Error details** after its snackbar
expires. Save and field errors stay inline with the draft. Background sync
issues stay in their existing persistent status surfaces. Unsafe failures and
choices such as copying text without unavailable attachments use dialogs.
The same failure must not open a dialog and snackbar at once.

If Undo fails and another operation later fails, **Retry Undo** stays available
in a persistent inline notice. The notice sits above the iOS content or in the
Mac panel's status area. Its **Details** opens the original Undo error, while the newest
error keeps its own feedback. The notice hides while those Undo details are open
and ends when the inverse succeeds, becomes unavailable, or a saved-snips change
replaces it. Retrying Undo never repeats the clipboard write.

Error details offers **Copy error details** and **Share diagnostic log**. The
copied report includes app and system versions, time, operation and safe error
code, plus available matching diagnostic entries. It excludes raw localized
error text because that text can contain file paths or user content. Diagnostic
sharing reuses the existing bounded local-log export and native delivery.
Failures to prepare or share diagnostics remain inside the details view.

The active sheet owns its nested error details; the root host presents them only
when no app sheet is open. Closing Details acknowledges its matching dialog
failure while retaining the incident for later inspection. A backend no-op does
not consume the previous Undo or emit completion feedback.

External Mac capture uses its screen HUD for immediate feedback. Failures remain
available through Error details without publishing a second in-panel snackbar.
Diagnostic settings retain the actual operation and safe error code rather than
deriving a diagnostic identity from the displayed notice.
