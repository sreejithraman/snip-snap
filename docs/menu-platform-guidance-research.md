# Apple menu guidance

Checked September 5, 2026. This note records Apple guidance and a proposed policy, without changing app code. Apple’s web search results expose the HIG text; opening some canonical pages returns a JavaScript shell. Beta guidance below is separate from the established HIG.

## What Apple says

| Control | Purpose |
| --- | --- |
| Context menu | Shortcuts for the item under the pointer or finger. |
| Pull-down button | Actions related to the button’s purpose. |
| Pop-up button | A flat set of mutually exclusive choices, with the current choice on the button. |

A pop-up button should provide a useful default and enough context to predict its choices. Use a pull-down when the list contains actions, multiple selections, or submenus. [Pop-up buttons](https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons)

For pull-downs, keep primary actions visible elsewhere. A More button suits secondary actions where space is tight, but its symbol gives little clue about its contents. Apple suggests considering direct controls when a menu has only one or two items. Destructive pull-down actions should show their risk and request confirmation; on iPhone this uses an action sheet, and on iPad a popover. [Pull-down buttons](https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons)

For context menus:

- Keep only common actions relevant to the target; aim for a short list.
- Make every action reachable from the main interface too. On Mac, include context commands in the menu bar.
- Hide unavailable items. Mac Cut, Copy, and Paste may remain dimmed.
- Use at most one submenu level and roughly three groups.
- Put frequent actions near the point where the menu opens.
- Show keyboard shortcuts in main menus, not context menus.
- On iOS/iPadOS, put destructive actions last and mark their destructive role.
- Use touch and hold on iPhone/iPad; support secondary click and Control-click on Mac/iPad.
- On iOS/iPadOS, previews should clarify the target. Avoid competing context and text-edit menus on the same item.

These rules come from [Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus).

Across menus, use short action labels with verbs and title capitalization. Add an ellipsis when completing the action needs more information or choices. Regular menus keep unavailable commands visible but dimmed. Put frequent actions first, keep related commands together, and separate groups. Prefer one submenu level. A changing action label can express a toggle, such as Show/Hide; a checkmark can show an active attribute. Use familiar system icons where they clarify meaning, omit unclear icons, and use one icon to introduce a group of similar actions rather than repeating it. [Menus](https://developer.apple.com/design/human-interface-guidelines/menus)

Apple’s SwiftUI controls adapt their display by platform. Use action buttons in menus and native controls for state. A primary action changes how a menu opens: tapping performs that action, while opening the menu becomes secondary. [Populating SwiftUI menus with adaptive controls](https://developer.apple.com/documentation/swiftui/populating-swiftui-menus-with-adaptive-controls)

SwiftUI’s priority order keeps early items near the interaction point. Fixed order keeps top-to-bottom order. On iOS, automatic order resolves to fixed inside scrollable content; menu pickers also default to fixed. Other menus default to priority. [menuOrder](https://developer.apple.com/documentation/swiftui/view/menuorder(_:))

## Version-sensitive icon behavior

Apple’s macOS 27 beta notes say SwiftUI hides most symbol images by default in Mac context menus and Mac/iPad menu bars, while keeping some common system images. The notes describe `.labelStyle(.titleAndIcon)` as an override, for example for an object or concept. Treat this as beta behavior to verify against the app’s SDK and deployment targets, rather than a reason to force icons everywhere. [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes?changes=latest_minor)

## Proposed app policy — our recommendation

Share the meaning of commands: names, target, conditions, checked state, and destructive behavior. Let native controls set appearance, spacing, symbol visibility, and presentation for each OS.

Keep item actions separate from list-wide sorting, filtering, selection, and creation. Use a short item context menu and a visible route to its actions. Use a choice control for a single setting, and a clearly named action menu for related commands. An ellipsis button is suitable only when the surrounding view makes its scope clear.

Audit state and action parity before adding visual polish. Check normal items, empty content, unavailable actions, done/not-done states, multiple selections, and deletion. Confirm that the label describes the next action and that both platforms act on the intended item or selection.

During implementation, verify actual ordering at the top and bottom of the screen; do not assume source order equals displayed order. Confirm supported Mac, iPhone, and iPad behavior, keyboard access, and VoiceOver labels. No blanket icon override or forced identical menu layout is warranted by this research.

## Final user choice

The user later chose an icon for every Mac item context action. That explicit
preference governs the implementation; the sparse-icon advice above records
the research recommendation. Mac keeps its native menu and has no Share action.
