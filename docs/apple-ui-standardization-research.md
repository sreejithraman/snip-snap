# Apple UI standardization for iOS and macOS

Date: September 2, 2026

This note checks current Apple guidance for control size, text, alignment,
spacing, and access on iOS and macOS. It then applies that guidance to Snip
Snap's SwiftUI code. Apple documentation and Apple sessions are the only web
sources.

## Short answer

Snip Snap had a sound start, but its custom controls did not use one full set
of shared UI rules before this review.

The Mac panel had named size and spacing values. Both apps shared color roles
in `Shared/SnipSnapTheme.swift`. The iOS app used many local values for control
heights, icon sizes, gaps, and insets. That made small differences easy to add
and hard to spot.

Apple does not say that the same control must have the same point size on iOS
and macOS. Its access guide lists a 44 by 44 point default control size on iOS
and iPadOS, and 28 by 28 points on macOS. The same table lists 28 by 28 and 20
by 20 points as the lower bounds for those platforms. Apple also gives a broad
button rule of a hit region of at least 44 by 44 points. For this app, use 44
points as the normal iOS touch target and let native Mac controls use their Mac
size unless a custom control has a clear reason to be larger. [Accessibility —
Mobility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)

The best shared design system is mostly semantic:

1. Use native controls, system text styles, system colors, and automatic styles
   first.
2. Name the few app-owned roles, such as compact composer height, related-item
   gap, and content inset.
3. Give each platform its own value for a role when touch and pointer needs
   differ.
4. Put custom control geometry and its access target in one component so its
   visible shape, alignment, and hit region cannot drift apart.

