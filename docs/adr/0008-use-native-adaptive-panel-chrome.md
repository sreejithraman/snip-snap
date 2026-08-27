# 0008: Use native adaptive panel chrome

## Context

Snip Snap floats over other apps, so its chrome must remain clear over backgrounds it does not control. Fixed white or black fills, custom blur plates, and outer glow layers fought macOS appearance and accessibility settings. Several one-off glass recipes also made similar controls look unrelated.

## Decision

Use macOS 26 Liquid Glass for top-level panel controls and navigation. Put nearby custom glass in a shared `GlassEffectContainer` when they form one visual group. Use named semantic color roles for text, state, edges, cards, and actions. Let native glass adapt to its backdrop and the selected System, Light, or Dark appearance. Do not force glass to a light or dark tint, add a window-wide blur plate, or draw a custom halo. Keep content cards as a separate content surface.

Keep resizing on the visible glass edge because the window frame includes a 24-point effect gutter. A five-point AppKit overlay owns the edge drag. Use always-active enter and exit tracking for idle frame-resize cursors, then hold the same cursor during a drag. Keep the panel's size limits on `NSWindow`.

## Consequences

Small and large glass surfaces can resolve to different tones over the same background. That native response is expected. Tints remain reserved for meaning or emphasis. Reduce Transparency, Increase Contrast, and Reduce Motion continue to work through the system. New views should reuse the shared surface and color roles instead of adding raw colors or opacity recipes.

The borderless panel needs a small resize overlay because AppKit's window edge sits outside the visible glass. The overlay takes only five points from straight edges and uses always-active enter and exit events instead of app-active cursor-update events.
