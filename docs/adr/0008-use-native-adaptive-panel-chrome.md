# 0008: Use native adaptive panel chrome

## Context

Snip Snap floats over other apps, so its chrome must remain clear over backgrounds it does not control. Fixed white or black fills, custom blur plates, and outer glow layers fought macOS appearance and accessibility settings. Several one-off glass recipes also made similar controls look unrelated.

## Decision

Use macOS 26 Liquid Glass for top-level panel controls and navigation. Put nearby custom glass in a shared `GlassEffectContainer` when they form one visual group. Use named semantic color roles for text, state, edges, cards, and actions. Let native glass adapt to its backdrop and the selected System, Light, or Dark appearance. Do not add a window-wide blur plate to the main panel or draw a custom halo. Keep content cards as a separate content surface.

The pinned header and small secondary controls share the `NestedGlassTint` color asset. Its light variant uses about 10% black; its dark variant uses 20% black. The composer uses regular interactive glass. Text and Send occupy separate slots in a bottom-aligned row. The input background and Send use separate glass containers to keep their presses separate. Keep the input's corner radius consistent with the Send capsule and its inset at every text height.

Send uses the selected list preset's resolved color at the shared glass tint strength, with a softly tinted white arrow. A neutral list has no preset color, so its Send takes the primary text color and an inverse arrow based on the view's appearance. Primary actions use the paired monochrome action fill and label on both platforms. Outside neutral Send, never use `Color.primary` as an action tint. It is a text color and turns black in light mode. Native button styles set the pressed and disabled states, except for Send. This list-color decision replaces the earlier shared neutral treatment for Send and Save.

Share the primary-action role across platforms, not its exact shape. Mac uses the native bordered-prominent style. iOS uses native prominent glass for controls that float over content. Secondary, cancel, and destructive buttons keep their native roles and lower weight. Use no more than one main action in a control group.

Use native button styles by default. The compact Mac editor actions are an exception: their shared glass treatment fixes their size and keeps idle controls visible. Send and Save use a 36 × 24 capsule; secondary editor controls use 24-point circles. Save uses a shared ButtonStyle that keeps the glass inside the button label and supplies explicit idle colors. Send is one control shared with iOS. It draws its own glass capsule, sends on a tap, opens the list of destinations on a long press, and supplies explicit disabled colors. Each button stays disabled when unavailable. Retain native Button actions, keyboard shortcuts, and accessibility labels.

Keep resizing on the visible glass edge because the window frame includes a 24-point effect gutter. A five-point AppKit overlay handles the edge drag. Use always-active enter and exit tracking for idle frame-resize cursors, then hold the same cursor during a drag. Keep the panel's size limits on `NSWindow`.

Forms, alerts, confirmations, and file panels follow [ADR 0030](0030-separate-floating-panel-dialogs-with-a-solid-surface.md), which replaces the native sheets this record first chose. Keep Escape on cancel or back actions. Use Return only for a safe main action.

## Consequences

Small and large glass surfaces can resolve to different tones over the same background. That native response is expected. Tints remain reserved for meaning or emphasis. Reduce Transparency, Increase Contrast, and Reduce Motion continue to work through the system. New views should reuse the shared surface and color roles instead of adding raw colors or opacity recipes.

Keep dialog surfaces compact so they still read as a subordinate layer of the panel.

The borderless panel needs a small resize overlay because AppKit's window edge sits outside the visible glass. The overlay takes only five points from straight edges and uses always-active enter and exit events instead of app-active cursor-update events.
