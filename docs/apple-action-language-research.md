# Apple action language research

Date: 2026-08-31

This note checks Apple's current guidance and first-party terms for an action that marks a list item complete on iPhone and Mac.

## Recommendation

Given the choice to keep the Mac app's language, use the same state terms on both platforms:

- **Done** for the compact action on an unfinished snip.
- **Not Done** for the compact reverse action, if the app offers one.
- **Mark Done** and **Mark Not Done** for menus, accessibility labels, or other places that need the state change spelled out.
- **Done** for the state or a collection of finished snips.

This choice meets Apple's label rules and matches Apple Schoolwork's done/not-done terms. **Complete**, **Mark Incomplete**, and **Completed** remain the closer match to Apple Reminders. Apple mainly uses bare **Done** to end a view or flow, so the row or item context must make the state change clear.

Keep the action term in one shared source so menus, swipe actions, buttons, accessibility labels, tooltips, and confirmation text cannot drift between iOS and Mac.

## Apple guidance

Apple says button text should use a few clear words, use title-style capitalization, and generally start with a verb. [Buttons — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/buttons)

Apple's writing guidance says button and link labels should almost always use a verb. It also says to build repeatable language patterns and use terms consistently. [Writing — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/writing)

Apple says menu commands should use a clear, short verb or verb phrase, such as **View**, **Close**, or **Select**. This applies most directly to the Mac menu and supports using the same action term in the iOS swipe action. [Menus — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/menus)

Apple's current design principles say to be clear, direct, and concise, and to use a consistent structure. [Design principles — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/design-principles)

Apple uses **Done** to make clear that a multistep flow has ended. That makes **Done** a good close-or-finish label, but a less exact state-change label than **Complete**. [Writing — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/writing)

## Apple's task language

Apple's Reminders guide for iPhone calls the operation **Complete items**, describes tapping the circle to “mark the item as completed,” and calls the result **Completed items**. [Complete items in Reminders on iPhone](https://support.apple.com/guide/iphone/iph3fb74d597/ios)

Apple's Reminders guide for Mac uses **Mark reminders as complete**, calls the control **Mark Completed**, and uses **Mark Complete** when it names the button. The reverse action is **mark ... as incomplete**. [Mark reminders as completed or incomplete on Mac](https://support.apple.com/guide/reminders/remndbeda47c/mac)

Apple’s Mac notification action uses the short button label **Complete**. [Manage notifications from Reminders on Mac](https://support.apple.com/guide/reminders/remn4e53b572/mac)

Apple Schoolwork uses **Mark Done** and **Mark Not Done** for item actions, backed by **Due Next** and **Done** views. This is direct first-party support for a product that has chosen done/not-done as its state language. [Schoolwork User Guide for Students](https://support.apple.com/guide/schoolwork-student/welcome/ios)

Apple's iCloud Home quick action uses **Mark as Complete** when a context menu needs to spell out the state change. [Customize and use the homepage tiles on iCloud.com](https://support.apple.com/guide/icloud-ipad/customize-and-use-the-homepage-mm048a5aa9cc/icloud)

Apple keeps each product's core state terms consistent, but it shortens labels when the surrounding UI supplies enough context. Cross-platform consistency therefore means shared terms and meaning, not one exact string on every surface.

## Decision table

| Term | Fit | Reason |
| --- | --- | --- |
| Complete | Best Apple match | Short verb and Apple's direct action term for reminders. |
| Done | Good if it is already the app's chosen word | Short and clear in context, but Apple also uses it to end a view or flow. |
| Mark Done | Good for a Done/Not Done product vocabulary | Apple Schoolwork uses it, but Reminders uses Complete instead. |
| Mark as Complete | Use in help text, not a compact action | Clear but too long for a swipe action. |
| Mark Complete | Good for an accessibility label or tooltip | Clear when the control needs more context than the visible action. |