Apple's current HIG calls consistency the use of platform conventions in a
design that adapts across window sizes and displays. SwiftUI's automatic
styles follow the same rule: they select a look from the current platform,
container, and context. A shared role should therefore mean the same thing on
both platforms; it need not hold the same number. [Human Interface
Guidelines](https://developer.apple.com/design/human-interface-guidelines),
[View styles](https://developer.apple.com/documentation/swiftui/view-styles)

## Why the composer can look wrong

In the code reviewed for this note, the iOS attachment button has a 24 point
label, a native glass style, and then a 44 by 44 point outer frame. The outer
frame makes room for a touch target, but it does not require the native style's
visible circle to fill that frame. The style still chooses its shape from the
label, platform, and context. This can leave a 44 point hit area around a
smaller visible circle.

The composer also uses `HStack(alignment: .bottom)`. Its text field has its own
vertical padding and a 40 point minimum surface, while the button has a 44 point
outer frame. Bottom alignment puts the shorter field at the bottom of the
taller row, so its visual center can sit low. SwiftUI stacks center their
children by default; another alignment must be requested. [Aligning views
within a stack](https://developer.apple.com/documentation/swiftui/aligning-views-within-a-stack)

For a one-line composer, use one named row height so each fixed control has the
same visual center. Let the hint and entered text come from the same `TextField`,
with equal top and bottom insets. Keep bottom alignment only when the actions
should stay at the bottom as the field grows to more lines.

## Apple rules to adopt

### Use semantic control sizes

`ControlSize.regular` is SwiftUI's default. Apple defines `.small` for a
space-limited view, `.large` for a prominent control, and `.mini` for the
smallest control. Apple does not define these names as fixed cross-platform
point values. Set one `controlSize` on a related control group when the group
needs a nondefault density, instead of setting unrelated frames on each child.
[ControlSize](https://developer.apple.com/documentation/swiftui/controlsize),
[`controlSize`](https://developer.apple.com/documentation/swiftui/environmentvalues/controlsize)

Apple's current design session says standard controls now form one family
across platforms while still adapting: Mac control heights changed, and
`controlSize` remains the way to preserve a dense inspector or popover. The
same session says standard controls provide much of the new design without
custom code. [Build a SwiftUI app with the new
design](https://developer.apple.com/videos/play/wwdc2025/323/)

Use `.buttonSizing(.automatic)` unless a compact action must fit its content or
a main action must fill space. Automatic button sizing uses the control's
platform and placement. [Automatic button
sizing](https://developer.apple.com/documentation/swiftui/buttonsizing/automatic)

### Keep visible size and hit size separate, but explicit

For iOS composer actions, make the normal hit region at least 44 by 44 points.
A visible symbol may be smaller, but the code should name both sizes and make
the difference clear. Add the interaction shape after the hit-target frame so
hit testing covers that frame. SwiftUI defines the interaction content shape
as the shape used for hit testing and access. [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons),
[`ContentShapeKinds.interaction`](https://developer.apple.com/documentation/swiftui/contentshapekinds/interaction)

Do not infer a visible button's size from a screenshot or from the hit-target
rule. Apple treats the hit region and drawn shape as separate concerns. In a
row of peer actions, keep the visible sizes consistent; Apple's button guide
warns that nearby buttons with different sizes can look unclear and
inconsistent. [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)

### Prefer native, context-aware styles

SwiftUI's automatic button style changes by platform and container. A blank
canvas uses a borderless button on iOS and a bordered button on macOS, while a
button in a list or other container resolves to that context's recommended
style. The automatic text-field style also uses the platform and the field's
place in the view tree. [Automatic button
style](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/automatic),
[Automatic text-field
style](https://developer.apple.com/documentation/swiftui/textfieldstyle/automatic)

Use native button, menu, toggle, text-field, and label styles where they fit.
Keep a custom composer surface only because it is a compound control with an
intentional design. Even there, keep the inner field as a real `TextField` and
the actions as real `Button` or `Menu` values.

### Use system text styles and scale only app-owned measures

Apple recommends the built-in text styles and system fonts. They preserve a
clear type order and support Dynamic Type where the platform offers it. iOS
and iPadOS support Dynamic Type; macOS does not. Apple's listed default text
sizes are 17 points on iOS and iPadOS and 13 points on macOS, so one fixed point
size is not a cross-platform text rule. [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)

Use `.font(.body)`, `.subheadline`, `.caption`, and other semantic styles for
product text. Use a fixed point size only for a measured display need, such as
a small badge with a tested lower bound. For custom iOS sizes that should grow
with text, use `@ScaledMetric(relativeTo:)`; Apple defines it as a numeric value
that scales from the current environment and a text style. [ScaledMetric](https://developer.apple.com/documentation/swiftui/scaledmetric)

Use SF Symbols next to system text. Apple says symbols integrate with the
system font, align with text across weights and sizes, and scale with Dynamic
Type. [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols),
[Typography](https://developer.apple.com/design/human-interface-guidelines/typography)

### Align by intent

Use center alignment for peer controls in a fixed-height, one-line row. Use a
text baseline when different text styles must line up. Use a custom alignment
guide only when the content that must align sits in nested stacks. Apple lists
all three as normal SwiftUI layout paths. [Aligning views within a
stack](https://developer.apple.com/documentation/swiftui/aligning-views-within-a-stack),
[Aligning views across
stacks](https://developer.apple.com/documentation/swiftui/aligning-views-across-stacks)

Use leading and trailing, not left and right. SwiftUI flips those guides in a
right-to-left setting, and Apple's HIG asks text alignment to follow the
interface direction. [Alignment](https://developer.apple.com/documentation/swiftui/alignment),
[Right to left](https://developer.apple.com/design/human-interface-guidelines/right-to-left)

### Keep spacing roles small and clear

Apple's layout guide asks apps to align related parts and to respect system
margins and guides. SwiftUI stacks can choose the platform's default spacing
when `spacing` is `nil`. Use that default for ordinary layouts. Use named app
spacing only when custom surfaces must align or keep a deliberate rhythm.
[Layout](https://developer.apple.com/design/human-interface-guidelines/layout),
[`HStackLayout.spacing`](https://developer.apple.com/documentation/swiftui/hstacklayout/spacing)

For Snip Snap, keep a short set of role names instead of a long list of raw
numbers:

- `relatedContent`
- `controlContentInset`
- `cardContentInset`
- `paneContentInset`
- `compactComposerHeight`
- `compactActionHitSize`
- `compactActionVisibleSize`

The first four roles already exist for the Mac panel. The iOS app should use
the same role names where the meaning matches and iOS-only values where the
interaction differs. Do not force Mac to use the iOS touch size.

Apple does not publish an app-level design-token type. This role layer is a
Snip Snap code choice built on Apple's wider rule: use semantic, adapting
system values first, then share the few custom values through a view hierarchy
or reusable component. SwiftUI environment values support such shared
configuration when a value needs to flow through a tree. [Environment
values](https://developer.apple.com/documentation/swiftui/environment-values)

### Include access in every custom component

Apple asks apps to label controls, support assistive input, test larger text,
and leave enough space between controls as well as making the controls large
enough. [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

For icon-only actions, prefer a `Button` with a title and system image, then
apply `.labelStyle(.iconOnly)`. SwiftUI keeps the title as the VoiceOver name
even when the title is hidden on screen. If a custom label is required, add an
explicit access label. [Button](https://developer.apple.com/documentation/swiftui/button),
[`IconOnlyLabelStyle`](https://developer.apple.com/documentation/swiftui/labelstyle/icononly)

Check each custom control with VoiceOver, Voice Control, Full Keyboard Access,
large access text on iOS, Bold Text, Increase Contrast, Reduce Motion, light
and dark appearances, and both left-to-right and right-to-left languages.
Apple also recommends using Accessibility Inspector to audit the view tree.
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

## Repo check

This is a source check, not a full screen-by-screen access audit.

### What already follows the guidance

- The Mac panel uses named control, spacing, shape, list, and composer roles
  instead of repeating every number.
- `Shared/SnipSnapTheme.swift` shares semantic color roles across iOS and Mac.
- Most product text uses semantic SwiftUI styles such as `.body`, `.headline`,
  `.subheadline`, and `.caption`.
- Settings and recovery screens mainly use native bordered button styles and
  standard controls.
- The iOS composer uses a real `TextField`, `Button`, and `Menu`, and its custom
  send control uses scaled values and a 44 point lower bound.
- Icon-only composer actions have access labels.
- The shared toast honors Reduce Motion.

### Gaps found before this fix

- The iOS compact controls repeat 8, 12, 16, 44, 48, 52, and 56 point values
  across local views. There is no iOS peer to the Mac panel's named metrics.
- Some iOS controls use a native glass style inside a fixed outer frame. That
  gives the hit region a size but does not make the drawn glass shape the same
  size.
- The one-line iOS composer bottom-aligns a 44 point action with a shorter text
  field. This is the cause of the low-looking hint and entered text in the
  supplied images.
- The composer uses a plain text-field style and owns all insets. That is fine
  for this compound control, but it means the app must own and test vertical
  centering, large text, and multiline changes.
- Several Mac custom surfaces still use fixed point font sizes. Some are valid
  for small panel chrome, but each needs a stated reason and a legibility check
  against Apple's 10 point Mac lower bound.
- Control geometry lives in several view files, so two peer controls can use
  different visible sizes even when both have a valid hit region.

### Changes made with this review

- Shared gap and inset roles now live beside the shared color roles, so iOS
  and Mac use the same names where the meaning matches.
- The iOS compact controls now name touch size, icon size, list height, and
  list-item width instead of repeating those values.
- The attachment and new-list actions use one round glass button component
  with a scaled 44 point size.
- The one-line text field now has the same scaled 44 point lower bound as its
  peer actions and equal top and bottom insets.
- The quick-composer UI test checks the access size and shared vertical center
  before and after text entry, keeps a filled-state screenshot, and checks the
  action position after the field grows past one line.
- The Mac composer now uses one compact 32 point role for its input and
  standalone attachment action. The list strip keeps its separate 40 point
  row, and regular Mac toolbar controls still use the native size.

## Recommended repo rule

Adopt this order for new and changed UI:

1. Start with the native SwiftUI control and automatic style.
2. Apply a semantic text style and system color.
3. Apply one `controlSize` to the smallest useful group.
4. Use system spacing unless a custom surface needs a named gap or inset.
5. For a custom control, keep its visible size, hit size, content shape,
   pressed state, disabled state, and access label in one component.
6. Use platform values for touch and pointer needs; share role names and
   behavior across platforms.
7. Test the real iOS and Mac surfaces, not only previews or build output.

For the current composer fix, the direct rule is: make the visible add circle
44 points on iOS, keep its hit area at least 44 points, give the one-line input
surface the same 44 point height, and center the text field and actions in that
row. Keep equal vertical text insets. Preserve the existing multiline growth
and verify the action placement at two through five lines.
