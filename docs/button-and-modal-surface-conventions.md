# Button and modal surface conventions

Date: September 19, 2026

This note checks Apple guidance and source code from Firefox for iOS, Ice Cubes,
Maccy, and AltTab. Links to open-source code use fixed commits, so the cited
lines will not move.

## Result

Snip Snap should share button *intent* across both apps, then let each platform
draw that intent. It should not share raw fills or label colors.

The Mac edit-list view should not use a standard sheet on the clear floating
panel. A Mac sheet dims its parent window. The parent is still a rectangle even
when much of it is clear, so the dim layer makes that rectangle visible. This is
expected when a sheet uses a clear window, not a bad gray value.

For the current case:

- Use a separate, normally backed Mac window or panel for list editing. Hide or
  close the floating panel while this editor is open if the task must hold the
  person's full attention.
- Keep `confirmationDialog` or `NSAlert` for short choices such as delete and
  discard.
- If the editor must stay inside the floating panel, use an app-owned overlay
  and mask its dim layer to the visible panel surface. This costs more work for
  focus, Escape, Return, VoiceOver, and blocked hit testing, so treat it as the
  fallback.

## Button rules

Use one shared action role with a platform renderer. The role should define
prominence, tint, keyboard behavior, and the disabled state.

| Intent | Shared rule | iOS and iPadOS 26 | macOS 26 |
| --- | --- | --- | --- |
| Primary or confirm | One safe main action in a control group. Use the paired monochrome action fill and label tokens. Do not use `Color.primary` as the tint. | Use a native prominent style. Use `.glassProminent` only when the button sits in the top control layer over content; use the native form or toolbar style in content. | Use the native default or prominent style. Add `.defaultAction` so Return works and the system gives the button default emphasis. |
| Secondary | Keep it neutral and below the primary action. | Use the native standard style, or `.glass` for a floating control. Do not add a strong tint. | Use the standard bordered style and normal prominence. Small controls can keep Mac's rounded-rectangle shape. |
| Cancel or close | Never look like the main commit action. | Use `cancellationAction` placement or `role: .cancel` in a dialog. | Use `cancellationAction` and `.cancelAction` so Escape works. |
| Destructive | Mark the action in code, not just with color. Do not make it the default action. | Use `role: .destructive`; let the system use red in the right context. | Use the destructive role and system red at lower prominence than the default action. |
| Icon or tertiary | Use only for a small, clear action. Always add an access label. | Use plain, borderless, or standard glass based on its layer. | Use plain, borderless, or standard glass based on its layer. |
| Disabled | Keep the same role and disable it. | Let the native style change contrast and material. | Let the native style change contrast and material. |

The color rule is simple:

1. The action role picks whether the control gets a tint.
2. A semantic monochrome action fill supplies that tint.
3. Its paired label token keeps contrast stable in light and dark modes.
4. The native button style owns the pressed state, edge, and disabled state.

Do not set a prominent button's label to a fixed black, white, background, or
`primary` color. Use the light-and-dark action label paired with the action fill.
Do not use `Color.primary` for the button tint. `Color.primary` describes text
against the current background, so it becomes black in a light appearance and
white in a dark one. It does not describe an action fill.

Before this change, `AppProminentActionButton` combined `.glassProminent`,
`SnipSnapTheme.controlTint`, and a forced foreground color, while `controlTint`
was `Color.primary`. The system and the app could then make separate choices
for the plate and its label. The design-system fix makes the wrapper semantic,
pairs its fill with a tested label token, and leaves pressed, edge, and disabled
states to the native style.

Apple's current rules support this split:

- A primary button uses the app accent; a destructive button uses system red.
  Apple also says not to make a destructive action primary. See the **Role**
  section in [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons).
- SwiftUI's [`tint(_:)`](https://developer.apple.com/documentation/swiftui/view/tint(_:))
  changes controls by style, platform, and context. On Mac, a bordered button
  does not fill with the tint, while a bordered-prominent button does. Apple
  says a direct tint should carry added meaning because it overrides the
  person's accent choice.
- SwiftUI's semantic toolbar placements let the system place and style actions
  per platform. In a Mac sheet, a
  [`confirmationAction`](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/confirmationaction)
  goes last and gains the app accent as its background, while a
  [`cancellationAction`](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/cancellationaction)
  goes before it. The same roles move to the expected sides on iOS.
