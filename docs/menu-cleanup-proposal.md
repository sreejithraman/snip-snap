# Menu cleanup proposal

Date: 2026-09-05

Status: First pass implemented on 2026-09-05. The table below records the
pre-change source review. See the implementation notes for scope and checks.

Apple sources and platform rules: [Menu platform guidance](menu-platform-guidance-research.md).

## Current behavior

| Surface | Mac | iOS / iPadOS |
| --- | --- | --- |
| Snip context menu | Native AppKit `NSMenu`: Copy; Done/Not Done, Edit, Edit in New Window, Merge Snips, Move to, Move Up/Down; Delete. Unavailable edit, merge, and reorder commands stay disabled. | SwiftUI context menu: Done/Not Done, Edit, Edit Attachments, Move; Copy, Copy Text, Copy Attachments, Share; Delete. Some actions have symbols and others do not. Copy Attachments stays disabled without files. |
| Move destinations | All lists, including the source, plus New List. | Other lists only. No New List; the submenu can have no destinations. |
| View options | More mixes filter, sort, appearance, selection actions, permission help, and keyboard settings. | A View Options menu holds inline Show and Sort pickers. Library Actions holds settings, selection mode, import, list actions, and optional sync tools. |
| Sort names | Chronological / Manual. | Newest First / Manual. Both use the shared sort implementation, which puts unfinished snips first, then sorts each state group. |
| List context menu | Edit List…; Delete List, with confirmation explaining that snips move to Inbox. | Edit List; Delete, called directly from sidebar and compact tabs. Library Actions uses Delete List and asks for confirmation. |
| Multiple snips | Context menu targets the clicked snip or the existing selection when the clicked snip belongs to it. Completion offers one action based on whether all are done. | Selection mode opens a separate menu. It always offers both Done and Not Done. |

Source locations:

- `SnipSnap/SnipListView.swift`: `makeSelectionMenu`, `contextSelection`.
- `SnipSnap/PanelCardInteraction.swift`: native menu creation and presentation.
- `SnipSnap/PanelMoreButton.swift`: Mac More contents.
- `SnipSnap/SnipListTabBarView.swift`: list actions and confirmation.
- `SnipSnapiOS/SnipCollectionViews.swift`: snip context menu.
- `SnipSnapiOS/WorkflowControls.swift`: view options and selection actions.
- `SnipSnapiOS/MoveSnipMenu.swift`: single-snip destinations.
- `SnipSnapiOS/IOSCopyShare.swift`: four copy/share commands.
- `SnipSnapiOS/LibrarySidebarViews.swift`, `CompactLibraryControls.swift`: list actions.
- `Packages/SnipSnapLibrary/Sources/SnipSnapCore/Snip.swift`: sort behavior.

## Proposed approach

Share action meaning, names, and availability rules. Keep native AppKit menus on
Mac and native SwiftUI menus on iOS. Do not add custom menu rows, colors, sizes,
or a cross-platform menu renderer. Mac's panel already handles right-click and
selection through AppKit; this review gives no reason to replace that path.

### First pass

1. Use the same names where the actions match: Show, Sort, Newest First,
   Manual, Move to List, Edit List, and Delete List. Use Mark Done / Mark Not
   Done in menus while keeping Done / Not Done for state labels and compact
   controls. Apply ellipses where an action needs more input, following each
   platform's guidance; do not append one merely because a view opens.
2. Use three broad context-menu groups: copy/share; edit, completion, and
   organization; deletion. Put Copy first on both as a product choice for this
   capture-and-reuse app. Check SwiftUI's actual display order near both screen
   edges; native priority ordering can differ from source order. Keep Delete
   last and separate. Keep Mac-only Edit in
   New Window and Merge Snips where they apply.
3. Omit inapplicable context actions: Merge for one snip, Edit for multiple
   snips, and reorder actions when manual reorder is unavailable. Retain normal
   disabled behavior in the Mac menu bar. On iOS, offer Copy Text and Copy
   Attachments only when they give a useful choice beyond Copy; hide Copy
   Attachments without attachments. Keep Share on iOS.
4. Make Move to List show valid destinations. Exclude a destination when all
   targeted snips already belong to it. Keep one submenu level. Add New List…
   on iOS using the existing list form, retaining the selected snips until the
   user saves or cancels. This also resolves the empty submenu for Inbox-only
   libraries. Verify selection survives the form flow before shipping it.
5. For bulk completion, offer Mark Done for all unfinished selections, Mark
   Not Done for all finished selections, and both for mixed selections. This
   avoids redundant commands while making a mixed selection's result explicit.
