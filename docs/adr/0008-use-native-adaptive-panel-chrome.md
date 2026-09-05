# 0008: Use native adaptive panel chrome

## Context

Snip Snap floats over other apps, so its chrome must remain clear over backgrounds it does not control. Fixed white or black fills, custom blur plates, and outer glow layers fought macOS appearance and accessibility settings. Several one-off glass recipes also made similar controls look unrelated.

## Decision

Use macOS 26 Liquid Glass for top-level panel controls and navigation. Put nearby custom glass in a shared `GlassEffectContainer` when they form one visual group. Use named semantic color roles for text, state, edges, cards, and actions. Let native glass adapt to its backdrop and the selected System, Light, or Dark appearance. Do not add a window-wide blur plate or draw a custom halo. Keep content cards as a separate content surface.

The pinned header and small secondary controls share the `NestedGlassTint` color asset. Its light variant keeps the subtle system tint; its dark variant uses 20% black. The composer uses regular interactive glass, with Send in a separate overlay and glass container inside its visible bounds. This keeps input and Send presses separate.

Send uses the selected list's saved color at the shared glass tint strength, with a softly tinted white arrow. Neutral lists use an inverse arrow based on the view's appearance. Save retains `ActionGlassTint` and its existing label role. Native glass supplies the material and edge; do not add a solid plate or custom stroke. This list-color decision replaces the earlier shared neutral treatment for Send and Save.

Use native button styles by default. The compact Mac editor actions are an exception: their shared glass treatment fixes their size and keeps idle controls visible. Send and Save use a 36 × 24 capsule; secondary editor controls use 24-point circles. A shared ButtonStyle keeps the glass inside the button label and supplies explicit idle colors. The button stays disabled when unavailable. Retain native Button actions, keyboard shortcuts, and accessibility labels.

Keep resizing on the visible glass edge because the window frame includes a 24-point effect gutter. A five-point AppKit overlay owns the edge drag. Use always-active enter and exit tracking for idle frame-resize cursors, then hold the same cursor during a drag. Keep the panel's size limits on `NSWindow`.

## Consequences

Small and large glass surfaces can resolve to different tones over the same background. That native response is expected. Tints remain reserved for meaning or emphasis. Reduce Transparency, Increase Contrast, and Reduce Motion continue to work through the system. New views should reuse the shared surface and color roles instead of adding raw colors or opacity recipes.

The borderless panel needs a small resize overlay because AppKit's window edge sits outside the visible glass. The overlay takes only five points from straight edges and uses always-active enter and exit events instead of app-active cursor-update events.