- On Mac, [`defaultAction`](https://developer.apple.com/documentation/swiftui/keyboardshortcut/defaultaction)
  uses Return and gives the default button special color. `cancelAction` uses
  Escape.
- SwiftUI's [`ButtonRole.destructive`](https://developer.apple.com/documentation/swiftui/buttonrole/destructive)
  tells the system that an action deletes data or cannot be undone.

## Liquid Glass rules

Apple treats Liquid Glass as a control and navigation layer, not a general fill.
Standard SwiftUI controls already use the new material. Custom glass should be
rare.

- Use tint to call out a main action. Do not tint every action.
- Prefer native glass tint to a solid fill. It adapts to the content below and
  keeps the label clear.
- Put glass on the control itself, not on inner label views or a sibling view.
- Use regular glass for neutral floating controls. Use prominent glass for the
  main floating action.
- On Mac, keep compact controls compact. Apple keeps mini through medium Mac
  controls as rounded rectangles and uses capsules for large, standout actions.

Apple shows these points in
[Meet Liquid Glass, transcript paragraphs on variants and tint](https://developer.apple.com/videos/play/wwdc2025/219/#:~:text=Tinting%20should%20only%20be%20used)
and in [Build an AppKit app with the new design, 11:10 Controls](https://developer.apple.com/videos/play/wwdc2025/310/?time=670).
The AppKit session says glass is for controls that float over content, default
buttons get the strongest tint, and destructive red should not overpower the
default action. Apple's
[SwiftUI custom glass guide](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
also says that tint suggests prominence and that interactive glass gives a
custom control the same response as a standard glass button.

## What open-source apps do for buttons

### Firefox for iOS: central roles, native iOS 26 renderer

Firefox keeps primary and secondary styles in its component library. Its
[primary style](https://github.com/mozilla-mobile/firefox-ios/blob/28643c07ee3aa12ff53c4ff2f97f4d70e975071f/BrowserKit/Sources/ComponentLibrary/SwiftUI/PrimaryButtonStyle.swift#L8-L36)
reads `actionPrimary` and `textInverted` theme roles; its
[secondary style](https://github.com/mozilla-mobile/firefox-ios/blob/28643c07ee3aa12ff53c4ff2f97f4d70e975071f/BrowserKit/Sources/ComponentLibrary/SwiftUI/SecondaryButtonStyle.swift#L8-L34)
uses separate secondary roles.

For iOS 26, Firefox changes the renderer while keeping the same intent. Its
[onboarding button helpers](https://github.com/mozilla-mobile/firefox-ios/blob/28643c07ee3aa12ff53c4ff2f97f4d70e975071f/BrowserKit/Sources/OnboardingKit/Views/OnboardingFlow/OnboardingButton.swift#L9-L59)
map primary and secondary roles to native glass styles and theme tints. It also
uses SwiftUI's destructive and cancel alert roles for card removal in
[CreditCardInputViewModel](https://github.com/mozilla-mobile/firefox-ios/blob/28643c07ee3aa12ff53c4ff2f97f4d70e975071f/firefox-ios/Client/Frontend/Autofill/CreditCard/CreditCardSettingsView/CreditCardInputViewModel.swift#L155-L180).

The useful part for Snip Snap is the split: call sites ask for an action role;
the OS-specific style stays in one place.

### Ice Cubes: one tinted primary beside a neutral secondary

Ice Cubes places a tinted `.borderedProminent` Send button next to a neutral
`.bordered` results button in
[StatusPollView](https://github.com/Dimillian/IceCubesApp/blob/b2db3033fbf67a97b54d25d6dac2df8a029b26b1/Packages/StatusKit/Sources/StatusKit/Poll/StatusPollView.swift#L93-L106).
That small pair shows the hierarchy clearly without giving both actions a
strong fill. It also uses a semantic destructive role in confirmation flows,
for example in
[ToolbarItems](https://github.com/Dimillian/IceCubesApp/blob/b2db3033fbf67a97b54d25d6dac2df8a029b26b1/Packages/StatusKit/Sources/StatusKit/Editor/ToolbarItems.swift#L83-L94).

## Why the Mac dim rectangle appears

Apple says that a Mac sheet is attached to one parent window and dims that
parent while the sheet is open. See the **macOS** section of
[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets).
AppKit also defines a sheet as a document-modal session on the receiving window;
see
[`beginSheet(_:completionHandler:)`](https://developer.apple.com/documentation/appkit/nswindow/beginsheet(_:completionhandler:)).

Snip Snap's parent panel sets `isOpaque = false` and `backgroundColor = .clear`.
The visible panel is a rounded surface inside that clear window. The screenshot
shows the system dim layer across the parent window's full bounds, including the
clear area. The square is therefore the window that hosts the sheet. This cause
is an inference from Apple's sheet rule, the panel setup, and the screenshot.

Apple's design advice gives two other options:

- A sheet fits a short task tied to a normal parent window. For a self-contained
  Mac edit task, the **Best practices** section of
  [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)
  says a separate window can work better.
- For controls that people use while still working with the main window, use a
  panel. See [Panels](https://developer.apple.com/design/human-interface-guidelines/panels).

Changing the dim color or padding cannot fix this. The dim view
still belongs to the rectangular parent window.

## What open-source Mac apps do

### Maccy: clear panel, system confirmation, separate settings window

Maccy builds its popup as a clear `NSPanel`; see
[FloatingPanel](https://github.com/p0deje/Maccy/blob/c376789c5d377b7c520b6f6e91f3f3a1aa28640b/Maccy/FloatingPanel.swift#L25-L65).
For a short destructive choice it uses SwiftUI's `confirmationDialog` with
destructive and cancel roles in
[ConfirmationView](https://github.com/p0deje/Maccy/blob/c376789c5d377b7c520b6f6e91f3f3a1aa28640b/Maccy/Views/ConfirmationView.swift#L7-L25).
For the larger settings flow it creates and brings forward a separate settings
window in
[AppState](https://github.com/p0deje/Maccy/blob/c376789c5d377b7c520b6f6e91f3f3a1aa28640b/Maccy/Observables/AppState.swift#L108-L182).

### AltTab: clear switcher panels, normal settings and feedback windows

AltTab centralizes the clear chrome for its switcher panels in
[`applyFloatingPanelChrome`](https://github.com/lwouis/alt-tab-macos/blob/1cfb7e1df05f2cb87e0cc88f490de97d3e51b753/src/macos/api-wrappers/HelperExtensions.swift#L290-L303).
It does not put its full settings flow inside that clear surface. It creates a
normal titled, resizable
[`SettingsWindow`](https://github.com/lwouis/alt-tab-macos/blob/1cfb7e1df05f2cb87e0cc88f490de97d3e51b753/src/preferences/settings-window/SettingsWindow.swift#L266-L378).
It does the same for feedback, then uses a system `NSAlert` for the short update
choice; see
[`FeedbackWindow`](https://github.com/lwouis/alt-tab-macos/blob/1cfb7e1df05f2cb87e0cc88f490de97d3e51b753/src/secondary-windows/FeedbackWindow.swift#L22-L72)
and its [`runModal` alert](https://github.com/lwouis/alt-tab-macos/blob/1cfb7e1df05f2cb87e0cc88f490de97d3e51b753/src/secondary-windows/FeedbackWindow.swift#L231-L249).

Both apps keep the fast floating surface separate from longer edit and settings
tasks. They show longer tasks in a normal window.

## Recommended Snip Snap design

1. Add one shared semantic API for the primary action. Keep secondary, cancel,
   destructive, and icon actions on native button roles.
2. Put the iOS and Mac primary renderers behind that API. Share intent and
   color roles, not exact fills, shapes, or sizes.
3. Replace `Color.primary` as the action tint with a real semantic accent. Pair
   it with the action label token, then let native styles own pressed, edge, and
   disabled states.
4. Give Mac confirm and cancel actions `.defaultAction` and `.cancelAction`.
   Use semantic toolbar placements when they sit in a sheet or editor toolbar.
5. Move Mac list editing out of the clear panel's `.sheet`. Use a separate
   backed editor window or panel. Keep the existing system confirmation dialog
   pattern for delete.
6. Test light, dark, Increase Contrast, Reduce Transparency, enabled, disabled,
   hover, press, Return, Escape, and VoiceOver on both platforms.

This gives both apps the same rules without forcing them to look the same.