6. Route every list-delete entry through the same per-platform confirmation
   flow, explaining that snips move to Inbox. Keep the existing short Undo
   behavior for snip deletion; ADR 0023 does not provide Undo for list deletion.
7. Group Mac More into view options, selection, and app controls. Keep native
   checkmarked pickers for Show and Sort. Start by regrouping the current
   control; do not add another toolbar button until real panel width is checked.
   Keep iOS's separate View Options and Library Actions menus. Put frequent
   selection/list actions before settings and maintenance actions on iOS.
8. Supply consistent SF Symbol labels for iOS actions, including Edit,
   completion, and Delete. Let each OS render symbols, destructive roles, and
   selection marks. Do not force iOS's icon treatment onto Mac.

### Check before widening scope

- Confirm common context actions have a visible route or a Mac menu-bar route.
  In particular, inspect Move to List and list editing on Mac, and Move on iOS
  outside a long press. Add a route if it is missing; do not put every rare
  command on a card.
- Treat Mac Share, iOS Merge, and broader editor changes as separate product
  decisions. Different feature sets do not require different names for shared
  actions.
- Retain unfinished-first sorting. Newest First names the time order inside
  each state group; make that grouping clear if runtime review shows confusion.

## Verification after approval

Run real apps only through `scripts/run.sh`, then use showroom for the review
surfaces. Check Mac right-click, Control-click, dismissal, keyboard focus, and
the target selection. Check iPhone long press and iPad touch/pointer menus.
Cover one snip, multiple snips, mixed completion states, text and attachments,
Inbox-only libraries, manual and chronological sorting, and list deletion from
every entry point. Check native checkmarks, VoiceOver action names, and large
text on iOS. Test move-to-new-list save/cancel and snip-delete Undo.

## First pass implemented

The user approved a first pass. It aligns Show, Newest First, Move to List,
Edit List…, and Delete List labels. Menus use Mark Done / Mark Not Done;
compact controls retain Done / Not Done. Both selection menus offer each
completion action only when it changes a targeted snip. Mixed selections offer
both actions. The Mac completion command sets the requested state while keeping
the target selection.

Copy appears first. iOS hides Copy Text and Copy Attachments for text-only
snips. Mac hides unavailable edit, merge, and reorder context commands. Move
excludes a list when all targeted snips already belong to it. iOS hides Move
when no destination exists. Mac retains New List… without an empty separator.

Mac More groups view options, selection actions, and app controls. iOS keeps
its separate menus and puts selection and list actions ahead of app controls.
iOS list tabs, sidebar rows, and Library Actions share a native confirmation
view that explains the move to Inbox. Native menu styles remain in place.

Deferred: iOS Move to New List needs a save/failure flow that keeps the target
IDs and avoids creating another list on retry. No editor or storage changes
for that flow are included. The broader audit of visible routes to context
actions also remains open.

Both Dev apps built and launched through `scripts/run.sh`. Live checks covered
Mac context and More menus, the Mac completion action, iOS text-only selection
actions and Mark Done, iOS View Options checkmarks, list creation, and opening
and dismissing the Library Actions delete confirmation. The list remained after
dismissal. Screenshots show Mac context/More and iOS selection/view/library menus.

Follow-up: removed Move Up and Move Down from the Mac context/menu-bar menus
and iOS selection menu at the user's request. Both Dev apps rebuilt through
`scripts/run.sh`. The installed Simulator helper opened the actual iOS item
long-press menu. Mark Not Done changed the sample item; reopening its menu
showed Mark Done. Captured `ios-item-long-press.png` for review.

The list-tab context confirmation, iPad, VoiceOver, attachment menus,
mixed-selection completion, actual list deletion, and move execution still
need hands-on checks. No automated test suite ran for this pass.

## Drag reorder follow-up

View Options now offers Reorder Snips. It shows native iOS drag handles and a
Done button without entering selection. Select Snips also retains native drag
handles. A changed drop switches to Manual order; iOS saves that sort choice
across launches. Reordering requires Show All and an empty search. The existing
unfinished-first grouping remains in place.

