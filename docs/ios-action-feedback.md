# iOS action feedback

UI controls request actions. The action owner publishes feedback only after the
result succeeds. Views never select a haptic pattern.

| Action | UI entry points | Shared execution seam | Feedback |
| --- | --- | --- | --- |
| Copy + Done | Row and selection menus; Copy, Copy Text, Copy Attachments, Copy Text Only | `IOSCopyShareCoordinator.writeAndMarkDone` after the pasteboard accepts the payload and the model marks it Done when needed | `copied`, plus `markedDone` when the state changes |
| Done + Copy / Mark Not Done | Row button, swipe, context menu, selection menu | `IOSCopyShareCoordinator.toggleDone` when marking Done; `IOSAppModel.setDoneUnlocked` when marking Not Done | `copied` and `markedDone`, or `reopened` |
| Delete snips | Row and selection menus, swipe | `IOSAppModel.deleteSnips` after the deletion snapshot applies | `deleted` |
| Delete list | List menu | `IOSAppModel.performUserAction` after the deletion snapshot applies | `deleted` |
| Undo delete | Undo toast | `IOSAppModel.restoreDeletion` after the restored snapshot applies | `restored` |
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
work. A UI test exercises swipe Done/Delete and context-menu Copy/Delete. These
checks prove requests, not tactile quality; feel must be checked on the phone.

Reordering keeps the native drag feedback. The app adds no extra reorder tick.
Expired Undo, moving to the same list, and merging fewer than two snips add no
completion feedback. Both chronological and manual moves use the same outcome.