The handles appear only while reordering or selecting. Keeping the list in
edit mode all the time blocked its swipe actions in Simulator checks. Apple
describes the native move controls in its [EditMode documentation](https://developer.apple.com/documentation/swiftui/editmode).

Checks passed: three model tests for saved manual order, unchanged drops, and
filtered/stale input; four Simulator UI tests for drag and relaunch, both swipe
actions, and selecting/moving several snips before reordering. The item menu
still opens after reorder and relaunch. Rebuilt and launched Dev 2 through
`scripts/run.sh`. Screenshot: `/tmp/snipsnap-menu-review/ios-reorder.png`.

## Selection follow-up

Selection mode groups View Options and selected-item actions in one native
toolbar section, with a separate × to finish selection. The symbols have no
inner circles. The item context menu includes Select; it enters selection mode
with that snip selected. Entering through Select Snips starts empty. Leaving
selection or changing lists clears the selection. Changing the completion
filter clears any selected IDs that the new filter hides.

The Delete context action keeps its destructive role and explicitly colors its
trash symbol red to match its title. Simulator review confirmed both are red.

Apple's [toolbar guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars)
calls for clear, distinct controls for critical actions such as closing a mode.
[ToolbarSpacer](https://developer.apple.com/documentation/swiftui/toolbarspacer)
provides the native separation used here. The × layout follows the user's
Photos reference.

Checks passed for item-menu selection, selected-item actions, separate close,
and clearing hidden selections when filtering. Screenshots confirm the separate
native toolbar sections and red Delete text and icon. Updated Snip Snap Dev 2
installed on the paired iPhone; automatic launch stopped because the phone was
locked.

## Editing and merge follow-up

The context menus now put content use first, then editing/completion,
organization, and deletion. Mac retains Copy as its content action. iOS keeps
Copy and Share together. Edit precedes completion; Merge occupies the edit
group for multiple selections.

Removed Mac's Edit in New Window command, Command-Return shortcut, accessibility
action, coordinator methods and window storage, detached editor view/session,
dedicated tests, project references, and unused strings.

iOS has one Edit menu action that opens the existing editor for text and
attachments. Double-tap retains quick inline text editing. Merge Snips appears
in selected-item actions for two or more visible snips and uses the same library
command as Mac. It combines text and retains attachments. A merge of done snips
switches Show to All so the new unfinished snip stays visible.

Verification passed: Mac Dev build and live context menu; real-store iOS merge
with attachments and saved result; iOS selected-item merge menu; and attachment
preview, removal, save, and relaunch through the unified Edit entry. No source
or project references remain for the detached Mac editor. The updated iPhone
Dev 2 build installed and launched successfully.

## Completion symbols

Completion actions now use a plain checkmark for Mark Done and a backward
arrow for Mark Not Done. Select keeps the circled checkmark. The item menu,
selected-item menu, and swipe actions use the same completion symbols.

## Tappable iOS completion control

The completion circle was a decorative image without a tap action. Replaced it
with a borderless button with a 44-point touch target, completion action label,
and current-state accessibility value. It disables itself while saving. Select
mode still uses native selection circles and hides the completion button.

The new tap test failed before the change and passed afterward, covering both
completion states and selection without completion changes. Existing inline-edit
and swipe-completion UI tests passed. The updated phone Dev build installed and
launched successfully.

## Plain iOS list

Changed the snip collection to the native plain list style, removing the rounded
card background and row dividers. Completion symbols are 24 points with 44-point
touch targets. Checked completion circles use the selected list's shared
light/dark accent color, including while editing inline. Unchecked circles keep
their neutral appearance. Simulator review covered a blue list, tapping a snip
done, and inline text editing. Screenshot: `/tmp/snipsnap-plain-list.png`.

## Mac padding and menu follow-up

Kept the Mac cards. Snip rows now use the clipboard list's 16-point outer inset; both already share 12-point inner padding. Kept the existing checkbox and clipboard Copy sizes. Share remains out of scope.

The user chose icons for every item context action. Added matching SF Symbols for Copy, Edit, Merge, completion, Move to List, destination lists, New List, and Delete. The native item menu keeps Copy, Edit/Merge, completion, Move, and Delete in that order. Delete uses system red for its title and symbol. More places Select All before Move to New List. The Snips menu starts with content actions and groups backup actions separately.

Validation: Mac Dev 2 builds and opens through scripts/run.sh. Compared live snip and clipboard card padding and read the item and More menus through accessibility. Captured the native context menu through its window ID and verified red Delete text and icon. The screenshots were shown in the conversation.

## Explicit Mac selection

Commands now receive target IDs without replacing selection. The model owns selected IDs, the range anchor, and keyboard focus together. Filtering and deletion prune that state; editing, completion, Copy, and dragging do not create selection. New List receives its move targets directly. Empty-list clicks clear selection, while toolbar clicks preserve it. The row bridge captures modifier keys at mouse-down so SwiftUI's delayed single-click callback retains them.

Validation: the unselected-move regression failed before the fix. All 92 model, selection, and focused click tests pass afterward. Live Dev 2 checks cover keyboard range selection, opening More, marking an unselected snip Done through its context menu, and clicking a different completion checkbox; the original selection remains. The UI tool cannot hold modifiers during a mouse click, so command/shift-click sequences use automated state tests. Screenshot: /tmp/snipsnap-selection-preserved.png.
